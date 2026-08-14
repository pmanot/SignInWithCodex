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

    do {
      if let credential = try credentialStore.load() {
        self.credential = credential
        account = CodexAccount(
          id: credential.accountID,
          planType: credential.planType
        )
        state = .signedIn
      }
    } catch {
      lastErrorMessage = error.localizedDescription
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
      authorization = try authClient.makeAuthorization(
        redirectURL: server.redirectURL,
        preferredProvider: preferredProvider
      )
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

  public func signOut() throws {
    cancelSignIn()
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
      let task = Task { @MainActor [weak self] in
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
    instructions: String = "Reply directly to the user. No tools are available."
  ) -> AsyncThrowingStream<CodexStreamEvent, Error> {
    stream(
      CodexRequest(
        prompt: prompt,
        history: history,
        model: model,
        reasoningEffort: reasoningEffort,
        instructions: instructions
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
    guard let credential else {
      throw SignInWithCodexError.notSignedIn
    }
    if authClient.needsRefresh(credential) {
      return try await refresh(credential)
    }
    return credential
  }

  private func refresh(_ credential: CodexCredential) async throws -> CodexCredential {
    let refreshed = try await authClient.refreshCredential(credential)
    try credentialStore.save(refreshed)
    apply(refreshed)
    return refreshed
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
