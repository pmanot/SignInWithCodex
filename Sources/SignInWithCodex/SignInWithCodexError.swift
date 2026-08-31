import Foundation

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
  case streamClosedBeforeCompletion
  case refused(String)
  case missingOutput
  case unknownModel(String)
  case catalogDecodingFailed(String)
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
    case .streamClosedBeforeCompletion:
      return "Codex closed the stream before the response completed."
    case .refused(let reason):
      return "Codex declined the request: \(reason)"
    case .missingOutput:
      return "Codex completed the request without text output."
    case .unknownModel(let identifier):
      return "The Codex model catalog does not list \"\(identifier)\"."
    case .catalogDecodingFailed(let detail):
      return "The Codex model catalog could not be decoded: \(detail)"
    case .randomGenerationFailed(let status):
      return "Secure random generation failed with status \(status)."
    case .keychain(let status):
      return "Keychain failed with status \(status)."
    }
  }
}
