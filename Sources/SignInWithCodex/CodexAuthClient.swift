import CryptoKit
import Foundation
import Security

struct CodexAuthConfiguration: Sendable {
  let issuer: URL
  let clientID: String
  let scope: String
  let originator: String

  static let current = CodexAuthConfiguration(
    // Source: OpenAI Codex `codex-rs/login/src/server.rs`.
    issuer: URL(string: "https://auth.openai.com")!,
    // Source: OpenAI Codex `codex-rs/login/src/auth/manager.rs` (`CLIENT_ID`).
    clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
    // Source: OpenAI Codex `codex-rs/login/src/server.rs` (`build_authorize_url`).
    scope: "openid profile email offline_access api.connectors.read api.connectors.invoke",
    // Source: OpenAI Codex `codex-rs/login/src/auth/default_client.rs`.
    originator: "codex_cli_rs"
  )
}

struct CodexAuthClient: Sendable {
  typealias RandomBytes = @Sendable (Int) throws -> Data

  private let session: URLSession
  private let configuration: CodexAuthConfiguration
  private let now: @Sendable () -> Date
  private let randomBytes: RandomBytes

  init(
    session: URLSession = .shared,
    configuration: CodexAuthConfiguration = .current,
    now: @escaping @Sendable () -> Date = { Date() },
    randomBytes: @escaping RandomBytes = {
      try CodexAuthClient.secureRandomBytes(count: $0)
    }
  ) {
    self.session = session
    self.configuration = configuration
    self.now = now
    self.randomBytes = randomBytes
  }

  func makeAuthorization(
    redirectURL: URL,
    preferredProvider: CodexLoginProvider? = nil
  ) throws -> CodexAuthorization {
    let verifier = base64URL(try randomBytes(64))
    let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    let state = base64URL(try randomBytes(32))
    // Source: OpenAI Codex `codex-rs/login/src/server.rs` (`build_authorize_url`).
    var queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: configuration.clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
      URLQueryItem(name: "scope", value: configuration.scope),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "id_token_add_organizations", value: "true"),
      URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "originator", value: configuration.originator),
    ]
    if let preferredProvider {
      queryItems.append(
        URLQueryItem(name: "connection", value: preferredProvider.rawValue)
      )
    }

    return CodexAuthorization(
      authorizationURL: try endpoint("/oauth/authorize", queryItems: queryItems),
      redirectURL: redirectURL,
      state: state,
      codeVerifier: verifier
    )
  }

  func completeAuthorization(
    callbackURL: URL,
    authorization: CodexAuthorization
  ) async throws -> CodexCredential {
    guard authorization.matchesCallback(callbackURL),
      let components = URLComponents(
        url: callbackURL,
        resolvingAgainstBaseURL: false
      )
    else {
      throw SignInWithCodexError.invalidURL
    }

    let values = Dictionary(
      components.queryItems?.compactMap { item in
        item.value.map { (item.name, $0) }
      } ?? [],
      uniquingKeysWith: { first, _ in first }
    )

    guard values["state"] == authorization.state else {
      throw SignInWithCodexError.callbackStateMismatch
    }
    if let error = values["error"], !error.isEmpty {
      throw SignInWithCodexError.authorizationRejected(
        code: error,
        description: values["error_description"]
      )
    }
    guard let code = values["code"], !code.isEmpty else {
      throw SignInWithCodexError.callbackMissingCode
    }

    return try credential(
      from: await exchangeAuthorizationCode(
        code,
        redirectURL: authorization.redirectURL,
        codeVerifier: authorization.codeVerifier
      )
    )
  }

  func needsRefresh(_ credential: CodexCredential) -> Bool {
    if let expiresAt = credential.expiresAt {
      return expiresAt <= now().addingTimeInterval(60)
    }
    return credential.obtainedAt <= now().addingTimeInterval(-8 * 24 * 60 * 60)
  }

  func refreshCredential(_ credential: CodexCredential) async throws -> CodexCredential {
    var request = URLRequest(url: try endpoint("/oauth/token"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "client_id": configuration.clientID,
      "grant_type": "refresh_token",
      "refresh_token": credential.refreshToken,
    ])

    let (data, response) = try await session.data(for: request)
    try validate(response, operation: "Token refresh", data: data)
    let object = try decodeObject(data)
    let tokens = OAuthTokens(
      idToken: object["id_token"] as? String ?? credential.idToken,
      accessToken: object["access_token"] as? String ?? credential.accessToken,
      refreshToken: object["refresh_token"] as? String ?? credential.refreshToken
    )
    return try self.credential(from: tokens)
  }

  private func exchangeAuthorizationCode(
    _ code: String,
    redirectURL: URL,
    codeVerifier: String
  ) async throws -> OAuthTokens {
    var request = URLRequest(url: try endpoint("/oauth/token"))
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )

    var form = URLComponents()
    form.queryItems = [
      URLQueryItem(name: "grant_type", value: "authorization_code"),
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
      URLQueryItem(name: "client_id", value: configuration.clientID),
      URLQueryItem(name: "code_verifier", value: codeVerifier),
    ]
    request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

    let (data, response) = try await session.data(for: request)
    try validate(response, operation: "Token exchange", data: data)
    let object = try decodeObject(data)
    guard let idToken = object["id_token"] as? String,
      let accessToken = object["access_token"] as? String,
      let refreshToken = object["refresh_token"] as? String
    else {
      throw SignInWithCodexError.invalidResponse
    }
    return OAuthTokens(
      idToken: idToken,
      accessToken: accessToken,
      refreshToken: refreshToken
    )
  }

  private func credential(from tokens: OAuthTokens) throws -> CodexCredential {
    let idMetadata = JWTMetadata.decode(tokens.idToken)
    let accessMetadata = JWTMetadata.decode(tokens.accessToken)
    guard let accountID = idMetadata?.accountID ?? accessMetadata?.accountID else {
      throw SignInWithCodexError.missingAccountID
    }

    return CodexCredential(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      idToken: tokens.idToken,
      accountID: accountID,
      planType: accessMetadata?.planType ?? idMetadata?.planType,
      expiresAt: accessMetadata?.expiresAt ?? idMetadata?.expiresAt,
      obtainedAt: now()
    )
  }

  private func endpoint(
    _ path: String,
    queryItems: [URLQueryItem]? = nil
  ) throws -> URL {
    guard
      var components = URLComponents(
        url: configuration.issuer,
        resolvingAgainstBaseURL: false
      )
    else {
      throw SignInWithCodexError.invalidURL
    }
    components.path = path
    components.queryItems = queryItems
    guard let url = components.url else {
      throw SignInWithCodexError.invalidURL
    }
    return url
  }

  private func validate(
    _ response: URLResponse,
    operation: String,
    data: Data
  ) throws {
    guard let http = response as? HTTPURLResponse else {
      throw SignInWithCodexError.invalidResponse
    }
    if http.statusCode == 401 {
      throw SignInWithCodexError.unauthorized
    }
    guard (200..<300).contains(http.statusCode) else {
      throw SignInWithCodexError.httpStatus(
        operation: operation,
        status: http.statusCode,
        message: String(data: data, encoding: .utf8).map {
          String($0.prefix(500))
        }
      )
    }
  }

  private func decodeObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SignInWithCodexError.invalidResponse
    }
    return object
  }

  private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func secureRandomBytes(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else {
      throw SignInWithCodexError.randomGenerationFailed(status)
    }
    return Data(bytes)
  }
}

private struct OAuthTokens: Sendable {
  let idToken: String
  let accessToken: String
  let refreshToken: String
}
