import Foundation
import Security

final class KeychainCredentialStore: CredentialStoring {
  private let service: String
  private let account = "codex-chatgpt"

  init(service: String? = nil) {
    self.service =
      service
      ?? "\(Bundle.main.bundleIdentifier ?? "SignInWithCodex").credentials"
  }

  func load() throws -> CodexCredential? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      throw SignInWithCodexError.keychain(status)
    }
    return try JSONDecoder().decode(CodexCredential.self, from: data)
  }

  func save(_ credential: CodexCredential) throws {
    let data = try JSONEncoder().encode(credential)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      attributes as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw SignInWithCodexError.keychain(updateStatus)
    }

    var insert = baseQuery
    for (key, value) in attributes {
      insert[key] = value
    }
    let addStatus = SecItemAdd(insert as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw SignInWithCodexError.keychain(addStatus)
    }
  }

  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SignInWithCodexError.keychain(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }
}
