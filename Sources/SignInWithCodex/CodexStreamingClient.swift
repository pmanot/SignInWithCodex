import Foundation

struct CodexStreamingClient: Sendable {
  typealias EventHandler = @Sendable (CodexStreamEvent) async -> Void

  private struct ModelsResponse: Decodable {
    let models: [Model]
  }

  private struct Model: Decodable, Sendable {
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
  private let threadID: String

  init(
    session: URLSession = .shared,
    baseURL: URL = Self.defaultBaseURL,
    clientVersion: String = Self.compatibleCodexVersion,
    installationID: String = UUID().uuidString,
    threadID: String = UUID().uuidString
  ) {
    self.session = session
    self.baseURL = baseURL
    self.clientVersion = clientVersion
    self.installationID = installationID
    self.threadID = threadID
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
    request.httpBody = try responseBody(for: codexRequest, model: model)

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

    var output = ""
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
        try await consume(
          dataLines,
          output: &output,
          onEvent: onEvent
        )
        dataLines.removeAll(keepingCapacity: true)
      } else if line.hasPrefix("data:") {
        dataLines.append(
          String(line.dropFirst(5).drop(while: { $0 == " " }))
        )
      }
    }
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
    try await consume(dataLines, output: &output, onEvent: onEvent)

    guard !output.isEmpty else {
      throw SignInWithCodexError.missingOutput
    }
    let result = CodexResponse(text: output, model: model.slug)
    await onEvent(.completed(result))
    return result
  }

  private func resolveModel(
    _ selection: CodexModelSelection,
    credential: CodexCredential
  ) async throws -> Model {
    do {
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
      let sorted = models.enumerated().sorted { left, right in
        let leftPriority = left.element.priority ?? Int.max
        let rightPriority = right.element.priority ?? Int.max
        if leftPriority == rightPriority {
          return left.offset < right.offset
        }
        return leftPriority < rightPriority
      }.map(\.element)

      switch selection {
      case .latest:
        if let visible = sorted.first(where: { $0.visibility == "list" }) {
          return visible
        }
        if let first = sorted.first {
          return first
        }
      case .modelID(let identifier):
        if let selected = sorted.first(where: { $0.slug == identifier }) {
          return selected
        }
      }
    } catch SignInWithCodexError.unauthorized {
      throw SignInWithCodexError.unauthorized
    } catch {
      return fallbackModel(for: selection)
    }

    return fallbackModel(for: selection)
  }

  private func fallbackModel(for selection: CodexModelSelection) -> Model {
    let slug =
      switch selection {
      case .latest:
        Self.fallbackLatestModel
      case .modelID(let identifier):
        identifier
      }
    return Model(
      slug: slug,
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
    model: Model
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
    output: inout String,
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
        output += delta
        await onEvent(.textDelta(delta))
      }
    case "response.completed":
      if output.isEmpty,
        let response = event["response"] as? [String: Any]
      {
        let text = outputText(in: response)
        if !text.isEmpty {
          output = text
          await onEvent(.textDelta(text))
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

  private func outputText(in response: [String: Any]) -> String {
    let items = response["output"] as? [[String: Any]] ?? []
    return items.flatMap { item -> [String] in
      let content = item["content"] as? [[String: Any]] ?? []
      return content.compactMap { part in
        guard part["type"] as? String == "output_text" else {
          return nil
        }
        return part["text"] as? String
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

  private var windowID: String {
    "\(threadID):0"
  }
}
