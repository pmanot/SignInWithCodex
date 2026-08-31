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
        ]
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
    let threadID = UUID()
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
          ]
        )
      case "/backend-api/codex/responses":
        let body = try requestBody(request)
        let json = try XCTUnwrap(
          JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "gpt-5.6-sol")
        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "medium")
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "thread-id"),
          threadID.uuidString.lowercased()
        )
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "x-client-request-id"),
          threadID.uuidString.lowercased()
        )
        XCTAssertEqual(
          json["prompt_cache_key"] as? String,
          threadID.uuidString.lowercased()
        )
        return StubResponse.sse(
          """
          data: {"type":"response.output_text.delta","delta":"Hello"}

          data: {"type":"response.output_text.delta","delta":" world"}

          data: {"type":"response.completed","response":{"output":[]}}

          data: [DONE]

          """
        )
      default:
        XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
        return StubResponse(status: 404, data: Data(), headers: [:])
      }
    }

    let client = CodexStreamingClient(
      session: session,
      installationID: "installation-test"
    )
    let collector = EventCollector()
    let result = try await client.perform(
      CodexRequest(prompt: "Hello", threadID: threadID),
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

          """
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

  func testCatalogIsCachedAcrossRequests() async throws {
    let session = makeSession()
    let counter = Counter()
    URLProtocolStub.handler = { request in
      switch request.url?.path {
      case "/backend-api/codex/models":
        counter.increment()
        return StubResponse.json(
          ["models": [["slug": "m1", "priority": 0, "visibility": "list"]]]
        )
      default:
        return StubResponse.sse(completedStream)
      }
    }

    let client = CodexStreamingClient(session: session)
    for _ in 0..<3 {
      _ = try await client.perform(
        CodexRequest(prompt: "Hi"), credential: credential, onEvent: { _ in }
      )
    }
    XCTAssertEqual(counter.value, 1)
  }

  func testConcurrentCatalogMissesShareOneFetch() async throws {
    let session = makeSession()
    let counter = Counter()
    URLProtocolStub.handler = { request in
      switch request.url?.path {
      case "/backend-api/codex/models":
        counter.increment()
        // Keep the first fetch in flight long enough for the others to miss.
        Thread.sleep(forTimeInterval: 0.1)
        return StubResponse.json(
          ["models": [["slug": "m1", "priority": 0, "visibility": "list"]]]
        )
      default:
        return StubResponse.sse(completedStream)
      }
    }

    let client = CodexStreamingClient(session: session)
    let credential = self.credential
    try await withThrowingTaskGroup(of: Void.self) { group in
      for prompt in ["a", "b", "c"] {
        group.addTask {
          _ = try await client.perform(
            CodexRequest(prompt: prompt), credential: credential, onEvent: { _ in }
          )
        }
      }
      try await group.waitForAll()
    }
    XCTAssertEqual(counter.value, 1)
  }

  func testCatalogCacheIsScopedToTheAccount() async throws {
    let session = makeSession()
    let counter = Counter()
    URLProtocolStub.handler = { request in
      switch request.url?.path {
      case "/backend-api/codex/models":
        counter.increment()
        return StubResponse.json(
          ["models": [["slug": "m1", "priority": 0, "visibility": "list"]]]
        )
      default:
        return StubResponse.sse(completedStream)
      }
    }

    let client = CodexStreamingClient(session: session)
    let first = credential
    let second = CodexCredential(
      accessToken: "other-access",
      refreshToken: "other-refresh",
      idToken: "other-id",
      accountID: "other-account",
      planType: "pro",
      expiresAt: first.expiresAt,
      obtainedAt: first.obtainedAt
    )
    for credential in [first, first, second, second, first] {
      _ = try await client.perform(
        CodexRequest(prompt: "Hi"), credential: credential, onEvent: { _ in }
      )
    }
    XCTAssertEqual(counter.value, 3)
  }

  func testStreamClosedBeforeCompletionIsAnError() async throws {
    let session = makeSession()
    URLProtocolStub.handler = { request in
      switch request.url?.path {
      case "/backend-api/codex/models":
        return StubResponse.json(
          ["models": [["slug": "m1", "priority": 0, "visibility": "list"]]]
        )
      default:
        return StubResponse.sse(
          """
          data: {"type":"response.output_text.delta","delta":"Half an"}

          data: {"type":"response.output_text.delta","delta":" answer"}

          """
        )
      }
    }

    let client = CodexStreamingClient(session: session)
    let collector = EventCollector()
    do {
      _ = try await client.perform(
        CodexRequest(prompt: "Hi"),
        credential: credential,
        onEvent: { event in
          await collector.append(event)
        }
      )
      XCTFail("A stream without response.completed must fail.")
    } catch let error as SignInWithCodexError {
      XCTAssertEqual(error, .streamClosedBeforeCompletion)
    }
    let events = await collector.events
    XCTAssertEqual(
      events,
      [
        .responseStarted(model: "m1"),
        .textDelta("Half an"),
        .textDelta(" answer"),
      ]
    )
  }

  func testEachRequestCarriesItsOwnThreadID() async throws {
    let session = makeSession()
    let seenThreadIDs = ValueBox<[String]>([])
    URLProtocolStub.handler = { request in
      switch request.url?.path {
      case "/backend-api/codex/models":
        return StubResponse.json(
          ["models": [["slug": "m1", "priority": 0, "visibility": "list"]]]
        )
      default:
        let json = try XCTUnwrap(
          JSONSerialization.jsonObject(with: try requestBody(request))
            as? [String: Any]
        )
        let metadata = try XCTUnwrap(json["client_metadata"] as? [String: Any])
        let header = try XCTUnwrap(request.value(forHTTPHeaderField: "thread-id"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "session-id"), header)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-codex-window-id"), "\(header):0")
        XCTAssertEqual(metadata["thread_id"] as? String, header)
        XCTAssertEqual(metadata["session_id"] as? String, header)
        XCTAssertEqual(json["prompt_cache_key"] as? String, header)
        seenThreadIDs.update { $0.append(header) }
        return StubResponse.sse(completedStream)
      }
    }

    let client = CodexStreamingClient(session: session)
    let conversation = UUID()
    for request in [
      CodexRequest(prompt: "a", threadID: conversation),
      CodexRequest(prompt: "b", threadID: conversation),
      CodexRequest(prompt: "c"),
    ] {
      _ = try await client.perform(request, credential: credential, onEvent: { _ in })
    }

    let ids = seenThreadIDs.value
    XCTAssertEqual(ids.count, 3)
    XCTAssertEqual(ids[0], conversation.uuidString.lowercased())
    XCTAssertEqual(ids[1], ids[0])
    XCTAssertNotEqual(ids[2], ids[0])
  }

  func testCallbackServerRejectsWrongStateWithoutConsumingSignIn() async throws {
    let received = ValueBox<[URL]>([])
    let server = try LocalOAuthCallbackServer.start { url in
      received.update { $0.append(url) }
    }
    defer { server.stop() }
    server.expect(state: "expected-state")

    func get(_ query: String) async throws -> (status: Int, body: String) {
      let url = try XCTUnwrap(URL(string: server.redirectURL.absoluteString + query))
      let (data, response) = try await URLSession.shared.data(from: url)
      let http = try XCTUnwrap(response as? HTTPURLResponse)
      return (http.statusCode, String(decoding: data, as: UTF8.self))
    }

    let missing = try await get("?code=stray")
    XCTAssertEqual(missing.status, 400)
    let wrong = try await get("?code=stray&state=wrong-state")
    XCTAssertEqual(wrong.status, 400)
    XCTAssertEqual(wrong.body, "State mismatch")
    XCTAssertTrue(received.value.isEmpty)

    let accepted = try await get("?code=real&state=expected-state")
    XCTAssertEqual(accepted.status, 200)
    XCTAssertTrue(accepted.body.contains("Sign-in received"))
    let urls = received.value
    XCTAssertEqual(urls.count, 1)
    XCTAssertEqual(
      urls.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems?.first(where: { $0.name == "code" })?.value,
      "real"
    )
  }

  func testUnknownModelIDIsAnError() async throws {
    let session = makeSession()
    URLProtocolStub.handler = { request in
      StubResponse.json(
        ["models": [["slug": "m1", "priority": 0, "visibility": "list"]]]
      )
    }

    let client = CodexStreamingClient(session: session)
    do {
      _ = try await client.perform(
        CodexRequest(prompt: "Hi", model: .modelID("nope")),
        credential: credential,
        onEvent: { _ in }
      )
      XCTFail("An unlisted model must fail.")
    } catch let error as SignInWithCodexError {
      XCTAssertEqual(error, .unknownModel("nope"))
    }
  }

  @MainActor
  func testConcurrentStreamsShareOneRefreshAndRejectionEvictsCredential() async throws {
    let session = makeSession()
    let refreshes = Counter()
    let store = MemoryCredentialStore()
    let expired = CodexCredential(
      accessToken: "old", refreshToken: "old-refresh", idToken: "id-token",
      accountID: "account-id", planType: nil,
      expiresAt: Date().addingTimeInterval(-60), obtainedAt: Date()
    )
    try store.save(expired)

    URLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.path, "/oauth/token")
      refreshes.increment()
      return StubResponse(
        status: 401, data: Data("invalid_grant".utf8), headers: [:]
      )
    }

    let codex = CodexSession(
      authClient: CodexAuthClient(session: session),
      streamingClient: CodexStreamingClient(session: session),
      credentialStore: store
    )
    XCTAssertTrue(codex.isSignedIn)

    async let first: Void = drain(codex.stream(prompt: "a"))
    async let second: Void = drain(codex.stream(prompt: "b"))
    _ = await (first, second)

    XCTAssertEqual(refreshes.value, 1)
    XCTAssertFalse(codex.isSignedIn)
    XCTAssertEqual(codex.state, .signedOut)
    XCTAssertNil(try store.load())
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

private func drain(_ stream: AsyncThrowingStream<CodexStreamEvent, Error>) async {
  do {
    for try await _ in stream {}
  } catch {}
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

private let completedStream = """
  data: {"type":"response.output_text.delta","delta":"ok"}

  data: {"type":"response.completed","response":{"output":[]}}

  """

private final class ValueBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

private final class MemoryCredentialStore: CredentialStoring {
  private var stored: CodexCredential?
  func load() throws -> CodexCredential? { stored }
  func save(_ credential: CodexCredential) throws { stored = credential }
  func delete() throws { stored = nil }
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

  static func json(_ object: Any) -> StubResponse {
    StubResponse(
      status: 200,
      data: try! JSONSerialization.data(withJSONObject: object),
      headers: ["Content-Type": "application/json"]
    )
  }

  static func sse(_ body: String) -> StubResponse {
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
