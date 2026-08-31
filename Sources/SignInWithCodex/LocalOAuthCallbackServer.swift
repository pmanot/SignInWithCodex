import Darwin
import Foundation

final class LocalOAuthCallbackServer: @unchecked Sendable {
  typealias Callback = @Sendable (URL) -> Void

  // Source: OpenAI Codex `codex-rs/login/src/server.rs` (`DEFAULT_PORT` and `FALLBACK_PORT`).
  private static let ports: [UInt16] = [1455, 1457]

  let redirectURL: URL

  private let callback: Callback
  private let queue: DispatchQueue
  private var listenerSources: [DispatchSourceRead] = []
  private var clients: [Int32: ClientConnection] = [:]
  private var expectedState: String?
  private var didReceiveCallback = false

  private init(
    fileDescriptors: [Int32],
    port: UInt16,
    callback: @escaping Callback
  ) {
    self.callback = callback
    queue = DispatchQueue(label: "dev.signinwithcodex.callback.\(port)")
    redirectURL = URL(string: "http://localhost:\(port)/auth/callback")!

    for fileDescriptor in fileDescriptors {
      let source = DispatchSource.makeReadSource(
        fileDescriptor: fileDescriptor,
        queue: queue
      )
      source.setEventHandler { [weak self] in
        self?.acceptConnections(from: fileDescriptor)
      }
      source.setCancelHandler {
        Darwin.close(fileDescriptor)
      }
      listenerSources.append(source)
      source.resume()
    }
  }

  static func start(callback: @escaping Callback) throws -> LocalOAuthCallbackServer {
    for port in ports {
      if let server = try? bind(port: port, callback: callback) {
        return server
      }
    }
    throw SignInWithCodexError.callbackServerUnavailable
  }

  /// Sets the OAuth `state` value that a callback must carry.
  ///
  /// Callbacks that arrive before this is set, or that carry another value,
  /// are answered with `400` and do not consume the sign-in attempt.
  func expect(state: String) {
    queue.async { [weak self] in
      self?.expectedState = state
    }
  }

  func stop() {
    for source in listenerSources {
      source.cancel()
    }
    queue.async { [weak self] in
      guard let self else { return }
      for client in clients.values {
        client.source.cancel()
      }
      clients.removeAll()
    }
  }

  private static func bind(
    port: UInt16,
    callback: @escaping Callback
  ) throws -> LocalOAuthCallbackServer {
    let ipv4Descriptor = try bindIPv4(port: port)
    var fileDescriptors = [ipv4Descriptor]
    if let ipv6Descriptor = try? bindIPv6(port: port) {
      fileDescriptors.append(ipv6Descriptor)
    }
    return LocalOAuthCallbackServer(
      fileDescriptors: fileDescriptors,
      port: port,
      callback: callback
    )
  }

  private static func bindIPv4(port: UInt16) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw SignInWithCodexError.callbackServerUnavailable
    }
    enableAddressReuse(on: descriptor)

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(
          descriptor,
          $0,
          socklen_t(MemoryLayout<sockaddr_in>.size)
        )
      }
    }
    guard result == 0 else {
      Darwin.close(descriptor)
      throw SignInWithCodexError.callbackServerUnavailable
    }
    try finishBinding(descriptor)
    return descriptor
  }

  private static func bindIPv6(port: UInt16) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw SignInWithCodexError.callbackServerUnavailable
    }
    enableAddressReuse(on: descriptor)

    var ipv6Only: Int32 = 1
    setsockopt(
      descriptor,
      IPPROTO_IPV6,
      IPV6_V6ONLY,
      &ipv6Only,
      socklen_t(MemoryLayout<Int32>.size)
    )

    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = in_port_t(port).bigEndian
    address.sin6_addr = in6addr_loopback

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(
          descriptor,
          $0,
          socklen_t(MemoryLayout<sockaddr_in6>.size)
        )
      }
    }
    guard result == 0 else {
      Darwin.close(descriptor)
      throw SignInWithCodexError.callbackServerUnavailable
    }
    try finishBinding(descriptor)
    return descriptor
  }

  private static func enableAddressReuse(on descriptor: Int32) {
    var reuseAddress: Int32 = 1
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_REUSEADDR,
      &reuseAddress,
      socklen_t(MemoryLayout<Int32>.size)
    )
  }

  private static func finishBinding(_ descriptor: Int32) throws {
    guard Darwin.listen(descriptor, SOMAXCONN) == 0 else {
      Darwin.close(descriptor)
      throw SignInWithCodexError.callbackServerUnavailable
    }
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0,
      fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    else {
      Darwin.close(descriptor)
      throw SignInWithCodexError.callbackServerUnavailable
    }
  }

  private func acceptConnections(from listenerDescriptor: Int32) {
    while true {
      let descriptor = Darwin.accept(listenerDescriptor, nil, nil)
      guard descriptor >= 0 else {
        return
      }
      startReading(descriptor)
    }
  }

  private func startReading(_ descriptor: Int32) {
    // A browser that closes the connection early must not raise SIGPIPE and
    // terminate the process; `write` reports EPIPE instead.
    var noSIGPIPE: Int32 = 1
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSIGPIPE,
      socklen_t(MemoryLayout<Int32>.size)
    )
    let client = ClientConnection(fileDescriptor: descriptor, queue: queue)
    clients[descriptor] = client
    client.source.setEventHandler { [weak self, weak client] in
      guard let self, let client else { return }
      receiveRequest(from: client)
    }
    client.source.setCancelHandler {
      Darwin.close(descriptor)
    }
    client.source.resume()
  }

  private func receiveRequest(from client: ClientConnection) {
    var buffer = [UInt8](repeating: 0, count: 16_384)
    let count = Darwin.read(client.fileDescriptor, &buffer, buffer.count)
    if count > 0 {
      client.data.append(buffer, count: count)
      if client.data.range(of: Data("\r\n\r\n".utf8)) != nil {
        handleRequest(client.data, client: client)
      } else if client.data.count > 65_536 {
        close(client)
      }
      return
    }
    if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
      close(client)
    }
  }

  private func handleRequest(_ data: Data, client: ClientConnection) {
    guard let request = String(data: data, encoding: .utf8),
      let firstLine = request.components(separatedBy: "\r\n").first
    else {
      respond(status: 400, body: "Bad Request", to: client)
      return
    }

    let fields = firstLine.split(separator: " ", maxSplits: 2)
    guard fields.count == 3, fields[0] == "GET" else {
      respond(status: 405, body: "Method Not Allowed", to: client)
      return
    }

    let target = String(fields[1])
    guard
      let requestURL = URL(
        string: "\(redirectURL.scheme!)://\(redirectURL.host!):\(redirectURL.port!)\(target)"
      )
    else {
      respond(status: 400, body: "Bad Request", to: client)
      return
    }

    guard requestURL.path == "/auth/callback" else {
      respond(status: 404, body: "Not Found", to: client)
      return
    }
    // Source: OpenAI Codex `codex-rs/login/src/server.rs`. The state check
    // happens before the callback counts, so a stray request cannot end the
    // sign-in attempt.
    let callbackState = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first(where: { $0.name == "state" })?
      .value
    guard let expectedState, let callbackState, !callbackState.isEmpty,
      callbackState == expectedState
    else {
      respond(status: 400, body: "State mismatch", to: client)
      return
    }
    guard !didReceiveCallback else {
      respond(status: 409, body: "Sign-in already completed", to: client)
      return
    }

    didReceiveCallback = true
    callback(requestURL)
    respond(
      status: 200,
      body: Self.successPage,
      contentType: "text/html; charset=utf-8",
      to: client,
      stopAfterResponse: true
    )
  }

  private func respond(
    status: Int,
    body: String,
    contentType: String = "text/plain; charset=utf-8",
    to client: ClientConnection,
    stopAfterResponse: Bool = false
  ) {
    let bodyData = Data(body.utf8)
    let reason =
      switch status {
      case 200: "OK"
      case 400: "Bad Request"
      case 405: "Method Not Allowed"
      case 409: "Conflict"
      default: "Not Found"
      }
    let headers =
      "HTTP/1.1 \(status) \(reason)\r\n"
      + "Content-Type: \(contentType)\r\n"
      + "Content-Length: \(bodyData.count)\r\n"
      + "Connection: close\r\n\r\n"
    var response = Data(headers.utf8)
    response.append(bodyData)
    response.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var sent = 0
      while sent < bytes.count {
        let count = Darwin.write(
          client.fileDescriptor,
          baseAddress.advanced(by: sent),
          bytes.count - sent
        )
        guard count > 0 else { break }
        sent += count
      }
    }

    close(client)
    if stopAfterResponse {
      for source in listenerSources {
        source.cancel()
      }
    }
  }

  private func close(_ client: ClientConnection) {
    guard clients.removeValue(forKey: client.fileDescriptor) != nil else {
      return
    }
    client.source.cancel()
  }

  private static let successPage = """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Sign in with Codex</title>
        <style>
          body { font: 16px system-ui; display: grid; min-height: 100vh;
                 margin: 0; place-items: center; text-align: center; }
          main { padding: 24px; }
        </style>
      </head>
      <body><main><h1>Sign-in received</h1><p>Close this tab and return to the app to finish.</p></main></body>
    </html>
    """
}

private final class ClientConnection: @unchecked Sendable {
  let fileDescriptor: Int32
  let source: DispatchSourceRead
  var data = Data()

  init(fileDescriptor: Int32, queue: DispatchQueue) {
    self.fileDescriptor = fileDescriptor
    source = DispatchSource.makeReadSource(
      fileDescriptor: fileDescriptor,
      queue: queue
    )
  }
}
