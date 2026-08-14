import Foundation

struct JWTMetadata: Equatable {
  let accountID: String?
  let planType: String?
  let expiresAt: Date?

  static func decode(_ token: String) -> JWTMetadata? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2,
      let payload = decodeBase64URL(String(parts[1])),
      let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    else {
      return nil
    }

    // Source: OpenAI Codex `codex-rs/login/src/token_data.rs` (`TokenData`).
    let auth = object["https://api.openai.com/auth"] as? [String: Any]
    let expiration = (object["exp"] as? NSNumber).map {
      Date(timeIntervalSince1970: $0.doubleValue)
    }
    return JWTMetadata(
      accountID: auth?["chatgpt_account_id"] as? String,
      planType: auth?["chatgpt_plan_type"] as? String,
      expiresAt: expiration
    )
  }

  private static func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
      base64.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: base64)
  }
}
