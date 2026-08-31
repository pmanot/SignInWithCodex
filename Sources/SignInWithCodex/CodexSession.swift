import Combine
import Foundation

@MainActor
public final class CodexSession: ObservableObject {
  @Published public private(set) var state: CodexSessionState = .signedOut
  @Published public private(set) var account: CodexAccount?
  @Published public private(set) var authorization: CodexAuthorization?
  @Published public private(set) var lastErrorMessage: String?

  public var isSignedIn: Bool {
    account != nil
  }

  private let authClient: CodexAuthClient
  private let streamingClient: CodexStreamingClient
  private let credentialStore: any CredentialStoring

  private var credential: CodexCredential?
  private var callbackServer: LocalOAuthCallbackServer?
  private var signInTask: Task<Void, Never>?
  private var refreshTask: Task<CodexCredential, Error>?
  private var activeStreams: [UUID: Task<Void, Never>] = [:]

  public convenience init(keychainService: String? = nil) {
    self.init(
      authClient: CodexAuthClient(),
      streamingClient: CodexStreamingClient(),
      credentialStore: KeychainCredentialStore(service: keychainService)
    )
  }

  init(
    authClient: CodexAuthClient,
    streamingClient: CodexStreamingClient,
    credentialStore: any CredentialStoring
  ) {
    self.authClient = authClient
    self.streamingClient = streamingClient
    self.credentialStore = credentialStore
    restore()
  }

  /// Loads the stored credential from Keychain.
  ///
  /// The initializer calls this once. Keychain is unavailable before the first
  /// unlock after boot (for example during a prewarm launch), so call it again
  /// when the scene becomes active if `isSignedIn` is unexpectedly `false`.
  @discardableResult
  public func restore() -> Bool {
    guard credential == nil else { return true }
    do {
      guard let stored = try credentialStore.load() else { return false }
      credential = stored
      account = CodexAccount(id: stored.accountID, planType: stored.planType)
      state = .signedIn
      lastErrorMessage = nil
      return true
    } catch {
      lastErrorMessage = error.localizedDescription
      return false
    }
  }

  public func signIn(preferredProvider: CodexLoginProvider? = nil) {
    guard state == .signedOut else { return }
    lastErrorMessage = nil
    state = .preparingSignIn

    do {
      let server = try LocalOAuthCallbackServer.start { [weak self] url in
        Task { @MainActor in
          self?.completeSignIn(callbackURL: url)
        }
      }
      callbackServer = server
      let authorization = try authClient.makeAuthorization(
        redirectURL: server.redirectURL,
        preferredProvider: preferredProvider
      )
      server.expect(state: authorization.state)
      self.authorization = authorization
      state = .awaitingCallback
    } catch {
      finishSignIn(error: error)
    }
  }

  public func cancelSignIn() {
    signInTask?.cancel()
    signInTask = nil
    callbackServer?.stop()
    callbackServer = nil
    authorization = nil
    if credential == nil {
      state = .signedOut
    }
  }

  /// Removes the credential and ends every active stream.
  ///
  /// A stream that is refreshing its token when sign-out happens is cancelled;
  /// a refresh that nevertheless completes afterwards is discarded rather
  /// than reapplied, so sign-out cannot be undone by an in-flight request.
  public func signOut() throws {
    cancelSignIn()
    cancelActiveStreams()
    refreshTask?.cancel()
    refreshTask = nil
    try credentialStore.delete()
    credential = nil
    account = nil
    state = .signedOut
    lastErrorMessage = nil
  }

  public func clearError() {
    lastErrorMessage = nil
  }

  public func stream(
    _ request: CodexRequest
  ) -> AsyncThrowingStream<CodexStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let id = UUID()
      let task = Task { @MainActor [weak self] in
        defer { self?.activeStreams[id] = nil }
        guard let self else {
          continuation.finish()
          return
        }

        do {
          var credential = try await validCredential()
          do {
            _ = try await streamingClient.perform(
              request,
              credential: credential,
              onEvent: { event in
                continuation.yield(event)
              }
            )
          } catch SignInWithCodexError.unauthorized {
            credential = try await refresh(credential)
            _ = try await streamingClient.perform(
              request,
              credential: credential,
              onEvent: { event in
                continuation.yield(event)
              }
            )
          }
          continuation.finish()
        } catch {
          lastErrorMessage = error.localizedDescription
          continuation.finish(throwing: error)
        }
      }
      activeStreams[id] = task
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  public func stream(
    prompt: String,
    history: [CodexMessage] = [],
    model: CodexModelSelection = .latest,
    reasoningEffort: CodexReasoningEffort? = nil,
    instructions: String = "Reply directly to the user. No tools are available.",
    threadID: UUID = UUID()
  ) -> AsyncThrowingStream<CodexStreamEvent, Error> {
    stream(
      CodexRequest(
        prompt: prompt,
        history: history,
        model: model,
        reasoningEffort: reasoningEffort,
        instructions: instructions,
        threadID: threadID
      )
    )
  }

  private func completeSignIn(callbackURL: URL) {
    guard let authorization, state == .awaitingCallback else { return }
    state = .exchangingCode
    self.authorization = nil

    signInTask = Task { [weak self] in
      guard let self else { return }
      do {
        let credential = try await authClient.completeAuthorization(
          callbackURL: callbackURL,
          authorization: authorization
        )
        try Task.checkCancellation()
        try credentialStore.save(credential)
        apply(credential)
      } catch is CancellationError {
        cancelSignIn()
      } catch {
        finishSignIn(error: error)
      }
    }
  }

  private func validCredential() async throws -> CodexCredential {
    if credential == nil {
      restore()
    }
    guard let credential else {
      throw SignInWithCodexError.notSignedIn
    }
    if authClient.needsRefresh(credential) {
      return try await refresh(credential)
    }
    return credential
  }

  /// Refreshes `stale`, coalescing concurrent callers onto one token request.
  ///
  /// The token endpoint rotates refresh tokens, so two parallel refreshes with
  /// the same token would invalidate each other. A refresh that the server
  /// rejects outright means the credential is dead; it is removed and the
  /// session returns to `signedOut`.
  ///
  /// `stale` doubles as the session generation: the result is applied only if
  /// `stale` is still the current credential once the token request returns.
  /// Sign-out, eviction, or another sign-in in the meantime all change it, and
  /// the refreshed credential is then discarded.
  private func refresh(_ stale: CodexCredential) async throws -> CodexCredential {
    guard let current = credential else {
      throw SignInWithCodexError.notSignedIn
    }
    if current != stale {
      // Another caller already refreshed while we waited.
      return current
    }
    if let refreshTask {
      let refreshed = try await refreshTask.value
      guard credential != nil else { throw SignInWithCodexError.notSignedIn }
      return refreshed
    }

    let task = Task { [authClient] in
      try await authClient.refreshCredential(stale)
    }
    refreshTask = task
    defer {
      if refreshTask == task {
        refreshTask = nil
      }
    }

    do {
      let refreshed = try await task.value
      guard credential == stale else { throw SignInWithCodexError.notSignedIn }
      try credentialStore.save(refreshed)
      apply(refreshed)
      return refreshed
    } catch SignInWithCodexError.unauthorized {
      evictCredential(stale)
      throw SignInWithCodexError.notSignedIn
    } catch let SignInWithCodexError.httpStatus(operation, status, message)
      where status == 400
    {
      // `invalid_grant`: the refresh token was revoked or already rotated.
      evictCredential(stale)
      throw SignInWithCodexError.httpStatus(
        operation: operation, status: status, message: message
      )
    }
  }

  /// Removes `dead` if it is still the current credential.
  private func evictCredential(_ dead: CodexCredential) {
    guard credential == dead else { return }
    try? credentialStore.delete()
    credential = nil
    account = nil
    state = .signedOut
  }

  private func cancelActiveStreams() {
    for task in activeStreams.values {
      task.cancel()
    }
    activeStreams.removeAll()
  }

  private func apply(_ credential: CodexCredential) {
    self.credential = credential
    account = CodexAccount(id: credential.accountID, planType: credential.planType)
    callbackServer?.stop()
    callbackServer = nil
    authorization = nil
    signInTask = nil
    state = .signedIn
    lastErrorMessage = nil
  }

  private func finishSignIn(error: Error) {
    callbackServer?.stop()
    callbackServer = nil
    authorization = nil
    signInTask = nil
    state = credential == nil ? .signedOut : .signedIn
    lastErrorMessage = error.localizedDescription
  }
}
