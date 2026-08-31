import Foundation

public struct CodexAuthorization: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let authorizationURL: URL

  let redirectURL: URL
  let state: String
  let codeVerifier: String

  init(
    id: UUID = UUID(),
    authorizationURL: URL,
    redirectURL: URL,
    state: String,
    codeVerifier: String
  ) {
    self.id = id
    self.authorizationURL = authorizationURL
    self.redirectURL = redirectURL
    self.state = state
    self.codeVerifier = codeVerifier
  }

  func matchesCallback(_ url: URL) -> Bool {
    guard
      let expected = URLComponents(
        url: redirectURL,
        resolvingAgainstBaseURL: false
      ),
      let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      return false
    }

    return candidate.scheme?.lowercased() == expected.scheme?.lowercased()
      && candidate.host?.lowercased() == expected.host?.lowercased()
      && candidate.port == expected.port
      && candidate.path == expected.path
  }
}

public enum CodexLoginProvider: String, Equatable, Sendable {
  case apple
}

public enum CodexSessionState: Equatable, Sendable {
  case signedOut
  case preparingSignIn
  case awaitingCallback
  case exchangingCode
  case signedIn
}

public struct CodexAccount: Equatable, Sendable {
  public let id: String
  public let planType: String?

  public init(id: String, planType: String?) {
    self.id = id
    self.planType = planType
  }
}

public struct CodexMessage: Identifiable, Equatable, Sendable {
  public enum Role: String, Equatable, Sendable {
    case user
    case assistant
  }

  public let id: UUID
  public let role: Role
  public let text: String

  public init(id: UUID = UUID(), role: Role, text: String) {
    self.id = id
    self.role = role
    self.text = text
  }
}

public enum CodexModelSelection: Equatable, Sendable {
  case latest
  case modelID(String)
}

public enum CodexReasoningEffort: String, CaseIterable, Equatable, Sendable {
  case none
  case low
  case medium
  case high
  case xhigh
  case max
}

public struct CodexRequest: Equatable, Sendable {
  public var messages: [CodexMessage]
  public var model: CodexModelSelection
  public var reasoningEffort: CodexReasoningEffort?
  public var instructions: String

  /// Identifies the conversation this request belongs to.
  ///
  /// Codex scopes its session, thread, and prompt-cache identifiers to one
  /// conversation. Reuse the same value for every turn of a conversation and
  /// create a new one for each new conversation.
  public var threadID: UUID

  public init(
    messages: [CodexMessage],
    model: CodexModelSelection = .latest,
    reasoningEffort: CodexReasoningEffort? = nil,
    instructions: String = "Reply directly to the user. No tools are available.",
    threadID: UUID = UUID()
  ) {
    self.messages = messages
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.instructions = instructions
    self.threadID = threadID
  }

  public init(
    prompt: String,
    history: [CodexMessage] = [],
    model: CodexModelSelection = .latest,
    reasoningEffort: CodexReasoningEffort? = nil,
    instructions: String = "Reply directly to the user. No tools are available.",
    threadID: UUID = UUID()
  ) {
    self.init(
      messages: history + [CodexMessage(role: .user, text: prompt)],
      model: model,
      reasoningEffort: reasoningEffort,
      instructions: instructions,
      threadID: threadID
    )
  }
}

public struct CodexResponse: Equatable, Sendable {
  public let text: String
  public let model: String

  public init(text: String, model: String) {
    self.text = text
    self.model = model
  }
}

public enum CodexStreamEvent: Equatable, Sendable {
  case responseStarted(model: String)
  case textDelta(String)
  case completed(CodexResponse)
}
