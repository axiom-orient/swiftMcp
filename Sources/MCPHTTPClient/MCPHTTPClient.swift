@preconcurrency import Foundation
import MCP
import MCPHTTPShared

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// HTTP header collection used by the public HTTP client configuration.
public typealias MCPHTTPHeaders = MCPHTTPShared.MCPHTTPHeaders

public protocol MCPHTTPAuthorizationProvider: Sendable {
  func authorizationHeader(for resource: URL) async throws -> String?
}

/// A non-JSON-RPC HTTP `401 Unauthorized` response.
///
/// The transport never retries the MCP request. A host may inspect the challenge, complete an
/// optional authorization flow, and explicitly decide whether to issue a new request.
public struct MCPHTTPUnauthorizedResponse: MCPClientTransportFailure, Equatable,
  CustomStringConvertible
{
  public let wwwAuthenticate: String?
  public let body: String?

  public init(wwwAuthenticate: String?, body: String?) {
    self.wwwAuthenticate = wwwAuthenticate
    self.body = body
  }

  public var description: String {
    "MCP HTTP 401 Unauthorized\(body.map { ": \($0)" } ?? "")"
  }
}

public struct MCPStaticBearerTokenProvider: MCPHTTPAuthorizationProvider {
  private let token: String

  public init(token: String) throws {
    _ = try MCPHTTPAuthorizationHeader.bearer(token: token)
    self.token = token
  }

  public func authorizationHeader(for resource: URL) async throws -> String? {
    try MCPHTTPAuthorizationHeader.bearer(token: token)
  }
}

public struct MCPHTTPRejectedTool: Sendable, Equatable {
  public let name: String
  public let reason: String

  public init(name: String, reason: String) {
    self.name = name
    self.reason = reason
  }
}

// The catalog is shared by concurrent requests. All mutable dictionaries and
// rejection diagnostics are protected by `lock`.
public final class MCPHTTPToolCatalog: @unchecked Sendable {
  private let lock = NSLock()
  private var schemas: [String: MCPHTTPToolHeaderSchema] = [:]
  private var rejected: [MCPHTTPRejectedTool] = []
  private var generation: UInt64 = 0

  public init() {}

  /// Rejections accumulated while processing the current paginated `tools/list` sequence.
  public var rejectedTools: [MCPHTTPRejectedTool] {
    lock.lock()
    defer { lock.unlock() }
    return rejected
  }

  @discardableResult
  public func registerValidTools(
    _ tools: [MCPTool],
    requestedCursor: String? = nil,
    expectedGeneration: UInt64? = nil
  ) -> [MCPTool] {
    var accepted: [MCPTool] = []
    var nextSchemas: [String: MCPHTTPToolHeaderSchema] = [:]
    var nextRejected: [MCPHTTPRejectedTool] = []
    for tool in tools {
      do {
        let schema = try MCPHTTPToolHeaderSchema(tool: tool)
        accepted.append(tool)
        nextSchemas[tool.name] = schema
      } catch {
        nextRejected.append(
          MCPHTTPRejectedTool(name: tool.name, reason: String(describing: error)))
      }
    }
    lock.lock()
    if let expectedGeneration, generation != expectedGeneration {
      lock.unlock()
      return accepted
    }
    if requestedCursor == nil {
      schemas = nextSchemas
      rejected = nextRejected
    } else {
      let pageToolNames = Set(tools.map(\.name))
      for name in pageToolNames { schemas.removeValue(forKey: name) }
      schemas.merge(nextSchemas) { _, replacement in replacement }
      rejected.removeAll { pageToolNames.contains($0.name) }
      rejected.append(contentsOf: nextRejected)
    }
    lock.unlock()
    return accepted
  }

  public func register(_ tool: MCPTool) throws {
    let schema = try MCPHTTPToolHeaderSchema(tool: tool)
    lock.lock()
    schemas[tool.name] = schema
    rejected.removeAll { $0.name == tool.name }
    lock.unlock()
  }

  public func schema(for toolName: String) -> MCPHTTPToolHeaderSchema? {
    lock.lock()
    defer { lock.unlock() }
    return schemas[toolName]
  }

  func snapshotGeneration() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }

  public func removeAll() {
    lock.lock()
    generation &+= 1
    schemas.removeAll(keepingCapacity: true)
    rejected.removeAll(keepingCapacity: true)
    lock.unlock()
  }
}

public struct MCPHTTPClientConfiguration: Sendable {
  public let endpoint: URL
  public let additionalHeaders: MCPHTTPHeaders
  public let authorizationProvider: (any MCPHTTPAuthorizationProvider)?
  public let jsonLimits: MCPJSONLimits
  public let maximumResponseBytes: Int
  public let maximumEventBytes: Int
  public let networkTimeout: TimeInterval
  /// Wall-clock timeout used by FoundationNetworking for long-lived subscription responses.
  /// Hosts may increase it or choose a deliberately shorter reconnect boundary.
  public let subscriptionTimeout: TimeInterval

  public init(
    endpoint: URL,
    additionalHeaders: MCPHTTPHeaders = MCPHTTPHeaders(),
    authorizationProvider: (any MCPHTTPAuthorizationProvider)? = nil,
    jsonLimits: MCPJSONLimits = .default,
    maximumResponseBytes: Int = MCPJSONLimits.default.maximumDocumentBytes,
    maximumEventBytes: Int = MCPJSONLimits.default.maximumDocumentBytes,
    networkTimeout: TimeInterval = 60,
    subscriptionTimeout: TimeInterval = 7 * 24 * 60 * 60
  ) throws {
    guard let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme),
      endpoint.host != nil, endpoint.fragment == nil
    else { throw MCPHTTPError.invalidEndpoint }
    try jsonLimits.validate()
    try additionalHeaders.validate()
    guard maximumResponseBytes > 0, maximumEventBytes > 0,
      networkTimeout.isFinite, networkTimeout > 0,
      subscriptionTimeout.isFinite, subscriptionTimeout > 0
    else {
      throw MCPHTTPError.io("HTTP limits and timeout must be positive")
    }
    let reserved = Set(
      [
        MCPHTTPHeaderName.protocolVersion,
        MCPHTTPHeaderName.method,
        MCPHTTPHeaderName.name,
        "content-type",
        "accept",
        "authorization",
        // These headers belong to pre-2026 session/resume transports and must never be emitted by
        // the strict stateless client, even when supplied as arbitrary additional headers.
        "mcp-session-id",
        "last-event-id",
      ].map { $0.lowercased() })
    for name in additionalHeaders.values.keys {
      let normalizedName = name.lowercased()
      guard !reserved.contains(normalizedName),
        !normalizedName.hasPrefix(MCPHTTPHeaderName.parameterPrefix.lowercased())
      else {
        throw MCPHTTPError.headerMismatch("additional headers cannot override \(name)")
      }
    }
    self.endpoint = endpoint
    self.additionalHeaders = additionalHeaders
    self.authorizationProvider = authorizationProvider
    self.jsonLimits = jsonLimits
    self.maximumResponseBytes = maximumResponseBytes
    self.maximumEventBytes = maximumEventBytes
    self.networkTimeout = networkTimeout
    self.subscriptionTimeout = subscriptionTimeout
  }
}

// URLSession delegate callbacks may be concurrent. All exchange state is
// protected by `lock`; stream continuations are completed at most once.
final class MCPHTTPExchangeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private enum Mode {
    case awaitingResponse
    case json
    case sse
    case errorStatus(Int)
    case failed
  }

  private let lock = NSLock()
  private let request: MCPWireRequest
  private let catalog: MCPHTTPToolCatalog
  private let catalogGeneration: UInt64?
  private let jsonLimits: MCPJSONLimits
  private let maximumResponseBytes: Int
  private let continuation: AsyncThrowingStream<MCPWireMessage, Error>.Continuation
  private var mode: Mode = .awaitingResponse
  private var buffer = Data()
  private var receivedBodyBytes = 0
  private var sse: MCPSSEDecoder
  private var completed = false
  private var responseHeaders = MCPHTTPHeaders()
  private weak var session: URLSession?
  private weak var task: URLSessionTask?

  init(
    request: MCPWireRequest,
    catalog: MCPHTTPToolCatalog,
    catalogGeneration: UInt64? = nil,
    jsonLimits: MCPJSONLimits,
    maximumResponseBytes: Int,
    maximumEventBytes: Int,
    continuation: AsyncThrowingStream<MCPWireMessage, Error>.Continuation
  ) throws {
    self.request = request
    self.catalog = catalog
    self.catalogGeneration = catalogGeneration
    self.jsonLimits = jsonLimits
    self.maximumResponseBytes = maximumResponseBytes
    self.continuation = continuation
    self.sse = try MCPSSEDecoder(maximumEventBytes: maximumEventBytes)
  }

  func install(session: URLSession) {
    lock.lock()
    self.session = session
    lock.unlock()
  }

  func install(session: URLSession, task: URLSessionTask) {
    lock.lock()
    self.session = session
    self.task = task
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    fail(MCPHTTPError.redirectRejected(request.url?.absoluteString))
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      fail(MCPHTTPError.io("response is not HTTP"))
      completionHandler(.cancel)
      return
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      headers[String(describing: key)] = String(describing: value)
    }
    let normalizedHeaders = MCPHTTPHeaders(headers)
    do {
      try normalizedHeaders.validate()
    } catch {
      fail(error)
      completionHandler(.cancel)
      return
    }
    lock.lock()
    responseHeaders = normalizedHeaders
    if !(200...299).contains(http.statusCode) {
      mode = .errorStatus(http.statusCode)
      lock.unlock()
      completionHandler(.allow)
      return
    }
    let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
      .split(separator: ";", maxSplits: 1).first.map(String.init)
    switch contentType {
    case "application/json": mode = .json
    case "text/event-stream": mode = .sse
    default:
      mode = .failed
      lock.unlock()
      fail(MCPHTTPError.unsupportedContentType(contentType))
      completionHandler(.cancel)
      return
    }
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    let current = mode
    switch current {
    case .json, .errorStatus:
      guard data.count <= maximumResponseBytes - receivedBodyBytes else {
        lock.unlock()
        fail(MCPHTTPError.responseTooLarge(maximumResponseBytes))
        dataTask.cancel()
        return
      }
      receivedBodyBytes += data.count
      buffer.append(data)
      lock.unlock()
    case .sse:
      do {
        let events = try sse.append(data)
        lock.unlock()
        for event in events { deliver(event) }
      } catch {
        lock.unlock()
        fail(error)
        dataTask.cancel()
      }
    case .awaitingResponse, .failed:
      lock.unlock()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
        fail(CancellationError())
      } else {
        fail(MCPHTTPError.io(error.localizedDescription))
      }
      invalidate()
      return
    }

    lock.lock()
    let current = mode
    let finalBuffer = buffer
    let headers = responseHeaders
    lock.unlock()

    switch current {
    case .json:
      deliver(finalBuffer)
      finish()
    case .sse:
      do {
        _ = try sse.finish()
        finish()
      } catch {
        fail(error)
      }
    case .errorStatus(let status):
      do {
        let message = try MCPWireMessage.decode(finalBuffer, limits: jsonLimits)
        guard case .error = message else {
          throw MCPHTTPError.invalidStatus(status, body: nil)
        }
        yield(message)
        finish()
      } catch {
        let text = String(data: finalBuffer, encoding: .utf8)
        let authentication = headers["www-authenticate"]
        if status == 401 {
          fail(
            MCPHTTPUnauthorizedResponse(
              wwwAuthenticate: authentication,
              body: text
            ))
        } else {
          fail(MCPHTTPError.invalidStatus(status, body: text))
        }
      }
    case .awaitingResponse:
      fail(MCPHTTPError.connectionClosed)
    case .failed:
      break
    }
    invalidate()
  }

  private func deliver(_ data: Data) {
    do {
      var message = try MCPWireMessage.decode(data, limits: jsonLimits)
      if request.method == "tools/list", case .result(let result) = message {
        let decoded = try MCPListToolsResult(json: .object(result.value))
        let requestedCursor = try MCPListToolsParams(json: .object(request.params)).cursor
        let accepted = catalog.registerValidTools(
          decoded.tools,
          requestedCursor: requestedCursor,
          expectedGeneration: catalogGeneration
        )
        if accepted.count != decoded.tools.count {
          let filtered = MCPListToolsResult(
            tools: accepted,
            nextCursor: decoded.nextCursor,
            cache: decoded.cache,
            metadata: decoded.metadata
          )
          message = .result(
            MCPWireResult(
              id: result.id, resultType: .complete, value: filtered.json.objectValue ?? [:])
          )
        }
      }
      yield(message)
    } catch {
      fail(error)
    }
  }

  private func yield(_ message: MCPWireMessage) {
    switch continuation.yield(message) {
    case .enqueued:
      break
    case .dropped:
      fail(MCPHTTPError.io("HTTP exchange frame buffer overflow"))
    case .terminated:
      break
    @unknown default:
      fail(MCPHTTPError.io("unknown HTTP exchange stream state"))
    }
  }

  private func finish() {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    lock.unlock()
    continuation.finish()
  }

  private func fail(_ error: Error) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    mode = .failed
    let task = self.task
    self.session = nil
    self.task = nil
    lock.unlock()
    continuation.finish(throwing: error)
    // A malformed response, redirect, or bound violation must stop only this task. The transport
    // owns one reusable URLSession so cancelling the whole session would abort unrelated
    // request-scoped exchanges and discard the connection pool.
    task?.cancel()
  }

  private func invalidate() {
    lock.lock()
    self.session = nil
    self.task = nil
    lock.unlock()
  }
}

/// Multiplexes request-scoped exchange delegates onto one transport-owned URLSession.
/// URLSession callbacks can arrive concurrently, so task routing is lock-protected and each
/// exchange retains ownership of its own parser and continuation state.
final class MCPHTTPSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var exchanges: [Int: MCPHTTPExchangeDelegate] = [:]
  private weak var session: URLSession?

  func install(session: URLSession) {
    lock.lock()
    self.session = session
    let delegates = Array(exchanges.values)
    lock.unlock()
    for delegate in delegates { delegate.install(session: session) }
  }

  func register(_ delegate: MCPHTTPExchangeDelegate, task: URLSessionDataTask) {
    lock.lock()
    exchanges[task.taskIdentifier] = delegate
    let session = self.session
    lock.unlock()
    if let session { delegate.install(session: session, task: task) }
  }

  private func exchange(for task: URLSessionTask) -> MCPHTTPExchangeDelegate? {
    lock.lock()
    defer { lock.unlock() }
    return exchanges[task.taskIdentifier]
  }

  private func unregister(_ task: URLSessionTask) {
    lock.lock()
    exchanges.removeValue(forKey: task.taskIdentifier)
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let exchange = exchange(for: task) else {
      completionHandler(nil)
      return
    }
    exchange.urlSession(
      session,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: request,
      completionHandler: completionHandler
    )
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let exchange = exchange(for: dataTask) else {
      completionHandler(.cancel)
      return
    }
    exchange.urlSession(
      session,
      dataTask: dataTask,
      didReceive: response,
      completionHandler: completionHandler
    )
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    exchange(for: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let exchange = exchange(for: task) else { return }
    exchange.urlSession(session, task: task, didCompleteWithError: error)
    unregister(task)
  }
}

// Immutable request factory. Shared mutable tool metadata is delegated to the
// lock-protected `MCPHTTPToolCatalog`.
public final class MCPHTTPClientTransport: MCPClientToolCatalogInvalidatingTransport,
  MCPClientRegistryReportingTransport,
  @unchecked Sendable
{
  public let endpointIdentity: String
  public let configuration: MCPHTTPClientConfiguration
  public let toolCatalog: MCPHTTPToolCatalog
  public let registry: MCPMethodRegistry
  private let sessionDelegate: MCPHTTPSessionDelegate
  private let session: URLSession

  public init(
    configuration: MCPHTTPClientConfiguration,
    registry: MCPMethodRegistry = .standard,
    toolCatalog: MCPHTTPToolCatalog = MCPHTTPToolCatalog()
  ) {
    let sessionDelegate = MCPHTTPSessionDelegate()
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.timeoutIntervalForRequest = configuration.networkTimeout
    let session = URLSession(
      configuration: sessionConfiguration,
      delegate: sessionDelegate,
      delegateQueue: nil
    )
    sessionDelegate.install(session: session)
    self.configuration = configuration
    self.registry = registry
    self.toolCatalog = toolCatalog
    self.sessionDelegate = sessionDelegate
    self.session = session
    endpointIdentity = configuration.endpoint.absoluteString
  }

  deinit {
    session.invalidateAndCancel()
  }

  public func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    let descriptor = try registry.require(request.method)
    let toolSchema: MCPHTTPToolHeaderSchema?
    if request.method == "tools/call" {
      let params = try MCPCallToolParams(json: .object(request.params))
      toolSchema = toolCatalog.schema(for: params.name)
    } else {
      toolSchema = nil
    }
    var headers = try MCPHTTPStandardHeaders.make(
      for: request,
      descriptor: descriptor,
      toolSchema: toolSchema
    )
    headers.merge(configuration.additionalHeaders)
    if let authorization = try await configuration.authorizationProvider?.authorizationHeader(
      for: configuration.endpoint)
    {
      headers["Authorization"] = authorization
    }
    try headers.validate()

    // `subscriptions/listen` is intentionally a long-lived SSE response. FoundationNetworking on
    // Linux treats `timeoutIntervalForRequest` as a wall-clock deadline rather than resetting it
    // for SSE comment keep-alives, so applying the ordinary request timeout would terminate a
    // healthy subscription. Cancellation remains explicit through the returned exchange.
    let transportTimeout =
      request.method == "subscriptions/listen"
      ? configuration.subscriptionTimeout : configuration.networkTimeout
    var urlRequest = URLRequest(url: configuration.endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = transportTimeout
    urlRequest.httpBody = try MCPWireMessage.request(request).encoded()
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    for (name, value) in headers.values {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(4_096))
    let delegate = try MCPHTTPExchangeDelegate(
      request: request,
      catalog: toolCatalog,
      catalogGeneration: request.method == "tools/list" ? toolCatalog.snapshotGeneration() : nil,
      jsonLimits: configuration.jsonLimits,
      maximumResponseBytes: configuration.maximumResponseBytes,
      maximumEventBytes: configuration.maximumEventBytes,
      continuation: pair.continuation
    )
    let task = session.dataTask(with: urlRequest)
    sessionDelegate.register(delegate, task: task)
    task.resume()
    pair.continuation.onTermination = { @Sendable [weak task] _ in
      task?.cancel()
    }

    return MCPClientExchange(
      frames: pair.stream,
      cancel: { reason in
        _ = reason
        task.cancel()
      }
    )
  }

  public func invalidateToolCatalog() async {
    toolCatalog.removeAll()
  }
}
