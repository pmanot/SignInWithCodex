import Foundation
import XCTest

@testable import SignInWithCodex

final class SignInWithCodexTests: XCTestCase {
  override func tearDown() {
    URLProtocolStub.handler = nil
    super.tearDown()
  }

  func testAuthorizationMatchesPinnedCodexFlow() throws {
    let client = CodexAuthClient(
      randomBytes: { count in
        Data((0..<count).map { UInt8($0 % 251) })
      }
    )
    let redirectURL = URL(string: "http://localhost:1455/auth/callback")!
    let authorization = try client.makeAuthorization(
      redirectURL: redirectURL,
      preferredProvider: .apple
    )
    let components = try XCTUnwrap(
      URLComponents(
        url: authorization.authorizationURL,
        resolvingAgainstBaseURL: false
      )
    )
    let values = Dictionary(
      uniqueKeysWithValues: components.queryItems?.compactMap { item in
        item.value.map { (item.name, $0) }
      } ?? []
    )

    XCTAssertEqual(components.host, "auth.openai.com")
    XCTAssertEqual(components.path, "/oauth/authorize")
    XCTAssertEqual(values["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
    XCTAssertEqual(values["redirect_uri"], redirectURL.absoluteString)
    XCTAssertEqual(values["code_challenge_method"], "S256")
    XCTAssertEqual(values["codex_cli_simplified_flow"], "true")
    XCTAssertEqual(values["originator"], "codex_cli_rs")
    XCTAssertEqual(values["connection"], "apple")
    XCTAssertFalse(try XCTUnwrap(values["state"]).isEmpty)
    XCTAssertFalse(try XCTUnwrap(values["code_challenge"]).isEmpty)
  }

  func testCallbackRejectsMismatchedStateBeforeTokenExchange() async throws {
    let client = CodexAuthClient(
      randomBytes: { Data(repeating: 7, count: $0) }
    )
    let redirectURL = URL(string: "http://localhost:1455/auth/callback")!
    let authorization = try client.makeAuthorization(redirectURL: redirectURL)
    let callback = URL(
      string: "http://localhost:1455/auth/callback?code=test&state=wrong"
    )!

    do {
      _ = try await client.completeAuthorization(
        callbackURL: callback,
        authorization: authorization
      )
      XCTFail("The callback must fail.")
    } catch let error as SignInWithCodexError {
      XCTAssertEqual(error, .callbackStateMismatch)
    }
  }

  func testCallbackExchangesCodeAndReadsAccountMetadata() async throws {
    let session = makeSession()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let accessToken = try makeJWT(
      accountID: "account-123",
      planType: "plus",
      expiration: now.addingTimeInterval(3_600)
    )
    let idToken = try makeJWT(
      accountID: "account-123",
      planType: nil,
      expiration: now.addingTimeInterval(3_600)
    )
    URLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.path, "/oauth/token")
      XCTAssertEqual(request.httpMethod, "POST")
      let form = String(data: try requestBody(request), encoding: .utf8)
      XCTAssertTrue(try XCTUnwrap(form).contains("code=test-code"))
      XCTAssertTrue(try XCTUnwrap(form).contains("code_verifier="))
      return StubResponse.json(
        [
          "id_token": idToken,
          "access_token": accessToken,
          "refresh_token": "refresh-token",
        ],
        request: request
      )
    }

    let client = CodexAuthClient(
      session: session,
      now: { now },
      randomBytes: { Data(repeating: 9, count: $0) }
    )
    let redirectURL = URL(string: "http://localhost:1455/auth/callback")!
    let authorization = try client.makeAuthorization(redirectURL: redirectURL)
    var callback = URLComponents(
      url: redirectURL,
      resolvingAgainstBaseURL: false
    )!
    callback.queryItems = [
      URLQueryItem(name: "code", value: "test-code"),
      URLQueryItem(name: "state", value: authorization.state),
    ]

    let credential = try await client.completeAuthorization(
      callbackURL: try XCTUnwrap(callback.url),
      authorization: authorization
    )

    XCTAssertEqual(credential.accountID, "account-123")
    XCTAssertEqual(credential.planType, "plus")
    XCTAssertEqual(credential.refreshToken, "refresh-token")
    XCTAssertEqual(credential.expiresAt, now.addingTimeInterval(3_600))
  }

  func testLatestModelUsesCatalogPriorityAndStreamsDeltas() async throws {
    let session = makeSession()
    URLProtocolStub.handler = { request in
      switch request.url?.path {
      case "/backend-api/codex/models":
        return StubResponse.json(
          [
            "models": [
              [
                "slug": "hidden-model",
                "priority": 0,
                "visibility": "hide",
              ],
              [
                "slug": "gpt-5.6-sol",
                "priority": 1,
                "visibility": "list",
                "default_reasoning_level": "medium",
                "supports_reasoning_summaries": true,
                "use_responses_lite": true,
                "supported_reasoning_levels": [
                  ["effort": "low"],
                  ["effort": "medium"],
                ],
              ],
              [
                "slug": "older-model",
                "priority": 2,
                "visibility": "list",
              ],
            ]
          ],
          request: request
        )
      case "/backend-api/codex/responses":
        let body = try requestBody(request)
        let json = try XCTUnwrap(
          JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "gpt-5.6-sol")
        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "medium")
        return StubResponse.sse(
          """
          data: {"type":"response.output_text.delta","delta":"Hello"}

          data: {"type":"response.output_text.delta","delta":" world"}

          data: {"type":"response.completed","response":{"output":[]}}

          data: [DONE]

          """,
          request: request
        )
      default:
        XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
        return StubResponse(status: 404, data: Data(), headers: [:])
      }
    }

    let client = CodexStreamingClient(
      session: session,
      installationID: "installation-test",
      threadID: "thread-test"
    )
    let collector = EventCollector()
    let result = try await client.perform(
      CodexRequest(prompt: "Hello"),
      credential: credential,
      onEvent: { event in
        await collector.append(event)
      }
    )

    XCTAssertEqual(result, CodexResponse(text: "Hello world", model: "gpt-5.6-sol"))
    let events = await collector.events
    XCTAssertEqual(
      events,
      [
        .responseStarted(model: "gpt-5.6-sol"),
        .textDelta("Hello"),
        .textDelta(" world"),
        .completed(
          CodexResponse(text: "Hello world", model: "gpt-5.6-sol")
        ),
      ]
    )
  }

  func testLatestModelUsesCurrentFallbackAfterCatalogFailure() async throws {
    let session = makeSession()
    URLProtocolStub.handler = { request in
      switch request.url?.path {
      case "/backend-api/codex/models":
        return StubResponse(
          status: 500,
          data: Data("catalog unavailable".utf8),
          headers: [:]
        )
      case "/backend-api/codex/responses":
        let body = try requestBody(request)
        let json = try XCTUnwrap(
          JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(
          json["model"] as? String,
          CodexStreamingClient.fallbackLatestModel
        )
        return StubResponse.sse(
          """
          data: {"type":"response.completed","response":{"output":[{"content":[{"type":"output_text","text":"Fallback reply"}]}]}}

          """,
          request: request
        )
      default:
        return StubResponse(status: 404, data: Data(), headers: [:])
      }
    }

    let client = CodexStreamingClient(session: session)
    let result = try await client.perform(
      CodexRequest(prompt: "Hello"),
      credential: credential,
      onEvent: { _ in }
    )

    XCTAssertEqual(result.model, "gpt-5.6-sol")
    XCTAssertEqual(result.text, "Fallback reply")
  }

  private var credential: CodexCredential {
    CodexCredential(
      accessToken: "access-token",
      refreshToken: "refresh-token",
      idToken: "id-token",
      accountID: "account-id",
      planType: "plus",
      expiresAt: Date().addingTimeInterval(3_600),
      obtainedAt: Date()
    )
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    return URLSession(configuration: configuration)
  }

  private func makeJWT(
    accountID: String,
    planType: String?,
    expiration: Date
  ) throws -> String {
    let header = try JSONSerialization.data(withJSONObject: ["alg": "none"])
    var authentication: [String: Any] = [
      "chatgpt_account_id": accountID
    ]
    if let planType {
      authentication["chatgpt_plan_type"] = planType
    }
    let payload = try JSONSerialization.data(withJSONObject: [
      "https://api.openai.com/auth": authentication,
      "exp": expiration.timeIntervalSince1970,
    ])
    return "\(base64URL(header)).\(base64URL(payload)).signature"
  }

  private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

private func requestBody(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody {
    return body
  }
  let stream = try XCTUnwrap(request.httpBodyStream)
  stream.open()
  defer { stream.close() }

  var body = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 {
      throw try XCTUnwrap(stream.streamError)
    }
    if count == 0 {
      break
    }
    body.append(buffer, count: count)
  }
  return body
}

private actor EventCollector {
  private(set) var events: [CodexStreamEvent] = []

  func append(_ event: CodexStreamEvent) {
    events.append(event)
  }
}

private struct StubResponse {
  let status: Int
  let data: Data
  let headers: [String: String]

  static func json(
    _ object: Any,
    request: URLRequest
  ) -> StubResponse {
    StubResponse(
      status: 200,
      data: try! JSONSerialization.data(withJSONObject: object),
      headers: ["Content-Type": "application/json"]
    )
  }

  static func sse(_ body: String, request: URLRequest) -> StubResponse {
    StubResponse(
      status: 200,
      data: Data(body.utf8),
      headers: ["Content-Type": "text/event-stream"]
    )
  }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> StubResponse)?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    do {
      let handler = try XCTUnwrap(Self.handler)
      let result = try handler(request)
      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: result.status,
          httpVersion: "HTTP/1.1",
          headerFields: result.headers
        )
      )
      client?.urlProtocol(
        self,
        didReceive: response,
        cacheStoragePolicy: .notAllowed
      )
      client?.urlProtocol(self, didLoad: result.data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
