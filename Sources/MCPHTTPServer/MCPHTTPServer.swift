import Dispatch
import Foundation
import MCP
import MCPHTTPShared

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// HTTP header collection used by the public HTTP server response API.
public typealias MCPHTTPHeaders = MCPHTTPShared.MCPHTTPHeaders

public enum MCPHTTPServerError: Error, Sendable, Equatable, CustomStringConvertible {
  case alreadyRunning
  case notRunning
  case invalidConfiguration(String)
  case invalidRequest(String)
  case payloadTooLarge
  case methodNotAllowed
  case endpointNotFound
  case originRejected(String?)
  case socket(String)
  case connection(String)

  public var description: String {
    switch self {
    case .alreadyRunning: "MCP HTTP server is already running"
    case .notRunning: "MCP HTTP server is not running"
    case .invalidConfiguration(let reason): "Invalid MCP HTTP server configuration: \(reason)"
    case .invalidRequest(let reason): "Invalid HTTP request: \(reason)"
    case .payloadTooLarge: "MCP HTTP request body is too large"
    case .methodNotAllowed: "MCP HTTP endpoint accepts POST only"
    case .endpointNotFound: "MCP HTTP endpoint not found"
    case .originRejected(let origin): "Rejected Origin \(origin ?? "<missing>")"
    case .socket(let reason): "MCP HTTP socket error: \(reason)"
    case .connection(let reason): "MCP HTTP connection error: \(reason)"
    }
  }
}

public struct MCPHTTPAuthenticationChallenge: Sendable, Hashable, CustomStringConvertible {
  public let value: String

  public init(_ value: String) throws {
    guard Self.isValid(value) else {
      throw MCPHTTPServerError.invalidConfiguration(
        "WWW-Authenticate challenge must be non-empty visible ASCII without surrounding whitespace"
      )
    }
    self.value = value
  }

  private init(validated value: String) { self.value = value }

  public static let bearer = MCPHTTPAuthenticationChallenge(validated: "Bearer")

  public var description: String { value }

  private static func isValid(_ value: String) -> Bool {
    guard !value.isEmpty, value.first != " ", value.first != "\t", value.last != " ",
      value.last != "\t"
    else { return false }
    return value.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
  }
}

/// A deliberate HTTP authorization decision. Transport authorization failures are represented by
/// HTTP status and `WWW-Authenticate`; they are not MCP JSON-RPC errors.
public enum MCPHTTPAuthorizationFailure: Error, Sendable, Hashable {
  case unauthorized(MCPHTTPAuthenticationChallenge)
  case forbidden(MCPHTTPAuthenticationChallenge?)
}

public struct MCPHTTPRequest: Sendable {
  public let method: String
  public let target: String
  public let headers: MCPHTTPHeaders
  public let body: Data
  public let remoteAddress: String?

  public init(
    method: String,
    target: String,
    headers: MCPHTTPHeaders,
    body: Data,
    remoteAddress: String? = nil
  ) {
    self.method = method
    self.target = target
    self.headers = headers
    self.body = body
    self.remoteAddress = remoteAddress
  }
}

public struct MCPHTTPResponseStream: Sendable {
  public let chunks: AsyncThrowingStream<Data, Error>
  private let cancelValue: @Sendable () async -> Void

  public init(
    chunks: AsyncThrowingStream<Data, Error>,
    cancel: @escaping @Sendable () async -> Void
  ) {
    self.chunks = chunks
    self.cancelValue = cancel
  }

  public func cancel() async { await cancelValue() }
}

public enum MCPHTTPResponseBody: Sendable {
  case empty
  case bytes(Data)
  case stream(MCPHTTPResponseStream)
}

public struct MCPHTTPResponse: Sendable {
  public let status: Int
  public let headers: MCPHTTPHeaders
  public let body: MCPHTTPResponseBody

  public init(status: Int, headers: MCPHTTPHeaders = MCPHTTPHeaders(), body: MCPHTTPResponseBody) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

public enum MCPHTTPOriginPolicy: Sendable, Hashable {
  /// Accept requests without Origin. When Origin is present it must have the same scheme, host,
  /// and effective port as the trusted effective endpoint. The untrusted Host header is not authority.
  case sameHostOrAbsent
  /// Accept a missing Origin or an exact origin string from the allow-list.
  case allowListedOrAbsent(Set<String>)
  /// Require an exact origin string from the allow-list.
  case requireAllowListed(Set<String>)

  fileprivate func validate(origin: String?, requestEndpoint: URL?) -> Bool {
    switch self {
    case .sameHostOrAbsent:
      guard let origin else { return true }
      guard let requestEndpoint,
        let expectedScheme = requestEndpoint.scheme?.lowercased(),
        let expectedHost = requestEndpoint.host?.lowercased(),
        ["http", "https"].contains(expectedScheme),
        requestEndpoint.user == nil, requestEndpoint.password == nil,
        let originURL = URL(string: origin), originURL.user == nil,
        originURL.password == nil, originURL.query == nil, originURL.fragment == nil,
        originURL.path.isEmpty || originURL.path == "/",
        let originScheme = originURL.scheme?.lowercased(),
        ["http", "https"].contains(originScheme),
        let originHost = originURL.host?.lowercased()
      else { return false }
      guard expectedScheme == originScheme, expectedHost == originHost else { return false }
      let originPort = originURL.port ?? Self.defaultPort(for: originScheme)
      let expectedPort = requestEndpoint.port ?? Self.defaultPort(for: expectedScheme)
      return expectedPort == originPort
    case .allowListedOrAbsent(let allowed):
      guard let origin else { return true }
      return allowed.contains(origin)
    case .requireAllowListed(let allowed):
      guard let origin else { return false }
      return allowed.contains(origin)
    }
  }

  private static func defaultPort(for scheme: String) -> Int {
    scheme == "https" ? 443 : 80
  }
}

public protocol MCPHTTPAuthorizationVerifier: Sendable {
  func authorize(
    headers: MCPHTTPHeaders,
    resource: URL,
    remoteAddress: String?
  ) async throws -> MCPAuthorizationContext
}

public struct MCPHTTPAllowAllAuthorizationVerifier: MCPHTTPAuthorizationVerifier {
  public init() {}

  public func authorize(
    headers: MCPHTTPHeaders,
    resource: URL,
    remoteAddress: String?
  ) async throws -> MCPAuthorizationContext {
    MCPAuthorizationContext()
  }
}

public struct MCPHTTPStaticBearerVerifier: MCPHTTPAuthorizationVerifier {
  private let expectedToken: String
  private let context: MCPAuthorizationContext

  public init(token: String, context: MCPAuthorizationContext) throws {
    guard !token.isEmpty else {
      throw MCPHTTPServerError.invalidConfiguration("bearer token must not be empty")
    }
    expectedToken = token
    self.context = context
  }

  public func authorize(
    headers: MCPHTTPHeaders,
    resource: URL,
    remoteAddress: String?
  ) async throws -> MCPAuthorizationContext {
    guard let raw = headers["authorization"],
      let supplied = MCPHTTPAuthorizationHeader.bearerToken(from: raw)
    else {
      throw MCPHTTPAuthorizationFailure.unauthorized(.bearer)
    }
    guard Self.constantTimeEqual(Array(supplied.utf8), Array(expectedToken.utf8)) else {
      throw MCPHTTPAuthorizationFailure.unauthorized(.bearer)
    }
    return context
  }

  private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    let count = max(lhs.count, rhs.count)
    var difference = lhs.count ^ rhs.count
    for index in 0..<count {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      difference |= Int(left ^ right)
    }
    return difference == 0
  }
}

public struct MCPHTTPConfiguration: Sendable {
  public let bindAddress: String
  public let port: UInt16
  public let endpointPath: String
  public let publicEndpoint: URL?
  public let originPolicy: MCPHTTPOriginPolicy
  public let authorizationVerifier: any MCPHTTPAuthorizationVerifier
  public let jsonLimits: MCPJSONLimits
  public let maximumHeaderBytes: Int
  public let maximumBodyBytes: Int
  public let maximumSSEEventBytes: Int
  public let sseKeepAliveInterval: TimeInterval
  public let requestReadTimeout: TimeInterval
  public let socketTimeout: TimeInterval
  public let maximumConcurrentConnections: Int
  /// Kernel accept backlog. Keep this at or above the expected burst size for the host.
  public let listenBacklog: Int
  public let toolHeaderValidationPolicy: MCPHTTPToolHeaderValidationPolicy

  public init(
    bindAddress: String = "127.0.0.1",
    port: UInt16 = 0,
    endpointPath: String = "/mcp",
    publicEndpoint: URL? = nil,
    originPolicy: MCPHTTPOriginPolicy = .sameHostOrAbsent,
    authorizationVerifier: any MCPHTTPAuthorizationVerifier =
      MCPHTTPAllowAllAuthorizationVerifier(),
    jsonLimits: MCPJSONLimits = .default,
    maximumHeaderBytes: Int = 64 * 1_024,
    maximumBodyBytes: Int = MCPJSONLimits.default.maximumDocumentBytes,
    maximumSSEEventBytes: Int = MCPJSONLimits.default.maximumDocumentBytes,
    sseKeepAliveInterval: TimeInterval = 15,
    requestReadTimeout: TimeInterval = 10,
    socketTimeout: TimeInterval = 60,
    // A connection occupies one blocking worker while an untrusted request is read. The default
    // is deliberately conservative for embedding in a host process; a non-blocking front end or
    // an explicitly sized deployment can raise it after measuring the host's thread budget.
    maximumConcurrentConnections: Int = 32,
    listenBacklog: Int = 128,
    toolHeaderValidationPolicy: MCPHTTPToolHeaderValidationPolicy = .required
  ) throws {
    guard bindAddress == "127.0.0.1" || bindAddress == "0.0.0.0" || Self.isIPv4(bindAddress) else {
      throw MCPHTTPServerError.invalidConfiguration("bindAddress must be an IPv4 literal")
    }
    guard endpointPath.hasPrefix("/"), !endpointPath.contains("?") && !endpointPath.contains("#")
    else {
      throw MCPHTTPServerError.invalidConfiguration("endpointPath must be an absolute path")
    }
    try jsonLimits.validate()
    guard maximumHeaderBytes > 0, maximumBodyBytes > 0, maximumSSEEventBytes > 0,
      sseKeepAliveInterval.isFinite, sseKeepAliveInterval > 0,
      requestReadTimeout.isFinite, requestReadTimeout > 0, requestReadTimeout < Double(Int.max),
      socketTimeout.isFinite, socketTimeout > 0, socketTimeout < Double(Int.max),
      maximumConcurrentConnections > 0,
      listenBacklog > 0, listenBacklog <= Int(Int32.max)
    else {
      throw MCPHTTPServerError.invalidConfiguration("limits and timeout must be positive")
    }
    if let publicEndpoint {
      guard let scheme = publicEndpoint.scheme?.lowercased(), ["http", "https"].contains(scheme),
        publicEndpoint.host != nil, publicEndpoint.fragment == nil
      else { throw MCPHTTPServerError.invalidConfiguration("invalid publicEndpoint") }
    }
    if bindAddress != "127.0.0.1",
      authorizationVerifier is MCPHTTPAllowAllAuthorizationVerifier
    {
      throw MCPHTTPServerError.invalidConfiguration(
        "non-loopback binding requires an explicit authorization verifier"
      )
    }
    self.bindAddress = bindAddress
    self.port = port
    self.endpointPath = endpointPath
    self.publicEndpoint = publicEndpoint
    self.originPolicy = originPolicy
    self.authorizationVerifier = authorizationVerifier
    self.jsonLimits = jsonLimits
    self.maximumHeaderBytes = maximumHeaderBytes
    self.maximumBodyBytes = maximumBodyBytes
    self.maximumSSEEventBytes = maximumSSEEventBytes
    self.sseKeepAliveInterval = sseKeepAliveInterval
    self.requestReadTimeout = requestReadTimeout
    self.socketTimeout = socketTimeout
    self.maximumConcurrentConnections = maximumConcurrentConnections
    self.listenBacklog = listenBacklog
    self.toolHeaderValidationPolicy = toolHeaderValidationPolicy
  }

  private static func isIPv4(_ value: String) -> Bool {
    var address = in_addr()
    return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
  }
}

/// Controls validation of the optional Streamable HTTP `x-mcp-header` tool-schema extension.
///
/// When a tool declares a binding and the corresponding argument is present, the 2026-07-28
/// Streamable HTTP rules require the matching `Mcp-Param-*` header. The strict default enforces
/// that rule; `whenPresent` is an explicit host escape hatch and is not a conforming mode for a
/// server that advertises the binding.
public enum MCPHTTPToolHeaderValidationPolicy: Sendable, Hashable {
  /// Validate bindings only when at least one `Mcp-Param-*` header is present.
  case whenPresent
  /// Require and validate every binding declared by an annotated tool schema.
  case required
}

public struct MCPHTTPServerHandler: Sendable {
  public let server: MCPServer
  public let configuration: MCPHTTPConfiguration

  public init(server: MCPServer, configuration: MCPHTTPConfiguration) {
    self.server = server
    self.configuration = configuration
  }

  public func handle(_ request: MCPHTTPRequest, effectiveEndpoint: URL? = nil) async
    -> MCPHTTPResponse
  {
    do {
      try request.headers.validate()
    } catch {
      return Self.rpcErrorResponse(status: 400, id: nil, error: .invalidRequest)
    }
    guard Self.path(of: request.target) == configuration.endpointPath else {
      return Self.textResponse(status: 404, text: "Not Found")
    }
    // Origin and authorization policy must be anchored to a trusted endpoint. `publicEndpoint`
    // describes the externally visible authority and therefore takes precedence over a local bind
    // address supplied by the built-in listener. A caller embedding the handler directly must
    // provide one of these values; the untrusted Host header is never an authority fallback.
    guard let endpoint = configuration.publicEndpoint ?? effectiveEndpoint else {
      return Self.rpcErrorResponse(status: 400, id: nil, error: .invalidRequest)
    }
    guard
      configuration.originPolicy.validate(
        origin: request.headers["origin"], requestEndpoint: endpoint)
    else {
      return MCPHTTPResponse(status: 403, body: .empty)
    }
    guard request.method == "POST" else {
      return MCPHTTPResponse(
        status: 405,
        headers: MCPHTTPHeaders(["allow": "POST", "content-type": "text/plain; charset=utf-8"]),
        body: .bytes(Data("Method Not Allowed".utf8))
      )
    }
    guard Self.mediaType(request.headers["content-type"]) == "application/json" else {
      return Self.rpcErrorResponse(status: 415, id: nil, error: .invalidRequest)
    }
    guard Self.acceptsMCPResponse(request.headers["accept"]) else {
      return Self.rpcErrorResponse(
        status: 406,
        id: nil,
        error: MCPRPCError(
          code: -32600, message: "Accept must include application/json and text/event-stream")
      )
    }
    guard request.body.count <= configuration.maximumBodyBytes else {
      return Self.rpcErrorResponse(
        status: 413,
        id: nil,
        error: MCPRPCError(code: -32600, message: "Request body too large")
      )
    }

    let message: MCPWireMessage
    do {
      message = try MCPWireMessage.decode(request.body, limits: configuration.jsonLimits)
    } catch let error as MCPJSONError {
      return Self.rpcErrorResponse(
        status: 400,
        id: nil,
        error: MCPRPCError(code: -32700, message: "Parse error", data: .string(error.description))
      )
    } catch {
      return Self.rpcErrorResponse(status: 400, id: nil, error: .invalidRequest)
    }
    guard case .request(let wireRequest) = message else {
      return Self.rpcErrorResponse(status: 400, id: nil, error: .invalidRequest)
    }

    // Validate transport-owned, body-derived headers before invoking authorization or any dynamic
    // route, authorization, or dynamic tool resolver. The body remains authoritative; headers are
    // redundant routing evidence only.
    do {
      let headerVersion = request.headers[MCPHTTPHeaderName.protocolVersion]
      guard let headerVersion else {
        throw MCPHTTPError.headerMismatch("missing MCP-Protocol-Version")
      }
      guard request.headers[MCPHTTPHeaderName.method] == wireRequest.method else {
        throw MCPHTTPError.headerMismatch("Mcp-Method does not match the request body")
      }
      let metadataObject = try MCPJSONObject(
        wireRequest.params["_meta"] ?? { throw MCPJSONError.missingField("_meta") }())
      let bodyVersion = try metadataObject.requiredString(MCPMetaKey.protocolVersion)
      // Compare the raw values before typed version parsing. An unknown body version that does
      // not match the transport header is a HeaderMismatch; only matching unknown versions are
      // reported as UnsupportedProtocolVersion.
      guard headerVersion == bodyVersion else {
        throw MCPHTTPError.headerMismatch(
          "MCP-Protocol-Version does not match request _meta")
      }
      _ = try MCPRequestMetadata.extract(from: wireRequest.params)
      guard headerVersion == MCPProtocolVersion.current.rawValue else {
        return Self.rpcErrorResponse(
          status: 400,
          id: wireRequest.id,
          error: .unsupportedProtocolVersion(headerVersion)
        )
      }
    } catch let error as MCPRPCError {
      return Self.rpcErrorResponse(status: 400, id: wireRequest.id, error: error)
    } catch let error as MCPHTTPError {
      return Self.rpcErrorResponse(
        status: 400,
        id: wireRequest.id,
        error: .headerMismatch("Header mismatch: \(error.description)")
      )
    } catch let error as MCPJSONError {
      return Self.rpcErrorResponse(
        status: 400,
        id: wireRequest.id,
        error: MCPRPCError(
          code: -32602, message: "Invalid params", data: .string(error.description))
      )
    } catch {
      return Self.rpcErrorResponse(status: 400, id: wireRequest.id, error: .invalidRequest)
    }

    let descriptor: MCPMethodDescriptor
    do {
      descriptor = try server.registry.require(wireRequest.method)
    } catch {
      return Self.rpcErrorResponse(status: 404, id: wireRequest.id, error: .methodNotFound)
    }

    do {
      try MCPHTTPStandardHeaders.validate(
        request.headers,
        request: wireRequest,
        descriptor: descriptor
      )
    } catch let error as MCPHTTPError {
      return Self.rpcErrorResponse(
        status: 400,
        id: wireRequest.id,
        error: .headerMismatch("Header mismatch: \(error.description)")
      )
    } catch let error as MCPJSONError {
      return Self.rpcErrorResponse(
        status: 400,
        id: wireRequest.id,
        error: MCPRPCError(
          code: -32602, message: "Invalid params", data: .string(error.description))
      )
    } catch {
      return Self.rpcErrorResponse(status: 400, id: wireRequest.id, error: .invalidRequest)
    }

    let authorization: MCPAuthorizationContext
    do {
      authorization = try await configuration.authorizationVerifier.authorize(
        headers: request.headers,
        resource: endpoint,
        remoteAddress: request.remoteAddress
      )
    } catch let failure as MCPHTTPAuthorizationFailure {
      switch failure {
      case .unauthorized(let challenge):
        return Self.authorizationFailureResponse(status: 401, challenge: challenge)
      case .forbidden(let challenge):
        return Self.authorizationFailureResponse(status: 403, challenge: challenge)
      }
    } catch {
      return Self.authorizationFailureResponse(status: 401, challenge: .bearer)
    }

    let prepared: MCPPreparedServerRequest
    do {
      prepared = try await server.prepare(wireRequest, authorization: authorization)
    } catch let error as MCPRPCError {
      let outbound = MCPServer.outboundError(error)
      return Self.rpcErrorResponse(
        status: Self.status(for: outbound), id: wireRequest.id, error: outbound)
    } catch let error as MCPJSONError {
      return Self.rpcErrorResponse(
        status: 400,
        id: wireRequest.id,
        error: MCPRPCError(
          code: -32602, message: "Invalid params", data: .string(error.description))
      )
    } catch let error as MCPRegistryError {
      let rpc: MCPRPCError =
        switch error {
        case .unsupportedMethod, .wrongDirection: .methodNotFound
        default: .invalidRequest
        }
      return Self.rpcErrorResponse(status: Self.status(for: rpc), id: wireRequest.id, error: rpc)
    } catch {
      return Self.rpcErrorResponse(status: 500, id: wireRequest.id, error: .internalError)
    }

    // x-mcp-header is an optional tool-definition feature. Once a tool declares a binding, the
    // Streamable HTTP protocol requires the server to validate every value present in the body.
    if let tool = prepared.resolvedTool {
      let toolSchema: MCPHTTPToolHeaderSchema
      do {
        toolSchema = try MCPHTTPToolHeaderSchema(tool: tool)
      } catch {
        return Self.rpcErrorResponse(status: 500, id: wireRequest.id, error: .internalError)
      }
      let usesToolHeaderBindings = toolSchema.bindings.contains {
        request.headers[MCPHTTPHeaderName.parameterPrefix + $0.headerName] != nil
      }
      if usesToolHeaderBindings || configuration.toolHeaderValidationPolicy == .required {
        do {
          try MCPHTTPStandardHeaders.validate(
            request.headers,
            request: wireRequest,
            descriptor: prepared.descriptor,
            toolSchema: toolSchema
          )
        } catch let error as MCPHTTPError {
          return Self.rpcErrorResponse(
            status: 400,
            id: wireRequest.id,
            error: .headerMismatch("Header mismatch: \(error.description)")
          )
        } catch let error as MCPJSONError {
          return Self.rpcErrorResponse(
            status: 400,
            id: wireRequest.id,
            error: MCPRPCError(
              code: -32602, message: "Invalid params", data: .string(error.description))
          )
        } catch {
          return Self.rpcErrorResponse(status: 400, id: wireRequest.id, error: .invalidRequest)
        }
      }
    }

    do {
      return await makeProtocolResponse(
        try server.execute(prepared),
        requestID: wireRequest.id,
        requestMethod: wireRequest.method
      )
    } catch {
      return Self.rpcErrorResponse(status: 500, id: wireRequest.id, error: .internalError)
    }
  }

  private func makeProtocolResponse(
    _ exchange: MCPServerExchange,
    requestID: MCPRequestID,
    requestMethod: String
  ) async -> MCPHTTPResponse {
    do {
      var iterator = exchange.frames.makeAsyncIterator()
      guard let first = try await iterator.next() else {
        return Self.rpcErrorResponse(status: 500, id: requestID, error: .internalError)
      }
      switch first {
      case .result:
        guard try await iterator.next() == nil else {
          await exchange.cancel(reason: "multiple terminal frames")
          return Self.rpcErrorResponse(status: 500, id: requestID, error: .internalError)
        }
        return MCPHTTPResponse(
          status: 200,
          headers: MCPHTTPHeaders(["content-type": "application/json"]),
          body: .bytes(try first.encoded())
        )
      case .error(let response):
        guard try await iterator.next() == nil else {
          await exchange.cancel(reason: "multiple terminal frames")
          return Self.rpcErrorResponse(status: 500, id: requestID, error: .internalError)
        }
        return MCPHTTPResponse(
          status: Self.status(for: response.error),
          headers: MCPHTTPHeaders(["content-type": "application/json"]),
          body: .bytes(try first.encoded())
        )
      case .notification:
        let pair = AsyncThrowingStream<Data, Error>.makeStream(
          bufferingPolicy: .bufferingNewest(4_096))
        let keepAliveTask: Task<Void, Never>? =
          requestMethod == "subscriptions/listen"
          ? Task {
            do {
              while true {
                try await Task.sleep(for: .seconds(configuration.sseKeepAliveInterval))
                try Task.checkCancellation()
                try Self.yieldSSEComment(into: pair.continuation)
              }
            } catch is CancellationError {
              // The response producer or consumer ended the long-lived stream.
            } catch {
              pair.continuation.finish(throwing: error)
              await exchange.cancel(reason: "HTTP SSE keep-alive failed")
            }
          } : nil
        let task = Task {
          defer { keepAliveTask?.cancel() }
          do {
            try Self.yieldSSE(
              first, into: pair.continuation, maximumEventBytes: configuration.maximumSSEEventBytes)
            var terminalSeen = false
            while let frame = try await iterator.next() {
              if terminalSeen {
                throw MCPHTTPError.io("frame emitted after terminal response")
              }
              switch frame {
              case .request:
                throw MCPHTTPError.io("server-originated request is forbidden")
              case .notification:
                break
              case .result, .error:
                terminalSeen = true
              }
              try Self.yieldSSE(
                frame, into: pair.continuation,
                maximumEventBytes: configuration.maximumSSEEventBytes)
            }
            guard terminalSeen else { throw MCPHTTPError.connectionClosed }
            pair.continuation.finish()
          } catch is MCPServerSubscriptionCancellation {
            // Streamable HTTP represents server-side subscription cancellation by closing the
            // response stream. `notifications/cancelled` is a stdio lifecycle signal and must not
            // be emitted on this HTTP stream.
            pair.continuation.finish()
          } catch {
            pair.continuation.finish(throwing: error)
            await exchange.cancel(reason: "HTTP response stream failed")
          }
        }
        pair.continuation.onTermination = { @Sendable _ in
          task.cancel()
          keepAliveTask?.cancel()
          Task { await exchange.cancel(reason: "HTTP response stream closed") }
        }
        return MCPHTTPResponse(
          status: 200,
          headers: MCPHTTPHeaders([
            "content-type": "text/event-stream",
            "cache-control": "no-cache",
            "x-accel-buffering": "no",
          ]),
          body: .stream(
            MCPHTTPResponseStream(chunks: pair.stream) {
              task.cancel()
              keepAliveTask?.cancel()
              await exchange.cancel(reason: "HTTP client disconnected")
            })
        )
      case .request:
        await exchange.cancel(reason: "server-originated request is forbidden")
        return Self.rpcErrorResponse(status: 500, id: requestID, error: .internalError)
      }
    } catch {
      await exchange.cancel(reason: "HTTP response assembly failed")
      return Self.rpcErrorResponse(status: 500, id: requestID, error: .internalError)
    }
  }

  private static func yieldSSE(
    _ message: MCPWireMessage,
    into continuation: AsyncThrowingStream<Data, Error>.Continuation,
    maximumEventBytes: Int
  ) throws {
    let payload = try message.encoded()
    guard payload.count <= maximumEventBytes else {
      throw MCPHTTPError.eventTooLarge(maximumEventBytes)
    }
    switch continuation.yield(MCPSSEEncoder.dataEvent(payload)) {
    case .enqueued:
      break
    case .dropped:
      throw MCPHTTPError.io("SSE response buffer overflow")
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw MCPHTTPError.io("unknown SSE response buffer state")
    }
  }

  private static func yieldSSEComment(
    into continuation: AsyncThrowingStream<Data, Error>.Continuation
  ) throws {
    switch continuation.yield(Data(": keep-alive\n\n".utf8)) {
    case .enqueued:
      break
    case .dropped:
      throw MCPHTTPError.io("SSE response buffer overflow")
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw MCPHTTPError.io("unknown SSE response stream state")
    }
  }

  private static func acceptsMCPResponse(_ value: String?) -> Bool {
    guard let value else { return false }
    let supportedTypes = Set(
      value.split(separator: ",").compactMap { part -> String? in
        let pieces = part.split(separator: ";", omittingEmptySubsequences: false)
        guard let type = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !type.isEmpty
        else { return nil }
        let qualityValues = pieces.dropFirst().compactMap { parameter -> String? in
          let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          guard pair.count == 2,
            pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "q"
          else { return nil }
          return pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard qualityValues.count <= 1 else { return nil }
        if let quality = qualityValues.first {
          guard Self.isAcceptableQualityValue(quality) else {
            return nil
          }
        }
        return type
      })
    return supportedTypes.contains("application/json")
      && supportedTypes.contains("text/event-stream")
  }

  private static func isAcceptableQualityValue(_ value: String) -> Bool {
    guard let integer = value.first, integer == "0" || integer == "1" else { return false }
    let suffix = value.dropFirst()
    if suffix.isEmpty { return integer == "1" }
    guard suffix.first == "." else { return false }
    let fraction = suffix.dropFirst()
    guard
      fraction.count <= 3,
      fraction.allSatisfy({ character in
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first
        else { return false }
        return (48...57).contains(scalar.value)
      })
    else { return false }
    return integer == "1"
      ? fraction.allSatisfy { $0 == "0" }
      : fraction.contains { $0 != "0" }
  }

  /// Maps a terminal JSON-RPC error onto the HTTP status the transport specification requires.
  /// Every code the specification assigns a status is listed explicitly, including `HeaderMismatch`
  /// which the request path answers directly today, so a future caller cannot route a specified
  /// error through this function and silently receive `200`.
  private static func status(for error: MCPRPCError) -> Int {
    switch error.code {
    case -32601:
      return 404
    case -32603:
      return 500
    case -32602, -32020, -32021, -32022:
      return 400
    default:
      return 200
    }
  }

  private static func mediaType(_ value: String?) -> String? {
    value?.split(separator: ";", maxSplits: 1).first.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
  }

  private static func path(of target: String) -> String {
    target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(
      String.init) ?? target
  }

  private static func textResponse(status: Int, text: String) -> MCPHTTPResponse {
    MCPHTTPResponse(
      status: status,
      headers: MCPHTTPHeaders(["content-type": "text/plain; charset=utf-8"]),
      body: .bytes(Data(text.utf8))
    )
  }

  private static func authorizationFailureResponse(
    status: Int,
    challenge: MCPHTTPAuthenticationChallenge?
  ) -> MCPHTTPResponse {
    var headers = MCPHTTPHeaders()
    if let challenge { headers["www-authenticate"] = challenge.value }
    return MCPHTTPResponse(status: status, headers: headers, body: .empty)
  }

  private static func rpcErrorResponse(
    status: Int,
    id: MCPRequestID?,
    error: MCPRPCError,
    additionalHeaders: MCPHTTPHeaders = MCPHTTPHeaders()
  ) -> MCPHTTPResponse {
    var envelope: [String: MCPJSONValue] = [
      "jsonrpc": .string("2.0"),
      "error": error.json,
    ]
    if let id { envelope["id"] = id.json }
    var headers = MCPHTTPHeaders(["content-type": "application/json"])
    headers.merge(additionalHeaders)
    do {
      let body = try MCPJSONValue.object(envelope).encoded()
      return MCPHTTPResponse(status: status, headers: headers, body: .bytes(body))
    } catch {
      // Error serialization must never turn into an empty or successful response. The fallback is
      // deliberately fixed, valid JSON and upgrades the status to 500 so the encoding failure is
      // externally visible without exposing internal details.
      let body = Data(
        #"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"}}"#.utf8
      )
      return MCPHTTPResponse(status: 500, headers: headers, body: .bytes(body))
    }
  }
}

private enum MCPHTTPConnectionRegistration {
  case accepted
  case atCapacity
  case stopped
}

// Socket descriptors can be registered and closed from different execution contexts. Capacity
// checks and registration happen under the same lock so concurrent accepts cannot exceed the
// configured limit. Registration IDs prevent a late cleanup from removing a reused descriptor.
private final class MCPHTTPConnectionRegistry: @unchecked Sendable {
  /// Whether a connection still owns only transport work, or has handed its request to the MCP
  /// server. Shutdown may interrupt the former freely; the latter is what it has to wait for.
  private enum Phase {
    case reading
    case handling
  }

  private struct Entry {
    var descriptor: Int32?
    var task: Task<Void, Never>?
    var phase: Phase = .reading
    var cancelResponseStream: (@Sendable () async -> Void)?
  }

  private let lock = NSLock()
  private var entries: [UInt64: Entry] = [:]
  private var nextRegistrationID: UInt64 = 0
  private var accepting = false
  private var shuttingDown = false

  func beginAccepting() {
    lock.lock()
    accepting = true
    // A restart reopens the drain gate; otherwise every later request would be abandoned at
    // `beginHandlingRequest` and answered with a closed connection.
    shuttingDown = false
    lock.unlock()
  }

  func register(
    _ descriptor: Int32,
    maximum: Int,
    operation: @escaping @Sendable (UInt64) async -> Void
  ) -> MCPHTTPConnectionRegistration {
    lock.lock()
    defer { lock.unlock() }
    guard accepting else { return .stopped }
    guard entries.count < maximum else { return .atCapacity }
    let registrationID = nextRegistrationID
    nextRegistrationID &+= 1
    // Reserve the entry before starting the operation. Task.detached may run immediately; without
    // this placeholder a fast peer close can execute the deferred remove/complete path before the
    // dictionary insertion below, leaking the descriptor and permanently consuming one capacity
    // slot.
    entries[registrationID] = Entry(descriptor: descriptor, task: nil)
    let task = Task.detached(priority: .utility) {
      await operation(registrationID)
    }
    entries[registrationID]?.task = task
    return .accepted
  }

  /// Transfers descriptor ownership to the connection task exactly once. The entry remains until
  /// `complete` so shutdown can still cancel and await a task that is between ownership transfer
  /// and the final close.
  func remove(_ registrationID: UInt64) -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    guard var entry = entries[registrationID], let descriptor = entry.descriptor else {
      return nil
    }
    entry.descriptor = nil
    entries[registrationID] = entry
    return descriptor
  }

  func complete(_ registrationID: UInt64) {
    lock.lock()
    entries.removeValue(forKey: registrationID)
    lock.unlock()
  }

  func stopAccepting() {
    lock.lock()
    accepting = false
    lock.unlock()
  }

  var hasConnections: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !entries.isEmpty
  }

  var isAccepting: Bool {
    lock.lock()
    defer { lock.unlock() }
    return accepting
  }

  /// Claims application ownership of a connection's request before it reaches the MCP server.
  ///
  /// Returns `false` once shutdown has begun, so a request that has not started running is
  /// abandoned at this boundary instead of being cancelled halfway through the handler.
  func beginHandlingRequest(_ registrationID: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !shuttingDown, entries[registrationID] != nil else { return false }
    entries[registrationID]?.phase = .handling
    return true
  }

  /// Records how to stop a streaming response so shutdown can end a long-lived subscription
  /// without cancelling the task that is still writing it. Returns `false` when shutdown has
  /// already passed this connection, leaving the caller to stop the stream itself.
  func registerResponseStream(
    _ registrationID: UInt64,
    cancel: @escaping @Sendable () async -> Void
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !shuttingDown, entries[registrationID] != nil else { return false }
    entries[registrationID]?.cancelResponseStream = cancel
    return true
  }

  /// Stops registration and releases every connection, without closing any descriptor. Keeping
  /// each file descriptor open until its owning task exits prevents the OS from reusing its
  /// numeric value while that task may still be unwinding a recv/send operation.
  ///
  /// A connection that has not dispatched its request owns no application work and is interrupted.
  /// When `drainingHandlers` is set, one that is already running in the MCP server is left alone:
  /// cancelling it would abort the response assembly and return control from `shutdown()` while
  /// the handler kept running in its own task. Its streaming response is still cancelled, so an
  /// open subscription ends promptly instead of holding shutdown open indefinitely.
  func stopAndShutdownAll(drainingHandlers: Bool) -> MCPHTTPConnectionTeardown {
    lock.lock()
    accepting = false
    shuttingDown = true
    var streamCancellations: [@Sendable () async -> Void] = []
    for entry in entries.values {
      if drainingHandlers, entry.phase == .handling {
        if let cancel = entry.cancelResponseStream { streamCancellations.append(cancel) }
        continue
      }
      if let descriptor = entry.descriptor { mcpShutdownSocket(descriptor) }
      entry.task?.cancel()
    }
    let tasks = entries.values.compactMap(\.task)
    lock.unlock()
    return MCPHTTPConnectionTeardown(tasks: tasks, streamCancellations: streamCancellations)
  }
}

/// The work `shutdown()` must finish after the registry has released its connections.
private struct MCPHTTPConnectionTeardown: Sendable {
  let tasks: [Task<Void, Never>]
  let streamCancellations: [@Sendable () async -> Void]
}

// Listener lifecycle fields are protected by `lock`; accepted connection
// descriptors are owned by the separately locked registry. Handler and
// configuration are immutable Sendable values.
public final class MCPHTTPServer: @unchecked Sendable {
  public let handler: MCPHTTPServerHandler
  public let configuration: MCPHTTPConfiguration

  private let lock = NSLock()
  private let connections = MCPHTTPConnectionRegistry()
  private let acceptQueue = DispatchQueue(label: "org.modelcontextprotocol.swift.http.accept")
  private let ioQueue = DispatchQueue(
    label: "org.modelcontextprotocol.swift.http.io",
    qos: .utility,
    attributes: .concurrent
  )
  private var listener: Int32 = -1
  private var acceptTask: Task<Void, Never>?
  private var shutdownTask: Task<Void, Never>?
  private var boundEndpointValue: URL?

  public init(server: MCPServer, configuration: MCPHTTPConfiguration) {
    self.configuration = configuration
    self.handler = MCPHTTPServerHandler(server: server, configuration: configuration)
  }

  public var boundEndpoint: URL? {
    lock.lock()
    defer { lock.unlock() }
    return boundEndpointValue
  }

  @discardableResult
  public func start() throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    guard listener < 0, shutdownTask == nil else { throw MCPHTTPServerError.alreadyRunning }
    let descriptor = socket(AF_INET, mcpSocketStreamType(), 0)
    guard descriptor >= 0 else { throw MCPHTTPServerError.socket(mcpErrnoDescription()) }
    do {
      try mcpConfigureNonblockingListener(descriptor)
    } catch {
      mcpCloseSocket(descriptor)
      throw error
    }
    var reuse: Int32 = 1
    guard
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_REUSEADDR,
        &reuse,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else {
      mcpCloseSocket(descriptor)
      throw MCPHTTPServerError.socket(mcpErrnoDescription())
    }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = configuration.port.bigEndian
    let parsed = configuration.bindAddress.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    guard parsed == 1 else {
      mcpCloseSocket(descriptor)
      throw MCPHTTPServerError.invalidConfiguration("invalid bindAddress")
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      let reason = mcpErrnoDescription()
      mcpCloseSocket(descriptor)
      throw MCPHTTPServerError.socket(reason)
    }
    guard listen(descriptor, Int32(configuration.listenBacklog)) == 0 else {
      let reason = mcpErrnoDescription()
      mcpCloseSocket(descriptor)
      throw MCPHTTPServerError.socket(reason)
    }
    var actual = sockaddr_in()
    var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &actual) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &actualLength)
      }
    }
    guard nameResult == 0 else {
      let reason = mcpErrnoDescription()
      mcpCloseSocket(descriptor)
      throw MCPHTTPServerError.socket(reason)
    }
    let actualPort = UInt16(bigEndian: actual.sin_port)
    guard
      let endpoint = URL(
        string: "http://\(configuration.bindAddress):\(actualPort)\(configuration.endpointPath)")
    else {
      mcpCloseSocket(descriptor)
      throw MCPHTTPServerError.invalidConfiguration("could not construct bound endpoint")
    }
    listener = descriptor
    boundEndpointValue = endpoint
    connections.beginAccepting()
    let handler = self.handler
    let config = configuration
    let registry = connections
    let acceptQueue = acceptQueue
    let ioQueue = ioQueue
    acceptTask = Task.detached(priority: .utility) { [weak self] in
      await withCheckedContinuation { continuation in
        acceptQueue.async {
          defer { mcpCloseSocket(descriptor) }
          Self.acceptLoop(
            listener: descriptor,
            endpoint: endpoint,
            handler: handler,
            configuration: config,
            registry: registry,
            ioQueue: ioQueue
          )
          continuation.resume()
        }
      }
      self?.clearStoppedListener(descriptor)
    }
    return endpoint
  }

  /// Stops accepting and returns once every in-flight request has finished.
  ///
  /// A request already running in the MCP server is drained, not cancelled: when this returns, no
  /// registered handler is still executing. Connections that have not dispatched a request are
  /// interrupted, and a streaming response is cancelled so an open subscription ends rather than
  /// holding shutdown open. A handler that never returns therefore keeps shutdown pending, which
  /// is the point of the guarantee; hosts that need a deadline impose one around this call.
  public func shutdown() async {
    let task: Task<Void, Never>? = lock.withLock {
      if let shutdownTask { return shutdownTask }
      guard listener >= 0 || acceptTask != nil || connections.hasConnections else {
        boundEndpointValue = nil
        return nil
      }
      let descriptor = listener
      let listenerTask = acceptTask
      let registry = connections
      boundEndpointValue = nil
      let task = Task.detached(priority: .utility) { [weak self] in
        let teardown = registry.stopAndShutdownAll(drainingHandlers: true)
        listenerTask?.cancel()
        await listenerTask?.value
        for cancelStream in teardown.streamCancellations { await cancelStream() }
        for connectionTask in teardown.tasks { await connectionTask.value }
        self?.finishShutdown(descriptor)
      }
      shutdownTask = task
      return task
    }
    await task?.value
  }

  deinit {
    lock.lock()
    listener = -1
    let listenerTask = acceptTask
    acceptTask = nil
    let shutdownTask = shutdownTask
    self.shutdownTask = nil
    lock.unlock()
    // Deinitialization cannot await a drain, so this is the abrupt path: every connection is
    // cancelled. A host that needs in-flight requests to finish calls `shutdown()` first.
    _ = connections.stopAndShutdownAll(drainingHandlers: false)
    listenerTask?.cancel()
    shutdownTask?.cancel()
  }

  private func finishShutdown(_ descriptor: Int32) {
    lock.lock()
    if listener == descriptor {
      listener = -1
      acceptTask = nil
    }
    boundEndpointValue = nil
    shutdownTask = nil
    lock.unlock()
  }

  private func clearStoppedListener(_ descriptor: Int32) {
    lock.lock()
    var didStop = false
    if listener == descriptor {
      listener = -1
      acceptTask = nil
      boundEndpointValue = nil
      didStop = true
    }
    lock.unlock()
    if didStop { connections.stopAccepting() }
  }

  private static func acceptLoop(
    listener: Int32,
    endpoint: URL,
    handler: MCPHTTPServerHandler,
    configuration: MCPHTTPConfiguration,
    registry: MCPHTTPConnectionRegistry,
    ioQueue: DispatchQueue
  ) {
    while registry.isAccepting {
      var pollDescriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      let pollResult = poll(&pollDescriptor, 1, 100)
      if pollResult < 0 {
        if mcpSocketWasInterrupted() { continue }
        return
      }
      if pollResult == 0 { continue }
      guard registry.isAccepting else { return }

      var address = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let client = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          accept(listener, $0, &length)
        }
      }
      if client < 0 {
        if mcpSocketWasInterrupted() || mcpSocketWouldBlock() { continue }
        return
      }
      let remote = mcpIPv4String(address.sin_addr)
      let registration = registry.register(
        client,
        maximum: configuration.maximumConcurrentConnections
      ) { registrationID in
        defer {
          if let ownedDescriptor = registry.remove(registrationID) {
            mcpCloseSocket(ownedDescriptor)
          }
          registry.complete(registrationID)
        }
        do {
          let request = try await mcpPerformBlocking(on: ioQueue) {
            try mcpConfigureBlockingSocket(client)
            try mcpDisableSocketSIGPIPE(client)
            try mcpConfigureSocketTimeout(client, seconds: configuration.requestReadTimeout)
            let request = try mcpReadHTTPRequest(
              from: client,
              remoteAddress: remote,
              maximumHeaderBytes: configuration.maximumHeaderBytes,
              maximumBodyBytes: configuration.maximumBodyBytes
            )
            try mcpConfigureSocketTimeout(client, seconds: configuration.socketTimeout)
            return request
          }
          // Claim the request before the MCP server can start running it. Once this succeeds the
          // connection is drained rather than cancelled, so `shutdown()` cannot return while the
          // handler below is still executing.
          guard registry.beginHandlingRequest(registrationID) else { return }
          let response = await handler.handle(request, effectiveEndpoint: endpoint)
          if case .stream(let stream) = response.body,
            !registry.registerResponseStream(registrationID, cancel: { await stream.cancel() })
          {
            // Shutdown already released this connection, so nothing will stop the stream later.
            await stream.cancel()
          }
          try await mcpWriteHTTPResponse(response, to: client, on: ioQueue)
        } catch {
          let payloadTooLarge = (error as? MCPHTTPServerError) == .payloadTooLarge
          let status = payloadTooLarge ? 413 : 400
          let text = payloadTooLarge ? "Payload Too Large" : "Bad Request"
          let response = MCPHTTPResponse(
            status: status,
            headers: MCPHTTPHeaders(["content-type": "text/plain; charset=utf-8"]),
            body: .bytes(Data(text.utf8))
          )
          do {
            try await mcpWriteHTTPResponse(response, to: client, on: ioQueue)
          } catch {
            // The connection already failed; there is no second safe response channel.
          }
        }
      }
      switch registration {
      case .accepted:
        continue
      case .atCapacity:
        mcpCloseSocket(client)
      case .stopped:
        mcpCloseSocket(client)
        return
      }
    }
  }
}

private func mcpSocketStreamType() -> Int32 {
  #if canImport(Glibc)
    return Int32(SOCK_STREAM.rawValue)
  #else
    return SOCK_STREAM
  #endif
}

private func mcpConfigureNonblockingListener(_ descriptor: Int32) throws {
  let flags = fcntl(descriptor, F_GETFL, 0)
  guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
    throw MCPHTTPServerError.socket(mcpErrnoDescription())
  }
}

private func mcpConfigureBlockingSocket(_ descriptor: Int32) throws {
  let flags = fcntl(descriptor, F_GETFL, 0)
  guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
    throw MCPHTTPServerError.socket(mcpErrnoDescription())
  }
}

private func mcpCloseSocket(_ descriptor: Int32) {
  guard descriptor >= 0 else { return }
  mcpShutdownSocket(descriptor)
  _ = close(descriptor)
}

private func mcpShutdownSocket(_ descriptor: Int32) {
  guard descriptor >= 0 else { return }
  _ = shutdown(descriptor, Int32(SHUT_RDWR))
}

private func mcpSocketWasInterrupted() -> Bool { errno == EINTR }
private func mcpSocketWouldBlock() -> Bool { errno == EAGAIN || errno == EWOULDBLOCK }
private func mcpErrnoDescription() -> String { String(cString: strerror(errno)) }

/// Runs a potentially blocking socket operation outside Swift's cooperative executor.
private func mcpPerformBlocking<Value: Sendable>(
  on queue: DispatchQueue,
  _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
  try await withCheckedThrowingContinuation { continuation in
    queue.async {
      do {
        continuation.resume(returning: try operation())
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

private func mcpIPv4String(_ address: in_addr) -> String? {
  var address = address
  var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
  guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
  let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
  return String(decoding: bytes, as: UTF8.self)
}

/// Turns a write to a peer-closed connection into an `EPIPE` error instead of a process signal.
///
/// A disconnect in the middle of a response is ordinary client behavior and must terminate one
/// request, never the host process. Linux carries this per write through `MSG_NOSIGNAL`; Darwin has
/// no such send flag for sockets, so the guarantee is installed once per accepted descriptor.
private func mcpDisableSocketSIGPIPE(_ descriptor: Int32) throws {
  #if canImport(Darwin)
    var enabled: Int32 = 1
    guard
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else { throw MCPHTTPServerError.socket(mcpErrnoDescription()) }
  #else
    _ = descriptor
  #endif
}

private func mcpConfigureSocketTimeout(_ descriptor: Int32, seconds: TimeInterval) throws {
  guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else {
    throw MCPHTTPServerError.invalidConfiguration("socket timeout is out of range")
  }
  let whole = Int(seconds)
  let microseconds = Int32((seconds - Double(whole)) * 1_000_000)
  var timeout = timeval()
  timeout.tv_sec = numericCast(whole)
  timeout.tv_usec = numericCast(microseconds)
  let size = socklen_t(MemoryLayout<timeval>.size)
  guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0
  else { throw MCPHTTPServerError.socket(mcpErrnoDescription()) }
}

private func mcpReadHTTPRequest(
  from descriptor: Int32,
  remoteAddress: String?,
  maximumHeaderBytes: Int,
  maximumBodyBytes: Int
) throws -> MCPHTTPRequest {
  var storage = Data()
  let delimiter = Data("\r\n\r\n".utf8)
  var headerEnd: Range<Data.Index>?
  while headerEnd == nil {
    guard storage.count < maximumHeaderBytes else {
      throw MCPHTTPServerError.invalidRequest("headers too large")
    }
    storage.append(
      try mcpReadSocketChunk(descriptor, maximum: min(8_192, maximumHeaderBytes - storage.count)))
    headerEnd = storage.range(of: delimiter)
  }
  guard let headerEnd else { throw MCPHTTPServerError.invalidRequest("missing header delimiter") }
  let headerData = storage[..<headerEnd.lowerBound]
  guard let headerText = String(data: headerData, encoding: .utf8) else {
    throw MCPHTTPServerError.invalidRequest("headers are not UTF-8")
  }
  let lines = headerText.components(separatedBy: "\r\n")
  guard let requestLine = lines.first else {
    throw MCPHTTPServerError.invalidRequest("missing request line")
  }
  let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
  guard requestParts.count == 3, requestParts[2] == "HTTP/1.1" else {
    throw MCPHTTPServerError.invalidRequest("expected HTTP/1.1 request line")
  }
  let method = String(requestParts[0])
  let target = String(requestParts[1])
  var rawHeaders: [String: String] = [:]
  var protocolHeaderNames = Set<String>()
  for line in lines.dropFirst() {
    guard !line.isEmpty, line.first != " " && line.first != "\t",
      let colon = line.firstIndex(of: ":")
    else { throw MCPHTTPServerError.invalidRequest("malformed header line") }
    let rawName = String(line[..<colon])
    let name = rawName.lowercased()
    guard !name.isEmpty,
      rawName.unicodeScalars.allSatisfy({ scalar in
        switch scalar.value {
        case 48...57, 65...90, 97...122, 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124,
          126:
          return true
        default:
          return false
        }
      })
    else { throw MCPHTTPServerError.invalidRequest("invalid header name") }
    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    guard !value.contains("\r"), !value.contains("\n") else {
      throw MCPHTTPServerError.invalidRequest("invalid header value")
    }
    let isProtocolOwned =
      name == "content-length" || name == "transfer-encoding" || name == "host"
      || name == "authorization" || name == "origin" || name == "content-type"
      || name == MCPHTTPHeaderName.protocolVersion.lowercased()
      || name == MCPHTTPHeaderName.method.lowercased()
      || name == MCPHTTPHeaderName.name.lowercased()
      || name.hasPrefix(MCPHTTPHeaderName.parameterPrefix.lowercased())
    if isProtocolOwned, !protocolHeaderNames.insert(name).inserted {
      throw MCPHTTPServerError.invalidRequest("duplicate protocol header \(rawName)")
    }
    if let existing = rawHeaders[name], !isProtocolOwned {
      rawHeaders[name] = existing + ", " + value
    } else {
      rawHeaders[name] = value
    }
  }
  guard rawHeaders["host"] != nil else {
    throw MCPHTTPServerError.invalidRequest("missing Host header")
  }
  // The application handler owns endpoint and method policy. Unsupported methods do not need
  // MCP request framing, so return the parsed request immediately instead of rejecting a missing
  // Content-Length before the handler can produce the required 405 response.
  if method != "POST" {
    return MCPHTTPRequest(
      method: method,
      target: target,
      headers: MCPHTTPHeaders(rawHeaders),
      body: Data(),
      remoteAddress: remoteAddress
    )
  }
  let transferEncoding = rawHeaders["transfer-encoding"]
  let contentLengthText = rawHeaders["content-length"]
  guard transferEncoding == nil || contentLengthText == nil else {
    throw MCPHTTPServerError.invalidRequest(
      "Content-Length and Transfer-Encoding cannot be combined")
  }

  let initialBody = Data(storage[headerEnd.upperBound...])
  let body: Data
  if let transferEncoding {
    let codings = transferEncoding.split(separator: ",", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    guard codings == ["chunked"] else {
      throw MCPHTTPServerError.invalidRequest("unsupported Transfer-Encoding")
    }
    body = try mcpDecodeChunkedBody(
      initial: initialBody,
      maximumBodyBytes: maximumBodyBytes,
      maximumFramingBytes: maximumHeaderBytes
    ) { maximum in
      try mcpReadSocketChunk(descriptor, maximum: maximum)
    }
  } else {
    guard let contentLengthText, !contentLengthText.isEmpty,
      contentLengthText.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
      let contentLength = Int(contentLengthText), contentLength >= 0
    else { throw MCPHTTPServerError.invalidRequest("missing or invalid Content-Length") }
    guard contentLength <= maximumBodyBytes else {
      throw MCPHTTPServerError.payloadTooLarge
    }
    guard initialBody.count <= contentLength else {
      throw MCPHTTPServerError.invalidRequest("unexpected bytes after request body")
    }
    var contentLengthBody = initialBody
    while contentLengthBody.count < contentLength {
      contentLengthBody.append(
        try mcpReadSocketChunk(
          descriptor, maximum: min(8_192, contentLength - contentLengthBody.count)))
    }
    body = contentLengthBody
  }
  return MCPHTTPRequest(
    method: method,
    target: target,
    headers: MCPHTTPHeaders(rawHeaders),
    body: body,
    remoteAddress: remoteAddress
  )
}

private struct MCPHTTPBufferedBodyReader {
  var storage: Data
  var cursor = 0
  let readMore: (Int) throws -> Data

  var availableCount: Int { storage.count - cursor }

  mutating func readExact(_ count: Int) throws -> Data {
    guard count >= 0 else { throw MCPHTTPServerError.invalidRequest("invalid body length") }
    try ensureAvailable(count)
    let start = cursor
    cursor += count
    return Data(storage[start..<cursor])
  }

  mutating func readLine(maximumBytes: Int) throws -> Data {
    let delimiter = Data([13, 10])
    while true {
      if let range = storage.range(of: delimiter, in: cursor..<storage.endIndex) {
        let length = range.lowerBound - cursor
        guard length <= maximumBytes else {
          throw MCPHTTPServerError.invalidRequest("chunk framing line too large")
        }
        let line = Data(storage[cursor..<range.lowerBound])
        cursor = range.upperBound
        return line
      }
      guard availableCount <= maximumBytes else {
        throw MCPHTTPServerError.invalidRequest("chunk framing line too large")
      }
      try appendMore(maximum: min(8_192, maximumBytes + 2 - availableCount))
    }
  }

  mutating func requireExhausted() throws {
    guard availableCount == 0 else {
      throw MCPHTTPServerError.invalidRequest("unexpected bytes after chunked request body")
    }
  }

  private mutating func ensureAvailable(_ count: Int) throws {
    while availableCount < count {
      try appendMore(maximum: min(8_192, count - availableCount))
    }
  }

  private mutating func appendMore(maximum: Int) throws {
    compactIfNeeded()
    let chunk = try readMore(max(1, maximum))
    guard !chunk.isEmpty else {
      throw MCPHTTPServerError.connection("peer closed connection")
    }
    storage.append(chunk)
  }

  private mutating func compactIfNeeded() {
    guard cursor > 0, cursor >= 8_192 || cursor * 2 >= storage.count else { return }
    storage.removeSubrange(0..<cursor)
    cursor = 0
  }
}

func mcpDecodeChunkedBody(
  initial: Data,
  maximumBodyBytes: Int,
  maximumFramingBytes: Int,
  readMore: @escaping (Int) throws -> Data
) throws -> Data {
  guard maximumBodyBytes >= 0, maximumFramingBytes > 0 else {
    throw MCPHTTPServerError.invalidRequest("invalid chunked body limits")
  }
  var reader = MCPHTTPBufferedBodyReader(storage: initial, readMore: readMore)
  var body = Data()
  var framingBytes = 0

  while true {
    let sizeLine = try reader.readLine(maximumBytes: min(8_192, maximumFramingBytes))
    framingBytes += sizeLine.count + 2
    guard framingBytes <= maximumFramingBytes else {
      throw MCPHTTPServerError.invalidRequest("chunk framing too large")
    }

    let components = sizeLine.split(separator: 59, maxSplits: 1, omittingEmptySubsequences: false)
    guard let sizeToken = components.first, !sizeToken.isEmpty,
      sizeToken.allSatisfy({ byte in
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
      }),
      let chunkLength = UInt64(String(decoding: sizeToken, as: UTF8.self), radix: 16),
      chunkLength <= UInt64(Int.max)
    else { throw MCPHTTPServerError.invalidRequest("invalid chunk size") }

    if components.count == 2 {
      let extensionBytes = components[1]
      guard !extensionBytes.isEmpty,
        extensionBytes.allSatisfy({ byte in byte == 9 || (32...126).contains(byte) })
      else { throw MCPHTTPServerError.invalidRequest("invalid chunk extension") }
    }

    if chunkLength == 0 {
      let trailerTerminator = try reader.readLine(
        maximumBytes: min(8_192, maximumFramingBytes - framingBytes))
      framingBytes += trailerTerminator.count + 2
      guard framingBytes <= maximumFramingBytes else {
        throw MCPHTTPServerError.invalidRequest("chunk framing too large")
      }
      guard trailerTerminator.isEmpty else {
        throw MCPHTTPServerError.invalidRequest("chunk trailers are not supported")
      }
      try reader.requireExhausted()
      return body
    }

    let length = Int(chunkLength)
    guard length <= maximumBodyBytes - body.count else {
      throw MCPHTTPServerError.payloadTooLarge
    }
    body.append(try reader.readExact(length))
    guard try reader.readExact(2) == Data([13, 10]) else {
      throw MCPHTTPServerError.invalidRequest("invalid chunk delimiter")
    }
    framingBytes += 2
    guard framingBytes <= maximumFramingBytes else {
      throw MCPHTTPServerError.invalidRequest("chunk framing too large")
    }
  }
}

private func mcpReadSocketChunk(_ descriptor: Int32, maximum: Int) throws -> Data {
  guard maximum > 0 else { throw MCPHTTPServerError.connection("zero-byte read requested") }
  var buffer = [UInt8](repeating: 0, count: maximum)
  while true {
    let count = recv(descriptor, &buffer, buffer.count, 0)
    if count > 0 { return Data(buffer.prefix(count)) }
    if count == 0 { throw MCPHTTPServerError.connection("peer closed connection") }
    if errno == EINTR { continue }
    throw MCPHTTPServerError.connection(mcpErrnoDescription())
  }
}

private func mcpWriteHTTPResponse(
  _ response: MCPHTTPResponse,
  to descriptor: Int32,
  on ioQueue: DispatchQueue
) async throws {
  try response.headers.validate()
  var headers = response.headers
  headers["connection"] = "close"
  switch response.body {
  case .empty:
    headers["content-length"] = "0"
    try await mcpWriteAll(
      descriptor,
      data: mcpHTTPHead(status: response.status, headers: headers),
      on: ioQueue
    )
  case .bytes(let body):
    headers["content-length"] = String(body.count)
    try await mcpWriteAll(
      descriptor,
      data: mcpHTTPHead(status: response.status, headers: headers),
      on: ioQueue
    )
    try await mcpWriteAll(descriptor, data: body, on: ioQueue)
  case .stream(let stream):
    headers["transfer-encoding"] = "chunked"
    try await mcpWriteAll(
      descriptor,
      data: mcpHTTPHead(status: response.status, headers: headers),
      on: ioQueue
    )
    do {
      for try await chunk in stream.chunks {
        try Task.checkCancellation()
        let prefix = Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8)
        try await mcpWriteAll(descriptor, data: prefix, on: ioQueue)
        try await mcpWriteAll(descriptor, data: chunk, on: ioQueue)
        try await mcpWriteAll(descriptor, data: Data("\r\n".utf8), on: ioQueue)
      }
      try await mcpWriteAll(descriptor, data: Data("0\r\n\r\n".utf8), on: ioQueue)
    } catch {
      await stream.cancel()
      throw error
    }
  }
}

private func mcpHTTPHead(status: Int, headers: MCPHTTPHeaders) -> Data {
  let reason: String =
    switch status {
    case 200: "OK"
    case 202: "Accepted"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 406: "Not Acceptable"
    case 413: "Payload Too Large"
    case 415: "Unsupported Media Type"
    case 500: "Internal Server Error"
    default: "HTTP Response"
    }
  var text = "HTTP/1.1 \(status) \(reason)\r\n"
  for (name, value) in headers.values.sorted(by: { $0.key < $1.key }) {
    text += "\(name): \(value)\r\n"
  }
  text += "\r\n"
  return Data(text.utf8)
}

private func mcpWriteAll(_ descriptor: Int32, data: Data, on ioQueue: DispatchQueue) async throws {
  try await mcpPerformBlocking(on: ioQueue) {
    try mcpWriteAllBlocking(descriptor, data: data)
  }
}

private func mcpWriteAllBlocking(_ descriptor: Int32, data: Data) throws {
  try data.withUnsafeBytes { rawBuffer in
    guard let base = rawBuffer.baseAddress else { return }
    var offset = 0
    while offset < rawBuffer.count {
      let count = send(
        descriptor, base.advanced(by: offset), rawBuffer.count - offset, mcpNoSignalFlag())
      if count < 0 {
        if errno == EINTR { continue }
        throw MCPHTTPServerError.connection(mcpErrnoDescription())
      }
      guard count > 0 else { throw MCPHTTPServerError.connection("zero-byte socket write") }
      offset += count
    }
  }
}

private func mcpNoSignalFlag() -> Int32 {
  #if canImport(Glibc)
    return Int32(MSG_NOSIGNAL)
  #else
    return 0
  #endif
}
