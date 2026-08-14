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

  public init(
    messages: [CodexMessage],
    model: CodexModelSelection = .latest,
    reasoningEffort: CodexReasoningEffort? = nil,
    instructions: String = "Reply directly to the user. No tools are available."
  ) {
    self.messages = messages
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.instructions = instructions
  }

  public init(
    prompt: String,
    history: [CodexMessage] = [],
    model: CodexModelSelection = .latest,
    reasoningEffort: CodexReasoningEffort? = nil,
    instructions: String = "Reply directly to the user. No tools are available."
  ) {
    self.init(
      messages: history + [CodexMessage(role: .user, text: prompt)],
      model: model,
      reasoningEffort: reasoningEffort,
      instructions: instructions
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

public enum SignInWithCodexError: LocalizedError, Equatable, Sendable {
  case notSignedIn
  case unauthorized
  case invalidResponse
  case invalidURL
  case emptyRequest
  case missingAccountID
  case callbackStateMismatch
  case callbackMissingCode
  case callbackServerUnavailable
  case authorizationRejected(code: String, description: String?)
  case httpStatus(operation: String, status: Int, message: String?)
  case streamFailed(String)
  case missingOutput
  case randomGenerationFailed(Int32)
  case keychain(Int32)

  public var errorDescription: String? {
    switch self {
    case .notSignedIn:
      return "Sign in with Codex before you send a request."
    case .unauthorized:
      return "Codex rejected the access token."
    case .invalidResponse:
      return "Codex returned an invalid response."
    case .invalidURL:
      return "The Codex authentication URL is invalid."
    case .emptyRequest:
      return "Add at least one nonempty message to the request."
    case .missingAccountID:
      return "The Codex credential does not contain a ChatGPT account identifier."
    case .callbackStateMismatch:
      return "The sign-in callback state does not match the request."
    case .callbackMissingCode:
      return "The sign-in callback does not contain an authorization code."
    case .callbackServerUnavailable:
      return "The app cannot start the local Codex callback server."
    case .authorizationRejected(let code, let description):
      if let description, !description.isEmpty {
        return "Codex rejected sign-in (\(code)): \(description)"
      }
      return "Codex rejected sign-in with OAuth error \(code)."
    case .httpStatus(let operation, let status, let message):
      if let message, !message.isEmpty {
        return "\(operation) failed with HTTP status \(status): \(message)"
      }
      return "\(operation) failed with HTTP status \(status)."
    case .streamFailed(let message):
      return "The Codex response failed: \(message)"
    case .missingOutput:
      return "Codex completed the request without text output."
    case .randomGenerationFailed(let status):
      return "Secure random generation failed with status \(status)."
    case .keychain(let status):
      return "Keychain failed with status \(status)."
    }
  }
}

struct CodexCredential: Codable, Equatable, Sendable {
  let accessToken: String
  let refreshToken: String
  let idToken: String
  let accountID: String
  let planType: String?
  let expiresAt: Date?
  let obtainedAt: Date
}
