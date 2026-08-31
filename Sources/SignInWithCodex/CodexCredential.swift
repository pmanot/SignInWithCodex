import Foundation

struct CodexCredential: Codable, Equatable, Sendable {
  let accessToken: String
  let refreshToken: String
  let idToken: String
  let accountID: String
  let planType: String?
  let expiresAt: Date?
  let obtainedAt: Date
}

protocol CredentialStoring: AnyObject {
  func load() throws -> CodexCredential?
  func save(_ credential: CodexCredential) throws
  func delete() throws
}
