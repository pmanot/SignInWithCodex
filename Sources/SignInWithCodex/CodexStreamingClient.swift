import Foundation

struct CodexStreamingClient: Sendable {
  typealias EventHandler = @Sendable (CodexStreamEvent) async -> Void

  private struct ModelsResponse: Decodable {
    let models: [Model]
  }

  fileprivate struct Model: Decodable, Sendable {
    struct ReasoningLevel: Decodable, Sendable {
      let effort: String
    }

    let slug: String
    let priority: Int?
    let visibility: String?
    let defaultReasoningLevel: String?
    let supportsReasoningSummaries: Bool?
    let defaultVerbosity: String?
    let useResponsesLite: Bool?
    let supportedReasoningLevels: [ReasoningLevel]?

    private enum CodingKeys: String, CodingKey {
      case slug
      case priority
      case visibility
      case defaultReasoningLevel = "default_reasoning_level"
      case supportsReasoningSummaries = "supports_reasoning_summaries"
      case defaultVerbosity = "default_verbosity"
      case useResponsesLite = "use_responses_lite"
      case supportedReasoningLevels = "supported_reasoning_levels"
    }
  }

  // Source: OpenAI Codex tag `rust-v0.147.0`. See `COMPATIBILITY.md`.
  static let compatibleCodexVersion = "0.147.0"
  // Source: the OpenAI model guide linked from `COMPATIBILITY.md`.
  static let fallbackLatestModel = "gpt-5.6-sol"

  // Source: OpenAI Codex `codex-rs/core/src/client.rs`.
  private static let responsesLiteHeader =
    "x-openai-internal-codex-responses-lite"
  // Source: OpenAI Codex `codex-rs/model-provider-info/src/lib.rs`.
  private static let defaultBaseURL = URL(
    string: "https://chatgpt.com/backend-api/codex"
  )!
  // Source: OpenAI Codex `codex-rs/login/src/auth/default_client.rs`.
  private static let upstreamOriginator = "codex_cli_rs"

  private let session: URLSession
  private let baseURL: URL
  private let clientVersion: String
  private let installationID: String
  private let catalog: ModelCatalogCache

  init(
    session: URLSession = .shared,
    baseURL: URL = Self.defaultBaseURL,
    clientVersion: String = Self.compatibleCodexVersion,
    installationID: String = UUID().uuidString,
    catalogTTL: TimeInterval = 10 * 60
  ) {
    self.session = session
    self.baseURL = baseURL
    self.clientVersion = clientVersion
    self.installationID = installationID
    catalog = ModelCatalogCache(ttl: catalogTTL)
  }

  func perform(
    _ codexRequest: CodexRequest,
    credential: CodexCredential,
    onEvent: @escaping EventHandler
  ) async throws -> CodexResponse {
    guard
      codexRequest.messages.contains(where: {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      throw SignInWithCodexError.emptyRequest
    }

    let model = try await resolveModel(
      codexRequest.model,
      credential: credential
    )
    // Source: OpenAI Codex `codex-rs/core/src/client.rs`. Upstream sends the
    // thread identifier as the session, thread, and client request ids, and
    // derives the window id from it.
    let threadID = codexRequest.threadID.uuidString.lowercased()
    let windowID = "\(threadID):0"
    var request = URLRequest(url: endpoint("responses"))
    request.httpMethod = "POST"
    addCommonHeaders(to: &request, credential: credential)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(threadID, forHTTPHeaderField: "session-id")
    request.setValue(threadID, forHTTPHeaderField: "thread-id")
    request.setValue(threadID, forHTTPHeaderField: "x-client-request-id")
    request.setValue(windowID, forHTTPHeaderField: "x-codex-window-id")
    if model.useResponsesLite == true {
      request.setValue("true", forHTTPHeaderField: Self.responsesLiteHeader)
    }
    request.httpBody = try responseBody(
      for: codexRequest,
      model: model,
      threadID: threadID,
      windowID: windowID
    )

    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw SignInWithCodexError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      var data = Data()
      for try await byte in bytes {
        data.append(byte)
      }
      try validate(response, operation: "Codex request", data: data)
      throw SignInWithCodexError.invalidResponse
    }

    await onEvent(.responseStarted(model: model.slug))

    var stream = StreamState()
    var dataLines: [String] = []
    var lineData = Data()
    for try await byte in bytes {
      guard byte == 0x0A else {
        lineData.append(byte)
        continue
      }
      if lineData.last == 0x0D {
        lineData.removeLast()
      }
      guard let line = String(data: lineData, encoding: .utf8) else {
        throw SignInWithCodexError.invalidResponse
      }
      lineData.removeAll(keepingCapacity: true)
      if line.isEmpty {
        try await consume(dataLines, into: &stream, onEvent: onEvent)
        dataLines.removeAll(keepingCapacity: true)
        // Source: OpenAI Codex `codex-rs/codex-api/src/sse/responses.rs`.
        // `response.completed` ends the response; do not wait for the
        // server to close the connection.
        if stream.isCompleted {
          break
        }
      } else if line.hasPrefix("data:") {
        dataLines.append(
          String(line.dropFirst(5).drop(while: { $0 == " " }))
        )
      }
    }
    if !stream.isCompleted {
      if !lineData.isEmpty {
        if lineData.last == 0x0D {
          lineData.removeLast()
        }
        guard let line = String(data: lineData, encoding: .utf8) else {
          throw SignInWithCodexError.invalidResponse
        }
        if line.hasPrefix("data:") {
          dataLines.append(
            String(line.dropFirst(5).drop(while: { $0 == " " }))
          )
        }
      }
      try await consume(dataLines, into: &stream, onEvent: onEvent)
    }

    // A stream that ends without `response.completed` is an error, not a
    // short answer.
    guard stream.isCompleted else {
      throw SignInWithCodexError.streamClosedBeforeCompletion
    }
    guard !stream.output.isEmpty else {
      if !stream.refusal.isEmpty {
        throw SignInWithCodexError.refused(stream.refusal)
      }
      throw SignInWithCodexError.missingOutput
    }
    let result = CodexResponse(text: stream.output, model: model.slug)
    await onEvent(.completed(result))
    return result
  }

  private struct StreamState {
    var output = ""
    var refusal = ""
    var isCompleted = false
  }

  /// Selects a model from the cached catalog.
  ///
  /// `.latest` falls back to `fallbackLatestModel` only when the catalog
  /// request itself fails (network or HTTP error). A catalog that decodes
  /// incorrectly, a 401, or an explicit `.modelID` that the catalog does not
  /// list are reported as errors instead of silently substituted.
  private func resolveModel(
    _ selection: CodexModelSelection,
    credential: CodexCredential
  ) async throws -> Model {
    let models: [Model]
    do {
      models = try await catalog.models(for: credential.accountID) {
        try await fetchCatalog(credential: credential)
      }
    } catch SignInWithCodexError.unauthorized {
      throw SignInWithCodexError.unauthorized
    } catch let error as DecodingError {
      throw SignInWithCodexError.catalogDecodingFailed(String(describing: error))
    } catch {
      guard case .latest = selection else { throw error }
      return fallbackLatestModel()
    }

    switch selection {
    case .latest:
      if let visible = models.first(where: { $0.visibility == "list" }) ?? models.first {
        return visible
      }
      return fallbackLatestModel()
    case .modelID(let identifier):
      guard let selected = models.first(where: { $0.slug == identifier }) else {
        throw SignInWithCodexError.unknownModel(identifier)
      }
      return selected
    }
  }

  private func fetchCatalog(credential: CodexCredential) async throws -> [Model] {
    var components = URLComponents(
      url: endpoint("models"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "client_version", value: clientVersion)
    ]
    var request = URLRequest(url: components.url!)
    addCommonHeaders(to: &request, credential: credential)
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    try validate(response, operation: "Codex model discovery", data: data)
    let models = try JSONDecoder().decode(ModelsResponse.self, from: data).models
    // Source: OpenAI Codex `codex-rs/models-manager/src/manager.rs`.
    // Ascending priority; catalog order breaks ties.
    return models.enumerated().sorted { left, right in
      let leftPriority = left.element.priority ?? Int.max
      let rightPriority = right.element.priority ?? Int.max
      if leftPriority == rightPriority {
        return left.offset < right.offset
      }
      return leftPriority < rightPriority
    }.map(\.element)
  }

  /// The model used for `.latest` when the catalog is unreachable. Its
  /// capabilities are assumed, not read from a catalog.
  private func fallbackLatestModel() -> Model {
    Model(
      slug: Self.fallbackLatestModel,
      priority: 0,
      visibility: "list",
      defaultReasoningLevel: "medium",
      supportsReasoningSummaries: true,
      defaultVerbosity: nil,
      useResponsesLite: true,
      supportedReasoningLevels: CodexReasoningEffort.allCases.map {
        Model.ReasoningLevel(effort: $0.rawValue)
      }
    )
  }

  private func addCommonHeaders(
    to request: inout URLRequest,
    credential: CodexCredential
  ) {
    request.setValue(
      "Bearer \(credential.accessToken)",
      forHTTPHeaderField: "Authorization"
    )
    request.setValue(
      credential.accountID,
      forHTTPHeaderField: "ChatGPT-Account-ID"
    )
    request.setValue(Self.upstreamOriginator, forHTTPHeaderField: "originator")
    request.setValue(clientVersion, forHTTPHeaderField: "version")
    request.setValue(
      "\(Self.upstreamOriginator)/\(clientVersion) (SignInWithCodex/0.1)",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue(
      installationID,
      forHTTPHeaderField: "x-codex-installation-id"
    )
  }

  private func responseBody(
    for request: CodexRequest,
    model: Model,
    threadID: String,
    windowID: String
  ) throws -> Data {
    var input: [[String: Any]] = request.messages.map { message in
      [
        "type": "message",
        "role": message.role.rawValue,
        "content": [
          [
            "type": message.role == .assistant
              ? "output_text"
              : "input_text",
            "text": message.text,
          ]
        ],
      ]
    }

    if model.useResponsesLite == true {
      input.insert(
        contentsOf: [
          [
            "type": "additional_tools",
            "role": "developer",
            "tools": [],
          ],
          [
            "type": "message",
            "role": "developer",
            "content": [
              [
                "type": "input_text",
                "text": request.instructions,
              ]
            ],
          ],
        ],
        at: 0
      )
    }

    var body: [String: Any] = [
      "model": model.slug,
      "input": input,
      "tool_choice": "auto",
      "parallel_tool_calls": false,
      "store": false,
      "stream": true,
      "include": [],
      "prompt_cache_key": threadID,
      "client_metadata": [
        "x-codex-installation-id": installationID,
        "session_id": threadID,
        "thread_id": threadID,
        "x-codex-window-id": windowID,
      ],
    ]

    if model.useResponsesLite != true {
      body["instructions"] = request.instructions
      body["tools"] = []
    }

    if model.supportsReasoningSummaries == true {
      var reasoning: [String: Any] = [
        "effort": reasoningEffort(
          request.reasoningEffort,
          supportedBy: model
        )
      ]
      if model.useResponsesLite == true {
        reasoning["context"] = "all_turns"
      }
      body["reasoning"] = reasoning
      body["include"] = ["reasoning.encrypted_content"]
    } else {
      body["reasoning"] = NSNull()
    }
    if let verbosity = model.defaultVerbosity {
      body["text"] = ["verbosity": verbosity]
    }

    return try JSONSerialization.data(withJSONObject: body)
  }

  private func reasoningEffort(
    _ requested: CodexReasoningEffort?,
    supportedBy model: Model
  ) -> String {
    guard let requested else {
      return model.defaultReasoningLevel ?? "medium"
    }
    let supported = model.supportedReasoningLevels?.map(\.effort) ?? []
    guard supported.isEmpty || supported.contains(requested.rawValue) else {
      return model.defaultReasoningLevel ?? "medium"
    }
    return requested.rawValue
  }

  private func consume(
    _ dataLines: [String],
    into stream: inout StreamState,
    onEvent: @escaping EventHandler
  ) async throws {
    let payload = dataLines.joined(separator: "\n")
    guard !payload.isEmpty, payload != "[DONE]",
      let eventData = payload.data(using: .utf8),
      let event = try? JSONSerialization.jsonObject(
        with: eventData
      ) as? [String: Any]
    else {
      return
    }

    switch event["type"] as? String {
    case "response.output_text.delta":
      let delta = event["delta"] as? String ?? ""
      if !delta.isEmpty {
        stream.output += delta
        await onEvent(.textDelta(delta))
      }
    case "response.refusal.delta":
      stream.refusal += event["delta"] as? String ?? ""
    case "response.completed":
      stream.isCompleted = true
      if let response = event["response"] as? [String: Any] {
        if stream.output.isEmpty {
          let text = outputText(in: response, part: "output_text", key: "text")
          if !text.isEmpty {
            stream.output = text
            await onEvent(.textDelta(text))
          }
        }
        if stream.refusal.isEmpty {
          stream.refusal = outputText(in: response, part: "refusal", key: "refusal")
        }
      }
    case "response.failed":
      let response = event["response"] as? [String: Any]
      let error = response?["error"] as? [String: Any]
      throw SignInWithCodexError.streamFailed(
        error?["message"] as? String ?? "Unknown backend error"
      )
    case "response.incomplete":
      throw SignInWithCodexError.streamFailed("The response was incomplete.")
    case "error":
      let error = event["error"] as? [String: Any]
      throw SignInWithCodexError.streamFailed(
        error?["message"] as? String
          ?? event["message"] as? String
          ?? "Unknown stream error"
      )
    default:
      break
    }
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
        message: serverMessage(data)
      )
    }
  }

  /// Concatenates the `key` field of every content part of type `part`.
  private func outputText(
    in response: [String: Any],
    part: String,
    key: String
  ) -> String {
    let items = response["output"] as? [[String: Any]] ?? []
    return items.flatMap { item -> [String] in
      let content = item["content"] as? [[String: Any]] ?? []
      return content.compactMap {
        $0["type"] as? String == part ? $0[key] as? String : nil
      }
    }.joined()
  }

  private func serverMessage(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    else {
      return String(data: data, encoding: .utf8).map {
        String($0.prefix(500))
      }
    }
    if let error = json["error"] as? [String: Any],
      let message = error["message"] as? String
    {
      return message
    }
    return json["detail"] as? String ?? json["message"] as? String
  }

  private func endpoint(_ path: String) -> URL {
    baseURL.appendingPathComponent(path)
  }
}

/// Caches the model catalog so that consecutive requests do not each pay a
/// discovery round trip. The catalog depends on the account's plan, so the
/// cache holds one entry and discards it when another account asks.
/// Concurrent misses for the same account share one fetch. A failed fetch is
/// not cached.
private actor ModelCatalogCache {
  typealias Models = [CodexStreamingClient.Model]

  private struct Entry {
    let accountID: String
    let models: Models
    let fetchedAt: Date
  }

  private struct InFlight {
    let accountID: String
    let task: Task<Models, Error>
  }

  private let ttl: TimeInterval
  private var entry: Entry?
  private var inFlight: InFlight?

  init(ttl: TimeInterval) {
    self.ttl = ttl
  }

  func models(
    for accountID: String,
    fetch: @escaping @Sendable () async throws -> Models
  ) async throws -> Models {
    if let entry, entry.accountID == accountID,
      Date().timeIntervalSince(entry.fetchedAt) < ttl
    {
      return entry.models
    }
    if let inFlight, inFlight.accountID == accountID {
      return try await inFlight.task.value
    }

    let task = Task { try await fetch() }
    inFlight = InFlight(accountID: accountID, task: task)
    defer {
      if inFlight?.task == task {
        inFlight = nil
      }
    }
    let fresh = try await task.value
    entry = Entry(accountID: accountID, models: fresh, fetchedAt: Date())
    return fresh
  }
}
