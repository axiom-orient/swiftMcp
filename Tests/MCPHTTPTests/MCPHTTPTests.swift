@preconcurrency import Foundation
import XCTest

@testable import MCP
@testable import MCPHTTPClient
@testable import MCPHTTPServer
@testable import MCPHTTPShared

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

private actor HTTPValueCapture<Value: Sendable> {
  private var values: [Value] = []
  func append(_ value: Value) { values.append(value) }
  func snapshot() -> [Value] { values }
}

private actor HTTPManualGate {
  private var entered = false
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func enterAndWait() async {
    entered = true
    let entryWaiters = entryWaiters
    self.entryWaiters.removeAll()
    for waiter in entryWaiters { waiter.resume() }
    guard !released else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func release() {
    released = true
    let releaseWaiters = releaseWaiters
    self.releaseWaiters.removeAll()
    for waiter in releaseWaiters { waiter.resume() }
  }
}

private actor HTTPSequenceAuthorizationProvider: MCPHTTPAuthorizationProvider {
  private var values: [String?]
  private var calls = 0

  init(_ values: [String?]) { self.values = values }

  func authorizationHeader(for resource: URL) async throws -> String? {
    _ = resource
    calls += 1
    return values.isEmpty ? nil : values.removeFirst()
  }

  func callCount() -> Int { calls }
}

private final class HTTPRedirectCompletionCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var request: URLRequest?
  func record(_ request: URLRequest?) { lock.withLock { self.request = request } }
  var followedRequest: URLRequest? { lock.withLock { request } }
}

private func httpTestSocketType() -> Int32 {
  #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
  #else
    SOCK_STREAM
  #endif
}

/// Opens a loopback connection the caller owns, so a test can keep it open across server writes
/// or discard it deliberately. The caller closes the returned descriptor.
private func connectLoopback(port: Int) throws -> Int32 {
  guard (1...65_535).contains(port) else { throw NSError(domain: "MCPHTTPTests", code: 1) }
  let descriptor = socket(AF_INET, httpTestSocketType(), 0)
  guard descriptor >= 0 else { throw NSError(domain: "MCPHTTPTests", code: Int(errno)) }
  var address = sockaddr_in()
  #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  #endif
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = in_port_t(UInt16(port).bigEndian)
  guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
    _ = close(descriptor)
    throw NSError(domain: "MCPHTTPTests", code: 2)
  }
  let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard connected == 0 else {
    let reason = errno
    _ = close(descriptor)
    throw NSError(domain: "MCPHTTPTests", code: Int(reason))
  }
  return descriptor
}

private func sendAll(_ data: Data, to descriptor: Int32) throws {
  try data.withUnsafeBytes { bytes in
    guard let baseAddress = bytes.baseAddress else { return }
    var offset = 0
    while offset < bytes.count {
      let written = send(descriptor, baseAddress.advanced(by: offset), bytes.count - offset, 0)
      guard written > 0 else { throw NSError(domain: "MCPHTTPTests", code: Int(errno)) }
      offset += written
    }
  }
}

private func peerClosesConnection(_ descriptor: Int32, within seconds: Int = 1) -> Bool {
  var timeout = timeval()
  timeout.tv_sec = numericCast(seconds)
  timeout.tv_usec = 0
  var timeoutCopy = timeout
  guard
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeoutCopy,
      socklen_t(MemoryLayout<timeval>.size)
    ) == 0
  else { return false }

  var byte: UInt8 = 0
  let count = recv(descriptor, &byte, 1, 0)
  return count == 0 || (count < 0 && errno == ECONNRESET)
}

private func sendRawHTTP11Request(_ request: Data, to endpoint: URL) throws -> Data {
  guard endpoint.host == "127.0.0.1", let port = endpoint.port, (1...65_535).contains(port)
  else { throw NSError(domain: "MCPHTTPTests", code: 1) }

  let descriptor = socket(AF_INET, httpTestSocketType(), 0)
  guard descriptor >= 0 else {
    throw NSError(domain: "MCPHTTPTests", code: Int(errno))
  }
  defer {
    _ = shutdown(descriptor, Int32(SHUT_RDWR))
    _ = close(descriptor)
  }

  var address = sockaddr_in()
  #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  #endif
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = in_port_t(UInt16(port).bigEndian)
  guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
    throw NSError(domain: "MCPHTTPTests", code: 2)
  }
  let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard connected == 0 else {
    throw NSError(domain: "MCPHTTPTests", code: Int(errno))
  }

  try request.withUnsafeBytes { bytes in
    guard let baseAddress = bytes.baseAddress else { return }
    var offset = 0
    while offset < bytes.count {
      let written = send(descriptor, baseAddress.advanced(by: offset), bytes.count - offset, 0)
      guard written > 0 else {
        throw NSError(domain: "MCPHTTPTests", code: Int(errno))
      }
      offset += written
    }
  }
  _ = shutdown(descriptor, Int32(SHUT_WR))

  var response = Data()
  var buffer = [UInt8](repeating: 0, count: 8_192)
  while true {
    let count = recv(descriptor, &buffer, buffer.count, 0)
    if count == 0 { break }
    guard count > 0 else {
      if errno == EINTR { continue }
      throw NSError(domain: "MCPHTTPTests", code: Int(errno))
    }
    response.append(contentsOf: buffer.prefix(count))
  }
  return response
}

final class MCPHTTPTests: XCTestCase {
  private let directHandlerEndpoint = URL(string: "http://127.0.0.1/mcp")!

  private func handle(
    _ handler: MCPHTTPServerHandler,
    _ request: MCPHTTPRequest,
    effectiveEndpoint: URL? = nil
  ) async -> MCPHTTPResponse {
    await handler.handle(
      request,
      effectiveEndpoint: effectiveEndpoint ?? directHandlerEndpoint
    )
  }

  private func implementation(_ name: String) throws -> MCPImplementation {
    try MCPImplementation(name: name, version: "1.0.0")
  }

  private func annotatedTool(name: String = "echo") throws -> MCPTool {
    try MCPTool(
      name: name,
      description: "HTTP header fixture",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "region": .object([
            "type": .string("string"),
            "x-mcp-header": .string("Region"),
          ]),
          "count": .object([
            "type": .string("integer"),
            "x-mcp-header": .string("Count"),
          ]),
          "nested": .object([
            "type": .string("object"),
            "properties": .object([
              "enabled": .object([
                "type": .string("boolean"),
                "x-mcp-header": .string("Enabled"),
              ])
            ]),
          ]),
        ]),
      ],
      outputSchema: ["type": .string("object")]
    )
  }

  private func makeServer(
    authorization: any MCPHTTPAuthorizationVerifier = MCPHTTPAllowAllAuthorizationVerifier(),
    contexts: HTTPValueCapture<MCPRequestContext>? = nil,
    resolverNames: HTTPValueCapture<String>? = nil,
    toolHeaderValidationPolicy: MCPHTTPToolHeaderValidationPolicy = .required
  ) throws -> (MCPServer, MCPTool, MCPHTTPConfiguration) {
    let tool = try annotatedTool()
    var builder = try MCPServerBuilder(implementation: implementation("http-server"))
    builder.setToolResolver { name, _ in
      await resolverNames?.append(name)
      return name == tool.name ? tool : nil
    }
    try builder.register(MCPStandardMethods.listTools) { _, context in
      await contexts?.append(context)
      return MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { params, context in
      await contexts?.append(context)
      try await context.progress?.report(progress: 0.5, total: 1, message: "half")
      try await context.progress?.report(progress: 1, total: 1, message: "done")
      return try MCPCallToolResult(
        content: [.text(MCPTextContent(text: params.name))],
        structuredContent: .object(["arguments": .object(params.arguments)])
      )
    }
    builder.enableToolListChanged()
    let server = try builder.build()
    let configuration = try MCPHTTPConfiguration(
      authorizationVerifier: authorization,
      socketTimeout: 5,
      toolHeaderValidationPolicy: toolHeaderValidationPolicy
    )
    return (server, tool, configuration)
  }

  private func request(
    method: MCPMethodDescriptor,
    id: Int64 = 1,
    params: [String: MCPJSONValue],
    toolSchema: MCPHTTPToolHeaderSchema? = nil,
    host: String = "127.0.0.1",
    clientName: String = "http-client"
  ) throws -> MCPHTTPRequest {
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation(clientName)
    )
    let wire = try MCPWireRequest(
      id: MCPRequestID(id),
      method: method.name,
      params: metadata.inserting(into: params)
    )
    var headers = try MCPHTTPStandardHeaders.make(
      for: wire,
      descriptor: method,
      toolSchema: toolSchema
    )
    headers["content-type"] = "application/json"
    headers["accept"] = "application/json, text/event-stream"
    headers["host"] = host
    return MCPHTTPRequest(
      method: "POST",
      target: "/mcp",
      headers: headers,
      body: try MCPWireMessage.request(wire).encoded(),
      remoteAddress: "127.0.0.1"
    )
  }

  private func responseBytes(_ response: MCPHTTPResponse) async throws -> Data {
    switch response.body {
    case .empty:
      return Data()
    case .bytes(let value):
      return value
    case .stream(let stream):
      var result = Data()
      for try await chunk in stream.chunks { result.append(chunk) }
      return result
    }
  }

  func testHTTPUsesTheRequestLocalResolvedToolExactlyOnce() async throws {
    let resolverNames = HTTPValueCapture<String>()
    let (server, tool, configuration) = try makeServer(resolverNames: resolverNames)
    let handler = MCPHTTPServerHandler(server: server, configuration: configuration)
    let descriptor = try server.registry.require("tools/call")
    let params = try MCPCallToolParams(
      name: tool.name,
      arguments: [
        "region": .string("서울"),
        "count": .number(try MCPJSONNumber(rawValue: "42")),
        "nested": .object(["enabled": .bool(true)]),
      ]
    )
    let request = try request(
      method: descriptor,
      params: params.json.objectValue ?? [:],
      toolSchema: MCPHTTPToolHeaderSchema(tool: tool)
    )

    let response = await handle(handler, request)
    XCTAssertEqual(response.status, 200)
    _ = try await responseBytes(response)
    let resolvedNames = await resolverNames.snapshot()
    XCTAssertEqual(resolvedNames, [tool.name])
  }

  func testHTTPTransportOwnsAndEnforcesJSONDecodeLimits() async throws {
    let (server, _, _) = try makeServer()
    let limits = MCPJSONLimits(maximumNumberBytes: 1)
    let configuration = try MCPHTTPConfiguration(jsonLimits: limits)
    let handler = MCPHTTPServerHandler(server: server, configuration: configuration)
    let descriptor = try server.registry.require("tools/list")
    let oversizedID = try request(
      method: descriptor,
      id: 10,
      params: MCPListToolsParams().json.objectValue ?? [:]
    )

    let response = await handle(handler, oversizedID)
    XCTAssertEqual(response.status, 400)
    guard case .error(let wireError) = try MCPWireMessage.decode(await responseBytes(response))
    else {
      return XCTFail("expected parse error")
    }
    XCTAssertEqual(wireError.error.code, -32700)

    XCTAssertThrowsError(
      try MCPHTTPClientConfiguration(
        endpoint: URL(string: "http://127.0.0.1/mcp")!,
        jsonLimits: MCPJSONLimits(maximumDocumentBytes: 0)
      )
    )
    XCTAssertThrowsError(try MCPHTTPConfiguration(socketTimeout: .infinity))
    XCTAssertThrowsError(
      try MCPHTTPClientConfiguration(
        endpoint: URL(string: "http://127.0.0.1/mcp")!,
        networkTimeout: .infinity
      )
    )
    XCTAssertThrowsError(
      try MCPHTTPClientConfiguration(
        endpoint: URL(string: "http://127.0.0.1/mcp")!,
        subscriptionTimeout: 0
      )
    )
  }

  func testServerConfigurationValidatesConnectionCap() throws {
    XCTAssertEqual(try MCPHTTPConfiguration().maximumConcurrentConnections, 32)
    XCTAssertEqual(try MCPHTTPConfiguration().listenBacklog, 128)
    XCTAssertEqual(try MCPHTTPConfiguration().sseKeepAliveInterval, 15)
    XCTAssertEqual(try MCPHTTPConfiguration().requestReadTimeout, 10)
    XCTAssertThrowsError(try MCPHTTPConfiguration(maximumConcurrentConnections: 0))
    XCTAssertThrowsError(try MCPHTTPConfiguration(maximumConcurrentConnections: -1))
    XCTAssertThrowsError(try MCPHTTPConfiguration(listenBacklog: 0))
    XCTAssertThrowsError(try MCPHTTPConfiguration(requestReadTimeout: 0))
    XCTAssertThrowsError(try MCPHTTPConfiguration(requestReadTimeout: .infinity))
    XCTAssertThrowsError(try MCPHTTPConfiguration(sseKeepAliveInterval: 0))
    XCTAssertThrowsError(try MCPHTTPConfiguration(sseKeepAliveInterval: .infinity))
    XCTAssertEqual(
      try MCPHTTPConfiguration(maximumConcurrentConnections: 7).maximumConcurrentConnections,
      7
    )
  }

  func testHeaderValueCodecAndCaseInsensitiveHeaders() throws {
    XCTAssertEqual(MCPHTTPHeaderValueCodec.encode("plain"), "plain")
    XCTAssertEqual(
      try MCPHTTPHeaderValueCodec.decode(MCPHTTPHeaderValueCodec.encode("Hello, 세계")),
      "Hello, 세계"
    )
    XCTAssertEqual(
      try MCPHTTPHeaderValueCodec.decode(MCPHTTPHeaderValueCodec.encode("=?base64?literal?=")),
      "=?base64?literal?="
    )
    XCTAssertEqual(
      try MCPHTTPHeaderValueCodec.decode("=?BASE64?literal?="),
      "=?BASE64?literal?="
    )
    XCTAssertThrowsError(try MCPHTTPHeaderValueCodec.decode("=?base64?not-valid?="))
    XCTAssertThrowsError(try MCPHTTPHeaderValueCodec.decode("Hello, 세계"))
    XCTAssertThrowsError(try MCPHTTPHeaderValueCodec.decode(" leading"))
    XCTAssertThrowsError(try MCPHTTPHeaderValueCodec.decode("trailing\t"))
    XCTAssertThrowsError(try MCPHTTPHeaderValueCodec.decode("line\nbreak"))

    var headers = MCPHTTPHeaders(["Mcp-Method": "tools/list"])
    XCTAssertEqual(headers["mcp-method"], "tools/list")
    headers["MCP-METHOD"] = "tools/call"
    XCTAssertEqual(headers["Mcp-Method"], "tools/call")

    let ambiguous = MCPHTTPHeaders(["X-Tenant": "one", "x-tenant": "two"])
    XCTAssertThrowsError(try ambiguous.validate())
    XCTAssertThrowsError(try MCPHTTPHeaders(["Bad Name": "value"]).validate()) { error in
      XCTAssertEqual(error as? MCPHTTPError, .invalidHeaderName("bad name"))
    }
    XCTAssertThrowsError(try MCPHTTPHeaders(["Authorization": "Bearer ok\r\nX: y"]).validate()) {
      error in
      XCTAssertEqual(error as? MCPHTTPError, .invalidHeaderEncoding("authorization"))
    }
    XCTAssertThrowsError(
      try MCPHTTPClientConfiguration(
        endpoint: URL(string: "http://127.0.0.1/mcp")!,
        additionalHeaders: ambiguous
      )
    )
    for reservedName in [
      "Mcp-Protocol-Version", "mCp-MeThOd", "MCP-NAME", "Mcp-Session-Id",
      "Last-Event-ID", "Authorization", "Mcp-Param-Region",
    ] {
      XCTAssertThrowsError(
        try MCPHTTPClientConfiguration(
          endpoint: URL(string: "http://127.0.0.1/mcp")!,
          additionalHeaders: MCPHTTPHeaders([reservedName: "override"])
        ),
        reservedName
      )
    }
  }

  func testAuthorizationProviderIsRevalidatedForEveryRequest() async throws {
    let provider = HTTPSequenceAuthorizationProvider([
      "Bearer first",
      "Bearer second\r\nX-Injected: true",
    ])
    let transport = MCPHTTPClientTransport(
      configuration: try MCPHTTPClientConfiguration(
        endpoint: URL(string: "http://127.0.0.1:9/mcp")!,
        authorizationProvider: provider,
        networkTimeout: 1
      )
    )
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("authorization-client")
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(1),
      method: "server/discover",
      params: metadata.inserting(into: [:])
    )

    let first = try await transport.open(request)
    try await first.cancel(reason: "test completed")

    do {
      let second = try await transport.open(request)
      try await second.cancel(reason: "invalid Authorization was accepted")
      XCTFail("request-time Authorization must reject header injection")
    } catch let error as MCPHTTPError {
      XCTAssertEqual(error, .invalidHeaderEncoding("authorization"))
    }
    let callCount = await provider.callCount()
    XCTAssertEqual(callCount, 2)
  }

  func testToolHeaderSchemaExactIntegerAndTypeValidation() throws {
    let schema = try MCPHTTPToolHeaderSchema(tool: annotatedTool())
    let arguments: [String: MCPJSONValue] = [
      "region": .string("서울"),
      "count": .number(try MCPJSONNumber(rawValue: "4.2e1")),
      "nested": .object(["enabled": .bool(true)]),
    ]
    let headers = try schema.generatedHeaders(arguments: arguments)
    XCTAssertEqual(try MCPHTTPHeaderValueCodec.decode(headers["Mcp-Param-Region"]!), "서울")
    XCTAssertEqual(headers["Mcp-Param-Count"], "42")
    XCTAssertEqual(headers["Mcp-Param-Enabled"], "true")
    XCTAssertNoThrow(try schema.validate(headers: headers, arguments: arguments))
    var numericallyEquivalent = headers
    numericallyEquivalent["Mcp-Param-Count"] = "42.0"
    XCTAssertNoThrow(
      try schema.validate(headers: numericallyEquivalent, arguments: arguments))

    XCTAssertThrowsError(
      try schema.generatedHeaders(arguments: [
        "region": .bool(true),
        "count": .integer(1),
      ])
    )
    XCTAssertThrowsError(
      try schema.generatedHeaders(arguments: [
        "region": .string("x"),
        "count": .number(try MCPJSONNumber(rawValue: "9007199254740992")),
      ])
    )
  }

  func testStandardHeadersMirrorEveryNamedRequestAndRejectMissingName() throws {
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("header-client")
    )
    let cases: [(String, [String: MCPJSONValue], String)] = [
      (
        "tools/call",
        try MCPCallToolParams(name: "날씨 도구").json.objectValue ?? [:],
        "날씨 도구"
      ),
      (
        "resources/read",
        try MCPReadResourceParams(uri: "https://example.com/자료?id=1").json.objectValue ?? [:],
        "https://example.com/자료?id=1"
      ),
      (
        "prompts/get",
        try MCPGetPromptParams(name: "코드 리뷰").json.objectValue ?? [:],
        "코드 리뷰"
      ),
    ]

    for (method, rawParams, expectedName) in cases {
      let descriptor = try MCPMethodRegistry.standard.require(method)
      let request = try MCPWireRequest(
        id: MCPRequestID(1),
        method: method,
        params: metadata.inserting(into: rawParams)
      )
      var headers = try MCPHTTPStandardHeaders.make(for: request, descriptor: descriptor)

      XCTAssertEqual(headers[MCPHTTPHeaderName.method], method)
      XCTAssertEqual(
        try MCPHTTPHeaderValueCodec.decode(
          try XCTUnwrap(headers[MCPHTTPHeaderName.name])),
        expectedName
      )
      XCTAssertNoThrow(
        try MCPHTTPStandardHeaders.validate(headers, request: request, descriptor: descriptor)
      )

      headers[MCPHTTPHeaderName.name] = nil
      XCTAssertThrowsError(
        try MCPHTTPStandardHeaders.validate(headers, request: request, descriptor: descriptor)
      ) { error in
        XCTAssertEqual(error as? MCPHTTPError, .headerMismatch("missing Mcp-Name"))
      }
    }
  }

  func testInvalidToolAnnotationsAreExcludedAndObservable() throws {
    let valid = try annotatedTool(name: "valid")
    let invalid = try MCPTool(
      name: "invalid",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "values": .object([
            "type": .string("array"),
            "items": .object([
              "type": .string("string"),
              "x-mcp-header": .string("Unreachable"),
            ]),
          ])
        ]),
      ]
    )
    let catalog = MCPHTTPToolCatalog()
    XCTAssertEqual(catalog.registerValidTools([valid, invalid]).map(\.name), ["valid"])
    XCTAssertEqual(catalog.rejectedTools.map(\.name), ["invalid"])
    XCTAssertNotNil(catalog.rejectedTools.first?.reason)
  }

  func testInvalidatedHTTPToolCatalogRejectsAnInflightStaleListPage() throws {
    let catalog = MCPHTTPToolCatalog()
    let generation = catalog.snapshotGeneration()
    let tool = try annotatedTool(name: "stale")

    catalog.removeAll()
    XCTAssertEqual(
      catalog.registerValidTools([tool], expectedGeneration: generation).map(\.name),
      ["stale"]
    )
    XCTAssertNil(catalog.schema(for: "stale"))
  }

  func testChunkedRequestBodyDecoderHandlesFragmentationAndRejectsAmbiguity() throws {
    var fragments = [
      Data("ki\r\n5;name=value\r\npe".utf8),
      Data("dia\r\n0\r\n\r\n".utf8),
    ]
    let decoded = try mcpDecodeChunkedBody(
      initial: Data("4\r\nWi".utf8),
      maximumBodyBytes: 9,
      maximumFramingBytes: 1_024
    ) { _ in
      fragments.isEmpty ? Data() : fragments.removeFirst()
    }
    XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "Wikipedia")

    XCTAssertThrowsError(
      try mcpDecodeChunkedBody(
        initial: Data("4\r\nWiki\r\n0\r\nTrailer: value\r\n\r\n".utf8),
        maximumBodyBytes: 4,
        maximumFramingBytes: 1_024,
        readMore: { _ in Data() }
      )
    )
    XCTAssertThrowsError(
      try mcpDecodeChunkedBody(
        initial: Data("4\r\nWiki\r\n0\r\n\r\nextra".utf8),
        maximumBodyBytes: 4,
        maximumFramingBytes: 1_024,
        readMore: { _ in Data() }
      )
    )
    XCTAssertThrowsError(
      try mcpDecodeChunkedBody(
        initial: Data("5\r\nhello\r\n0\r\n\r\n".utf8),
        maximumBodyBytes: 4,
        maximumFramingBytes: 1_024,
        readMore: { _ in Data() }
      )
    )

    let exactFraming = Data("1\r\na\r\n0\r\n\r\n".utf8)
    XCTAssertEqual(
      try mcpDecodeChunkedBody(
        initial: exactFraming,
        maximumBodyBytes: 1,
        maximumFramingBytes: 10,
        readMore: { _ in Data() }
      ),
      Data("a".utf8)
    )
    XCTAssertThrowsError(
      try mcpDecodeChunkedBody(
        initial: exactFraming,
        maximumBodyBytes: 1,
        maximumFramingBytes: 9,
        readMore: { _ in Data() }
      )
    ) { error in
      guard case MCPHTTPServerError.invalidRequest(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(reason, "chunk framing too large")
    }
  }

  func testSSEIncrementalRoundTripAndLimits() throws {
    let payload = Data("{\"line\":\"a\\nb\"}".utf8)
    let encoded = MCPSSEEncoder.dataEvent(payload)
    var decoder = try MCPSSEDecoder(maximumEventBytes: 1_024)
    var events: [Data] = []
    for byte in encoded { events += try decoder.append(Data([byte])) }
    events += try decoder.finish()
    XCTAssertEqual(events, [payload])

    // One network read may carry multiple complete events whose aggregate size exceeds the
    // per-event limit. The decoder must bound each unfinished event, not the transport chunk.
    var batched = try MCPSSEDecoder(maximumEventBytes: 12)
    let batchedEvents = try batched.append(Data("data: a\n\ndata: b\n\n".utf8))
    XCTAssertEqual(batchedEvents, [Data("a".utf8), Data("b".utf8)])
    XCTAssertNoThrow(try batched.finish())

    var keepalive = try MCPSSEDecoder(maximumEventBytes: 64)
    let afterKeepalive = try keepalive.append(
      Data(": keepalive\r\n\r\ndata: {\"ok\":true}\r\n\r\n".utf8)
    )
    XCTAssertEqual(afterKeepalive, [Data("{\"ok\":true}".utf8)])
    XCTAssertNoThrow(try keepalive.finish())

    var cumulative = try MCPSSEDecoder(maximumEventBytes: 16)
    XCTAssertThrowsError(try cumulative.append(Data("data: 12345678\ndata: 9\n\n".utf8)))

    var truncated = try MCPSSEDecoder()
    _ = try truncated.append(Data("data: {}\n".utf8))
    XCTAssertThrowsError(try truncated.finish())

    // A comment line is complete at its own line terminator and carries no event data, so a
    // stream that ends on a keep-alive has no partially delivered event. MCP requires clients to
    // ignore comments rather than treat them as malformed input, so SSE framing must report this
    // as a clean end. A listen stream that ends without its terminal response is still an error,
    // but it is raised by the client runtime, not by the framing decoder.
    var trailingComment = try MCPSSEDecoder()
    _ = try trailingComment.append(Data(": keepalive\n".utf8))
    XCTAssertNoThrow(try trailingComment.finish())

    // Quiet keep-alives must not accumulate against the event budget either: only an actual
    // unfinished event may exhaust it.
    var quiet = try MCPSSEDecoder(maximumEventBytes: 32)
    for _ in 0..<64 { _ = try quiet.append(Data(":\r\n".utf8)) }
    XCTAssertEqual(
      try quiet.append(Data("data: {\"ok\":true}\r\n\r\n".utf8)),
      [
        Data("{\"ok\":true}".utf8)
      ])
    XCTAssertNoThrow(try quiet.finish())

    // A single oversized comment is still bounded.
    var hugeComment = try MCPSSEDecoder(maximumEventBytes: 8)
    XCTAssertThrowsError(try hugeComment.append(Data(": 0123456789\n".utf8)))

    XCTAssertThrowsError(try MCPSSEEncoder.comment("bad\ncomment"))
  }

  func testHandlerRejectsMethodOriginAndHeaderMismatch() async throws {
    let (server, tool, configuration) = try makeServer()
    let handler = MCPHTTPServerHandler(server: server, configuration: configuration)
    let schema = try MCPHTTPToolHeaderSchema(tool: tool)
    let descriptor = try server.registry.require("tools/call")
    let params = try MCPCallToolParams(
      name: tool.name,
      arguments: ["region": .string("seoul"), "count": .integer(1)]
    )
    var valid = try request(
      method: descriptor,
      params: params.json.objectValue ?? [:],
      toolSchema: schema
    )

    let get = MCPHTTPRequest(
      method: "GET",
      target: valid.target,
      headers: valid.headers,
      body: valid.body
    )
    let getResponse = await handle(handler, get)
    XCTAssertEqual(getResponse.status, 405)

    var originHeaders = valid.headers
    originHeaders["origin"] = "http://evil.example"
    let badOrigin = MCPHTTPRequest(
      method: valid.method,
      target: valid.target,
      headers: originHeaders,
      body: valid.body
    )
    let badOriginResponse = await handle(handler, badOrigin)
    XCTAssertEqual(badOriginResponse.status, 403)
    let badOriginBytes = try await responseBytes(badOriginResponse)
    XCTAssertTrue(badOriginBytes.isEmpty)

    var mismatchHeaders = valid.headers
    mismatchHeaders[MCPHTTPHeaderName.method] = "tools/list"
    valid = MCPHTTPRequest(
      method: valid.method,
      target: valid.target,
      headers: mismatchHeaders,
      body: valid.body
    )
    let mismatch = await handle(handler, valid)
    XCTAssertEqual(mismatch.status, 400)
    let mismatchBody = try await responseBytes(mismatch)
    guard case .error(let error) = try MCPWireMessage.decode(mismatchBody) else {
      return XCTFail("expected HeaderMismatch error")
    }
    XCTAssertEqual(error.error.code, -32020)
  }

  func testToolHeaderValidationIsRequiredByDefault() async throws {
    let (defaultServer, defaultTool, defaultConfiguration) = try makeServer()
    let descriptor = try defaultServer.registry.require("tools/call")
    let params = try MCPCallToolParams(
      name: defaultTool.name,
      arguments: ["region": .string("seoul"), "count": .integer(1)]
    )
    let unbound = try request(method: descriptor, params: params.json.objectValue ?? [:])

    let defaultResponse = await handle(
      MCPHTTPServerHandler(server: defaultServer, configuration: defaultConfiguration), unbound)
    XCTAssertEqual(defaultResponse.status, 400)
    guard
      case .error(let defaultError) = try MCPWireMessage.decode(
        await responseBytes(defaultResponse))
    else { return XCTFail("expected HeaderMismatch error") }
    XCTAssertEqual(defaultError.error.code, -32020)

    var partialHeaders = unbound.headers
    partialHeaders["Mcp-Param-Region"] = "seoul"
    let partial = MCPHTTPRequest(
      method: unbound.method,
      target: unbound.target,
      headers: partialHeaders,
      body: unbound.body,
      remoteAddress: unbound.remoteAddress
    )
    let partialResponse = await handle(
      MCPHTTPServerHandler(server: defaultServer, configuration: defaultConfiguration), partial)
    XCTAssertEqual(partialResponse.status, 400)

    let (strictServer, _, strictConfiguration) = try makeServer(
      toolHeaderValidationPolicy: .required)
    let strictResponse = await handle(
      MCPHTTPServerHandler(server: strictServer, configuration: strictConfiguration), unbound)
    XCTAssertEqual(strictResponse.status, 400)
    guard
      case .error(let strictError) = try MCPWireMessage.decode(await responseBytes(strictResponse))
    else { return XCTFail("expected HeaderMismatch error") }
    XCTAssertEqual(strictError.error.code, -32020)
  }

  func testHandlerValidatesStatelessAuthorityBeforeUnknownMethodRouting() async throws {
    let (server, _, configuration) = try makeServer()
    let handler = MCPHTTPServerHandler(server: server, configuration: configuration)
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("unknown-method-client")
    )
    let wire = try MCPWireRequest(
      id: MCPRequestID(44),
      method: "vendor.example/unknown",
      params: ["_meta": metadata.json]
    )
    let body = try MCPWireMessage.request(wire).encoded()
    let baseHeaders = MCPHTTPHeaders([
      "host": "127.0.0.1",
      "content-type": "application/json",
      "accept": "application/json, text/event-stream",
    ])

    let missingAuthority = MCPHTTPRequest(
      method: "POST", target: "/mcp", headers: baseHeaders, body: body)
    let missingResponse = await handle(handler, missingAuthority)
    XCTAssertEqual(missingResponse.status, 400)
    guard
      case .error(let missingError) = try MCPWireMessage.decode(
        await responseBytes(missingResponse))
    else { return XCTFail("expected HeaderMismatch") }
    XCTAssertEqual(missingError.error.code, -32020)

    var validHeaders = baseHeaders
    validHeaders[MCPHTTPHeaderName.protocolVersion] = MCPProtocolVersion.current.rawValue
    validHeaders[MCPHTTPHeaderName.method] = wire.method
    let validAuthority = MCPHTTPRequest(
      method: "POST", target: "/mcp", headers: validHeaders, body: body)
    let unknownResponse = await handle(handler, validAuthority)
    XCTAssertEqual(unknownResponse.status, 404)
    guard
      case .error(let unknownError) = try MCPWireMessage.decode(
        await responseBytes(unknownResponse))
    else { return XCTFail("expected Method not found") }
    XCTAssertEqual(unknownError.error.code, -32601)
  }

  func testOriginValidationUsesTrustedEndpointInsteadOfHostHeader() async throws {
    let (server, _, _) = try makeServer()
    let configuration = try MCPHTTPConfiguration(
      publicEndpoint: URL(string: "https://api.example/mcp")!
    )
    let handler = MCPHTTPServerHandler(server: server, configuration: configuration)
    let descriptor = try server.registry.require("tools/list")
    var base = try request(
      method: descriptor,
      params: MCPListToolsParams().json.objectValue ?? [:],
      host: "api.example"
    )

    var acceptedHeaders = base.headers
    acceptedHeaders["origin"] = "https://api.example"
    base = MCPHTTPRequest(
      method: base.method,
      target: base.target,
      headers: acceptedHeaders,
      body: base.body,
      remoteAddress: base.remoteAddress
    )
    let accepted = await handle(handler, base)
    XCTAssertEqual(accepted.status, 200)

    var wrongSchemeHeaders = acceptedHeaders
    wrongSchemeHeaders["origin"] = "http://api.example"
    let wrongScheme = MCPHTTPRequest(
      method: base.method,
      target: base.target,
      headers: wrongSchemeHeaders,
      body: base.body,
      remoteAddress: base.remoteAddress
    )
    let rejectedScheme = await handle(handler, wrongScheme)
    XCTAssertEqual(rejectedScheme.status, 403)

    var rebindingHeaders = base.headers
    rebindingHeaders["host"] = "evil.example:9000"
    rebindingHeaders["origin"] = "http://evil.example:9000"
    let rebinding = MCPHTTPRequest(
      method: base.method,
      target: base.target,
      headers: rebindingHeaders,
      body: base.body,
      remoteAddress: base.remoteAddress
    )
    let trustedEndpoint = URL(string: "http://127.0.0.1:9000/mcp")!
    let rejectedRebinding = await handle(
      handler,
      rebinding, effectiveEndpoint: trustedEndpoint)
    XCTAssertEqual(rejectedRebinding.status, 403)

    let untrustedConfiguration = try MCPHTTPConfiguration()
    let untrustedHandler = MCPHTTPServerHandler(
      server: server, configuration: untrustedConfiguration)
    var selfAuthorizingHeaders = base.headers
    selfAuthorizingHeaders["host"] = "evil.example"
    selfAuthorizingHeaders["origin"] = "http://evil.example"
    let selfAuthorizing = MCPHTTPRequest(
      method: base.method,
      target: base.target,
      headers: selfAuthorizingHeaders,
      body: base.body
    )
    let failClosed = await untrustedHandler.handle(selfAuthorizing)
    XCTAssertEqual(failClosed.status, 400)
  }

  func testHandlerJSONAndSSEProtocolResponses() async throws {
    let contexts = HTTPValueCapture<MCPRequestContext>()
    let verifier = try MCPHTTPStaticBearerVerifier(
      token: "secret",
      context: MCPAuthorizationContext(subject: "alice", scopes: ["tools:call"])
    )
    let (server, tool, configuration) = try makeServer(authorization: verifier, contexts: contexts)
    let handler = MCPHTTPServerHandler(server: server, configuration: configuration)

    let listDescriptor = try server.registry.require("tools/list")
    var listRequest = try request(
      method: listDescriptor,
      params: MCPListToolsParams().json.objectValue ?? [:]
    )
    let unauthorized = await handle(handler, listRequest)
    XCTAssertEqual(unauthorized.status, 401)
    XCTAssertEqual(unauthorized.headers["www-authenticate"], "Bearer")
    let unauthorizedBytes = try await responseBytes(unauthorized)
    XCTAssertTrue(unauthorizedBytes.isEmpty)

    var authorizedHeaders = listRequest.headers
    authorizedHeaders["authorization"] = "Bearer secret"
    listRequest = MCPHTTPRequest(
      method: listRequest.method,
      target: listRequest.target,
      headers: authorizedHeaders,
      body: listRequest.body,
      remoteAddress: listRequest.remoteAddress
    )
    let listed = await handle(handler, listRequest)
    XCTAssertEqual(listed.status, 200)
    guard case .result(let listedWire) = try MCPWireMessage.decode(try await responseBytes(listed))
    else {
      return XCTFail("expected list result")
    }
    XCTAssertEqual(
      try MCPListToolsResult(json: .object(listedWire.value)).tools.map(\.name), [tool.name])

    let callDescriptor = try server.registry.require("tools/call")
    let callParams = try MCPCallToolParams(
      name: tool.name,
      arguments: ["region": .string("서울"), "count": .integer(7)]
    )
    var callRequest = try request(
      method: callDescriptor,
      id: 2,
      params: callParams.json.objectValue ?? [:],
      toolSchema: try MCPHTTPToolHeaderSchema(tool: tool)
    )
    var callHeaders = callRequest.headers
    callHeaders["authorization"] = "Bearer secret"
    callRequest = MCPHTTPRequest(
      method: callRequest.method,
      target: callRequest.target,
      headers: callHeaders,
      body: callRequest.body,
      remoteAddress: callRequest.remoteAddress
    )
    let called = await handle(handler, callRequest)
    XCTAssertEqual(called.status, 200)
    XCTAssertEqual(called.headers["content-type"], "application/json")

    let captured = await contexts.snapshot()
    XCTAssertEqual(captured.count, 2)
    XCTAssertTrue(captured.allSatisfy { $0.authorization.subject == "alice" })
  }

  func testHTTPRequestsWithTheSameIDKeepMetadataStatelessAndIgnoreSessionHeaders() async throws {
    let contexts = HTTPValueCapture<MCPRequestContext>()
    let (server, _, configuration) = try makeServer(contexts: contexts)
    let handler = MCPHTTPServerHandler(server: server, configuration: configuration)
    let descriptor = try server.registry.require("tools/list")

    var first = try request(
      method: descriptor,
      id: 7,
      params: MCPListToolsParams().json.objectValue ?? [:],
      clientName: "client-a"
    )
    var firstHeaders = first.headers
    firstHeaders["Mcp-Session-Id"] = "legacy-a"
    first = MCPHTTPRequest(
      method: first.method,
      target: first.target,
      headers: firstHeaders,
      body: first.body,
      remoteAddress: first.remoteAddress
    )

    var second = try request(
      method: descriptor,
      id: 7,
      params: MCPListToolsParams().json.objectValue ?? [:],
      clientName: "client-b"
    )
    var secondHeaders = second.headers
    secondHeaders["Mcp-Session-Id"] = "legacy-b"
    second = MCPHTTPRequest(
      method: second.method,
      target: second.target,
      headers: secondHeaders,
      body: second.body,
      remoteAddress: second.remoteAddress
    )

    let effectiveEndpoint = directHandlerEndpoint
    async let firstResponse = handler.handle(first, effectiveEndpoint: effectiveEndpoint)
    async let secondResponse = handler.handle(second, effectiveEndpoint: effectiveEndpoint)
    let responses = await [firstResponse, secondResponse]

    for response in responses {
      XCTAssertEqual(response.status, 200)
      XCTAssertNil(response.headers["Mcp-Session-Id"])
      guard case .result(let result) = try MCPWireMessage.decode(await responseBytes(response))
      else { return XCTFail("expected tools/list result") }
      XCTAssertEqual(result.id, MCPRequestID(7))
    }

    let captured = await contexts.snapshot()
    XCTAssertEqual(captured.map(\.id), [MCPRequestID(7), MCPRequestID(7)])
    XCTAssertEqual(
      Set(captured.compactMap { $0.metadata.clientInfo?.name }),
      ["client-a", "client-b"]
    )
    XCTAssertTrue(captured.allSatisfy { $0.metadata.protocolVersion == .current })
  }

  func testHandlerMapsStatelessProtocolErrorsToHTTPStatus() async throws {
    var builder = try MCPServerBuilder(implementation: implementation("http-error-server"))
    try builder.register(MCPStandardMethods.complete) { _, _ -> MCPCompleteResult in
      throw MCPRPCError.invalidParams
    }
    let server = try builder.build()
    let handler = MCPHTTPServerHandler(
      server: server,
      configuration: try MCPHTTPConfiguration(socketTimeout: 5)
    )
    let descriptor = try server.registry.require("completion/complete")
    let params = try MCPCompleteParams(
      reference: .prompt(name: "summarize"),
      argument: MCPCompletionArgument(name: "topic", value: "sw")
    )
    let response = await handle(
      handler,
      try request(method: descriptor, params: params.json.objectValue ?? [:])
    )

    XCTAssertEqual(response.status, 400)
    guard case .error(let wireError) = try MCPWireMessage.decode(await responseBytes(response))
    else {
      return XCTFail("expected invalid params error")
    }
    XCTAssertEqual(wireError.error.code, -32602)
  }

  func testHTTPPrepareSanitizesResolverErrorsAsServerFailures() async throws {
    var builder = try MCPServerBuilder(implementation: implementation("http-resolver-error"))
    builder.setToolResolver { name, _ in
      if name == "reserved" {
        throw MCPRPCError(code: -32002, message: "retired")
      }
      throw MCPJSONError.invalidField(field: "tool", reason: "broken resolver")
    }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(content: [])
    }
    let server = try builder.build()
    let handler = MCPHTTPServerHandler(
      server: server,
      configuration: try MCPHTTPConfiguration(socketTimeout: 5)
    )
    let descriptor = try server.registry.require("tools/call")

    for name in ["reserved", "broken"] {
      let params = try MCPCallToolParams(name: name, arguments: [:])
      let response = await handle(
        handler,
        try request(method: descriptor, params: params.json.objectValue ?? [:])
      )
      XCTAssertEqual(response.status, 500, name)
      guard case .error(let wireError) = try MCPWireMessage.decode(await responseBytes(response))
      else { return XCTFail("expected internal error for \(name)") }
      XCTAssertEqual(wireError.error.code, -32603, name)
    }
  }

  func testRealLoopbackAcceptsBoundedChunkedRequestBody() async throws {
    let (server, _, configuration) = try makeServer()
    let httpServer = MCPHTTPServer(server: server, configuration: configuration)
    let endpoint = try httpServer.start()
    defer { Task { await httpServer.shutdown() } }

    let descriptor = try server.registry.require("tools/list")
    let logicalRequest = try request(
      method: descriptor,
      params: MCPListToolsParams().json.objectValue ?? [:],
      host: "127.0.0.1:\(try XCTUnwrap(endpoint.port))"
    )
    var headers = logicalRequest.headers.values
    headers["transfer-encoding"] = "chunked"
    headers["connection"] = "close"
    headers.removeValue(forKey: "content-length")

    var raw = Data("POST /mcp HTTP/1.1\r\n".utf8)
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      raw.append(Data("\(name): \(value)\r\n".utf8))
    }
    raw.append(Data("\r\n".utf8))
    let midpoint = max(1, logicalRequest.body.count / 2)
    for chunk in [logicalRequest.body.prefix(midpoint), logicalRequest.body.dropFirst(midpoint)]
    where !chunk.isEmpty {
      raw.append(Data("\(String(chunk.count, radix: 16))\r\n".utf8))
      raw.append(chunk)
      raw.append(Data("\r\n".utf8))
    }
    raw.append(Data("0\r\n\r\n".utf8))

    let response = try sendRawHTTP11Request(raw, to: endpoint)
    let delimiter = Data("\r\n\r\n".utf8)
    let headerEnd = try XCTUnwrap(response.range(of: delimiter))
    let head = String(decoding: response[..<headerEnd.lowerBound], as: UTF8.self)
    XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)
    let body = Data(response[headerEnd.upperBound...])
    guard case .result(let result) = try MCPWireMessage.decode(body) else {
      return XCTFail("expected tools/list result")
    }
    XCTAssertEqual(try MCPListToolsResult(json: .object(result.value)).resultType, .complete)

    await httpServer.shutdown()
  }

  func testRealLoopbackAtomicallyRejectsConnectionsAboveConfiguredCap() async throws {
    let (server, _, _) = try makeServer()
    let configuration = try MCPHTTPConfiguration(
      socketTimeout: 5,
      maximumConcurrentConnections: 1
    )
    let httpServer = MCPHTTPServer(server: server, configuration: configuration)
    let endpoint = try httpServer.start()
    let port = try XCTUnwrap(endpoint.port)

    let first = try connectLoopback(port: port)
    do {
      // Keep the first registered connection blocked in recv. The dedicated accept queue must
      // still accept the next socket and reject it because registration is already at capacity.
      try sendAll(Data("POST /mcp HTTP/1.1\r\n".utf8), to: first)
      try await Task.sleep(for: .milliseconds(100))

      let second = try connectLoopback(port: port)
      let rejected = peerClosesConnection(second)
      _ = shutdown(second, Int32(SHUT_RDWR))
      _ = close(second)
      XCTAssertTrue(rejected, "the connection above the configured cap must be closed")
    } catch {
      _ = shutdown(first, Int32(SHUT_RDWR))
      _ = close(first)
      await httpServer.shutdown()
      throw error
    }

    _ = shutdown(first, Int32(SHUT_RDWR))
    _ = close(first)
    await httpServer.shutdown()
  }

  func testRequestReadTimeoutClosesAConnectionWithPartialHeaders() async throws {
    let (server, _, _) = try makeServer()
    let configuration = try MCPHTTPConfiguration(
      requestReadTimeout: 0.1,
      socketTimeout: 5,
      maximumConcurrentConnections: 1
    )
    let httpServer = MCPHTTPServer(server: server, configuration: configuration)
    let endpoint = try httpServer.start()
    let descriptor = try connectLoopback(port: try XCTUnwrap(endpoint.port))
    defer {
      _ = shutdown(descriptor, Int32(SHUT_RDWR))
      _ = close(descriptor)
      Task { await httpServer.shutdown() }
    }

    try sendAll(Data("POST /mcp HTTP/1.1\r\n".utf8), to: descriptor)
    var timeout = timeval()
    timeout.tv_sec = 1
    var timeoutCopy = timeout
    XCTAssertEqual(
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeoutCopy,
        socklen_t(MemoryLayout<timeval>.size)
      ),
      0
    )

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = recv(descriptor, &buffer, buffer.count, 0)
      if count == 0 { break }
      if count < 0, errno == EINTR { continue }
      XCTAssertGreaterThan(count, 0)
      if count <= 0 { break }
      response.append(contentsOf: buffer.prefix(count))
    }
    XCTAssertTrue(
      String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 400"),
      "timed-out partial requests should receive a bounded error before close"
    )
  }

  func testShutdownAwaitsInFlightConnectionBeforeAllowingRestart() async throws {
    let gate = HTTPManualGate()
    let tool = try annotatedTool(name: "restart-tool")
    var builder = try MCPServerBuilder(implementation: implementation("restart-server"))
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      await gate.enterAndWait()
      return MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { params, _ in
      try MCPCallToolResult(content: [.text(MCPTextContent(text: params.name))])
    }
    let server = try builder.build()
    let httpServer = MCPHTTPServer(
      server: server,
      configuration: try MCPHTTPConfiguration(socketTimeout: 5)
    )
    let endpoint = try httpServer.start()
    let descriptor = try server.registry.require("tools/list")
    let logicalRequest = try request(
      method: descriptor,
      params: MCPListToolsParams().json.objectValue ?? [:]
    )
    var firstRequest = URLRequest(url: endpoint)
    firstRequest.httpMethod = logicalRequest.method
    firstRequest.httpBody = logicalRequest.body
    for (name, value) in logicalRequest.headers.values {
      firstRequest.setValue(value, forHTTPHeaderField: name)
    }

    let initialRequest = firstRequest
    let responseTask = Task { try await URLSession.shared.data(for: initialRequest) }
    await gate.waitUntilEntered()
    let shutdownFinished = HTTPValueCapture<Bool>()
    let shutdownTask = Task {
      await httpServer.shutdown()
      await shutdownFinished.append(true)
    }
    try await Task.sleep(for: .milliseconds(50))

    let shutdownBeforeRelease = await shutdownFinished.snapshot()
    XCTAssertTrue(shutdownBeforeRelease.isEmpty)
    XCTAssertThrowsError(try httpServer.start()) { error in
      XCTAssertEqual(error as? MCPHTTPServerError, .alreadyRunning)
    }

    await gate.release()
    await shutdownTask.value
    _ = try? await responseTask.value
    let shutdownAfterRelease = await shutdownFinished.snapshot()
    XCTAssertEqual(shutdownAfterRelease, [true])

    let restartedEndpoint = try httpServer.start()
    var restartedRequest = URLRequest(url: restartedEndpoint)
    restartedRequest.httpMethod = logicalRequest.method
    restartedRequest.httpBody = logicalRequest.body
    for (name, value) in logicalRequest.headers.values {
      restartedRequest.setValue(value, forHTTPHeaderField: name)
    }
    do {
      let (_, response) = try await URLSession.shared.data(for: restartedRequest)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    } catch {
      await httpServer.shutdown()
      throw error
    }
    await httpServer.shutdown()
  }

  func testRealLoopbackMapsAllOversizedBodyFramingTo413() async throws {
    let (server, _, _) = try makeServer()
    let configuration = try MCPHTTPConfiguration(maximumBodyBytes: 4, socketTimeout: 5)
    let httpServer = MCPHTTPServer(server: server, configuration: configuration)
    let endpoint = try httpServer.start()
    defer { Task { await httpServer.shutdown() } }
    let host = "127.0.0.1:\(try XCTUnwrap(endpoint.port))"

    let requests = [
      Data(
        "POST /mcp HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: 5\r\nConnection: close\r\n\r\n12345"
          .utf8),
      Data(
        "POST /mcp HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\n12345\r\n0\r\n\r\n"
          .utf8),
    ]

    for rawRequest in requests {
      let response = try sendRawHTTP11Request(rawRequest, to: endpoint)
      let delimiter = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
      let head = String(decoding: response[..<delimiter.lowerBound], as: UTF8.self)
      let body = String(decoding: response[delimiter.upperBound...], as: UTF8.self)
      XCTAssertTrue(head.hasPrefix("HTTP/1.1 413 Payload Too Large"), head)
      XCTAssertEqual(body, "Payload Too Large")
    }

    await httpServer.shutdown()
  }

  func testClientRejectsSingleChunkResponseOverByteLimit() async throws {
    let (server, _, configuration) = try makeServer()
    let httpServer = MCPHTTPServer(server: server, configuration: configuration)
    let endpoint = try httpServer.start()
    defer { Task { await httpServer.shutdown() } }

    let transport = MCPHTTPClientTransport(
      configuration: try MCPHTTPClientConfiguration(
        endpoint: endpoint,
        maximumResponseBytes: 1,
        networkTimeout: 5
      )
    )
    let client = try MCPClient(
      transport: transport,
      configuration: MCPClientConfiguration(
        implementation: implementation("bounded-client"),
        capabilities: MCPClientCapabilities(),
        requestTimeout: .seconds(5)
      )
    )

    do {
      _ = try await client.discover()
      XCTFail("expected HTTP response byte limit failure")
    } catch let error as MCPClientError {
      guard case .transport(let detail) = error else {
        return XCTFail("unexpected client error: \(error)")
      }
      XCTAssertTrue(detail.contains("exceeds 1 bytes"), detail)
    }

    await httpServer.shutdown()
  }

  func testRealLoopbackJSONSSESubscriptionAndMethodRejection() async throws {
    let contexts = HTTPValueCapture<MCPRequestContext>()
    let verifier = try MCPHTTPStaticBearerVerifier(
      token: "secret",
      context: MCPAuthorizationContext(subject: "alice", cachePartition: "alice")
    )
    let (server, tool, configuration) = try makeServer(authorization: verifier, contexts: contexts)
    let httpServer = MCPHTTPServer(server: server, configuration: configuration)
    let endpoint = try httpServer.start()

    do {
      let transport = MCPHTTPClientTransport(
        configuration: try MCPHTTPClientConfiguration(
          endpoint: endpoint,
          authorizationProvider: MCPStaticBearerTokenProvider(token: "secret"),
          networkTimeout: 5
        )
      )
      let client = try MCPClient(
        transport: transport,
        configuration: MCPClientConfiguration(
          implementation: implementation("loopback-client"),
          capabilities: MCPClientCapabilities(),
          requestTimeout: .seconds(5)
        )
      )

      let discovery = try await client.discover()
      XCTAssertTrue(discovery.capabilities.tools)
      let listedTools = try await client.listTools()
      XCTAssertEqual(listedTools.tools.map(\.name), [tool.name])
      XCTAssertTrue(transport.toolCatalog.rejectedTools.isEmpty)

      let progress = HTTPValueCapture<Double>()
      let result = try await client.callTool(
        try MCPCallToolParams(
          name: tool.name,
          arguments: [
            "region": .string("서울"),
            "count": .number(try MCPJSONNumber(rawValue: "7.0")),
            "nested": .object(["enabled": .bool(true)]),
          ]
        ),
        progress: { update in
          if let value = update.progress.doubleValue { await progress.append(value) }
        }
      )
      XCTAssertEqual(result.resultType, .complete)
      let progressValues = await progress.snapshot()
      XCTAssertEqual(progressValues, [0.5, 1])

      let subscription = try await client.listen(
        notifications: MCPSubscriptionFilter(toolsListChanged: true)
      )
      let collector = Task { () throws -> [MCPClientSubscriptionEvent] in
        var values: [MCPClientSubscriptionEvent] = []
        for try await value in subscription.events { values.append(value) }
        return values
      }
      try await Task.sleep(for: .milliseconds(30))
      try await server.notifyToolsChanged()
      await server.closeAllSubscriptions()
      let events = try await collector.value
      XCTAssertEqual(events.count, 3)

      for method in ["GET", "DELETE"] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 405)
      }

      let captured = await contexts.snapshot()
      XCTAssertTrue(captured.allSatisfy { $0.authorization.subject == "alice" })
    } catch {
      await httpServer.shutdown()
      throw error
    }
    await httpServer.shutdown()
    XCTAssertNil(httpServer.boundEndpoint)
  }

  func testIndependentHTTPSubscriptionsMayReuseClientScopedRequestID() async throws {
    let (server, _, configuration) = try makeServer()
    let httpServer = MCPHTTPServer(server: server, configuration: configuration)
    let endpoint = try httpServer.start()

    func makeClient(named name: String) throws -> MCPClient {
      try MCPClient(
        transport: MCPHTTPClientTransport(
          configuration: try MCPHTTPClientConfiguration(endpoint: endpoint, networkTimeout: 5)
        ),
        configuration: MCPClientConfiguration(
          implementation: try implementation(name),
          capabilities: MCPClientCapabilities(),
          requestTimeout: .seconds(5)
        ),
        startingRequestID: 1
      )
    }

    do {
      let requested = try MCPSubscriptionFilter(toolsListChanged: true)
      let first = try await makeClient(named: "subscription-client-a").listen(
        notifications: requested)
      let second = try await makeClient(named: "subscription-client-b").listen(
        notifications: requested)
      XCTAssertEqual(first.id, MCPRequestID(1))
      XCTAssertEqual(second.id, MCPRequestID(1))

      let firstCollector = Task { () throws -> [MCPClientSubscriptionEvent] in
        var events: [MCPClientSubscriptionEvent] = []
        for try await event in first.events { events.append(event) }
        return events
      }
      let secondCollector = Task { () throws -> [MCPClientSubscriptionEvent] in
        var events: [MCPClientSubscriptionEvent] = []
        for try await event in second.events { events.append(event) }
        return events
      }

      try await server.notifyToolsChanged()
      await server.closeAllSubscriptions()
      let firstEvents = try await firstCollector.value
      let secondEvents = try await secondCollector.value
      let eventSets = [firstEvents, secondEvents]
      for events in eventSets {
        guard events.count == 3,
          case .acknowledged(let accepted) = events[0],
          case .notification(let notification) = events[1],
          case .completed(let completion) = events[2]
        else {
          return XCTFail("each independent HTTP subscription must acknowledge, receive, and close")
        }
        XCTAssertEqual(accepted, requested)
        XCTAssertEqual(notification.method, "notifications/tools/list_changed")
        let metadata = try MCPNotificationMetadata(
          json: notification.params["_meta"] ?? .null)
        XCTAssertEqual(metadata.subscriptionID, MCPRequestID(1))
        XCTAssertEqual(completion.subscriptionID, MCPRequestID(1))
      }
    } catch {
      await httpServer.shutdown()
      throw error
    }
    await httpServer.shutdown()
  }

  func testLongLivedSSEKeepAliveSurvivesQuietPeriodsAndUsesPerEventBounds() async throws {
    let (server, _, _) = try makeServer()
    let configuration = try MCPHTTPConfiguration(
      sseKeepAliveInterval: 0.02,
      socketTimeout: 5
    )
    let httpServer = MCPHTTPServer(server: server, configuration: configuration)
    let endpoint = try httpServer.start()

    do {
      let client = try MCPClient(
        transport: MCPHTTPClientTransport(
          configuration: try MCPHTTPClientConfiguration(
            endpoint: endpoint,
            maximumResponseBytes: 1,
            maximumEventBytes: 4_096,
            networkTimeout: 0.1
          )
        ),
        configuration: MCPClientConfiguration(
          implementation: implementation("long-lived-sse-client"),
          capabilities: MCPClientCapabilities(),
          requestTimeout: .seconds(2)
        )
      )
      let subscription = try await client.listen(
        notifications: MCPSubscriptionFilter(toolsListChanged: true)
      )
      let collector = Task { () throws -> [MCPClientSubscriptionEvent] in
        var events: [MCPClientSubscriptionEvent] = []
        for try await event in subscription.events { events.append(event) }
        return events
      }
      // This exceeds the client's request idle timeout. SSE comments must keep the subscription
      // alive without surfacing phantom protocol events to the decoder.
      try await Task.sleep(for: .milliseconds(200))
      for _ in 0..<5 {
        try await Task.sleep(for: .milliseconds(40))
        try await server.notifyToolsChanged()
      }
      await server.closeAllSubscriptions()
      let events = try await collector.value
      XCTAssertEqual(events.count, 7)
    } catch {
      await httpServer.shutdown()
      throw error
    }
    await httpServer.shutdown()
  }

  func testCancellingHTTPExchangeStreamReleasesTheUnderlyingConnection() async throws {
    let (server, _, _) = try makeServer()
    let httpServer = MCPHTTPServer(
      server: server,
      configuration: try MCPHTTPConfiguration(
        sseKeepAliveInterval: 0.02,
        socketTimeout: 5,
        maximumConcurrentConnections: 1
      )
    )
    let endpoint = try httpServer.start()
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("exchange-lifecycle-client")
    )
    let listen = try MCPSubscriptionsListenParams(
      notifications: MCPSubscriptionFilter(toolsListChanged: true)
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(1),
      method: "subscriptions/listen",
      params: metadata.inserting(into: listen.json.objectValue ?? [:])
    )
    let transport = MCPHTTPClientTransport(
      configuration: try MCPHTTPClientConfiguration(endpoint: endpoint, networkTimeout: 5)
    )
    let exchange = try await transport.open(request)
    let gate = HTTPManualGate()
    let consumer = Task { () -> Bool in
      do {
        var iterator = exchange.frames.makeAsyncIterator()
        guard case .notification? = try await iterator.next() else { return false }
        await gate.enterAndWait()
        while try await iterator.next() != nil {}
        return true
      } catch {
        return false
      }
    }
    await gate.waitUntilEntered()
    consumer.cancel()
    await gate.release()
    try await Task.sleep(for: .milliseconds(250))

    do {
      let client = try MCPClient(
        transport: MCPHTTPClientTransport(
          configuration: try MCPHTTPClientConfiguration(endpoint: endpoint, networkTimeout: 2)
        ),
        configuration: MCPClientConfiguration(
          implementation: implementation("exchange-lifecycle-follow-up"),
          capabilities: MCPClientCapabilities(),
          requestTimeout: .seconds(2)
        )
      )
      let result = try await client.listTools()
      XCTAssertEqual(result.tools.map(\.name), ["echo"])
    } catch {
      try? await exchange.cancel(reason: "test cleanup")
      consumer.cancel()
      _ = await consumer.value
      await httpServer.shutdown()
      throw error
    }

    try? await exchange.cancel(reason: "test cleanup")
    consumer.cancel()
    _ = await consumer.value
    await httpServer.shutdown()
  }

  func testShutdownEndsAnOpenSubscriptionInsteadOfDrainingItForever() async throws {
    // `shutdown()` drains in-flight requests, so a subscription — whose handler only returns when
    // the stream ends — would hold it open indefinitely unless shutdown cancels the response
    // stream. Without that cancellation this test hangs rather than fails.
    let (server, _, _) = try makeServer()
    let httpServer = MCPHTTPServer(
      server: server,
      configuration: try MCPHTTPConfiguration(sseKeepAliveInterval: 0.02, socketTimeout: 5)
    )
    let endpoint = try httpServer.start()
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("shutdown-subscription-client")
    )
    let listen = try MCPSubscriptionsListenParams(
      notifications: MCPSubscriptionFilter(toolsListChanged: true)
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(1),
      method: "subscriptions/listen",
      params: metadata.inserting(into: listen.json.objectValue ?? [:])
    )
    let transport = MCPHTTPClientTransport(
      configuration: try MCPHTTPClientConfiguration(endpoint: endpoint, networkTimeout: 5)
    )
    let exchange = try await transport.open(request)
    var iterator = exchange.frames.makeAsyncIterator()
    // The acknowledgement proves the subscription is live and the connection is draining.
    guard case .notification? = try await iterator.next() else {
      return XCTFail("subscription was not acknowledged")
    }

    await httpServer.shutdown()

    XCTAssertNil(httpServer.boundEndpoint)
    try? await exchange.cancel(reason: "test cleanup")
  }

  func testHTTPServerCancellationInterruptsSubscriptionStream() async throws {
    let (server, _, configuration) = try makeServer()
    let httpServer = MCPHTTPServer(server: server, configuration: configuration)
    let endpoint = try httpServer.start()

    do {
      let transport = MCPHTTPClientTransport(
        configuration: try MCPHTTPClientConfiguration(
          endpoint: endpoint,
          networkTimeout: 5
        )
      )
      let client = try MCPClient(
        transport: transport,
        configuration: MCPClientConfiguration(
          implementation: implementation("http-cancellation-client"),
          capabilities: MCPClientCapabilities(),
          requestTimeout: .seconds(5)
        )
      )

      let subscription = try await client.listen(
        notifications: MCPSubscriptionFilter(toolsListChanged: true)
      )
      var iterator = subscription.events.makeAsyncIterator()
      guard case .acknowledged? = try await iterator.next() else {
        await httpServer.shutdown()
        return XCTFail("HTTP subscription did not acknowledge")
      }

      // A server tearing down a subscription stream must send notifications/cancelled referencing
      // the subscriptions/listen request. Closing the SSE stream alone is the *client's*
      // cancellation signal and is indistinguishable from an abrupt disconnect, so the client must
      // observe an explicit peer cancellation here rather than a truncated-stream transport error.
      await server.cancelAllSubscriptions(reason: "maintenance")
      do {
        _ = try await iterator.next()
        XCTFail("server cancellation must interrupt the HTTP subscription")
      } catch let error as MCPClientError {
        guard case .peerCancelled(let reason) = error else {
          await httpServer.shutdown()
          return XCTFail("unexpected client error: \(error)")
        }
        XCTAssertEqual(reason, "maintenance")
      }
    } catch {
      await httpServer.shutdown()
      throw error
    }

    await httpServer.shutdown()
  }

  /// A peer that vanishes mid-response is ordinary client behavior. The write must fail as an
  /// errno on that one connection; it must never reach the process as a signal, because the
  /// default `SIGPIPE` disposition would take down every other in-flight request with it.
  func testAbortedSSEConnectionDoesNotTerminateTheServerProcess() async throws {
    let (server, _, configuration) = try makeServer()
    let httpServer = MCPHTTPServer(server: server, configuration: configuration)
    let endpoint = try httpServer.start()
    defer { Task { await httpServer.shutdown() } }
    let port = try XCTUnwrap(endpoint.port)

    let listen = try request(
      method: try server.registry.require("subscriptions/listen"),
      params: MCPSubscriptionsListenParams(
        notifications: MCPSubscriptionFilter(toolsListChanged: true)
      ).json.objectValue ?? [:],
      host: "127.0.0.1:\(port)"
    )
    var raw = Data("POST /mcp HTTP/1.1\r\n".utf8)
    var headers = listen.headers.values
    headers["content-length"] = String(listen.body.count)
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      raw.append(Data("\(name): \(value)\r\n".utf8))
    }
    raw.append(Data("\r\n".utf8))
    raw.append(listen.body)

    let descriptor = try connectLoopback(port: port)
    var closed = false
    defer { if !closed { _ = close(descriptor) } }
    try sendAll(raw, to: descriptor)

    // The acknowledgement proves the response stream is open and actively being written to.
    var acknowledgement = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    let started = Date()
    while !acknowledgement.contains(Data("subscriptions/acknowledged".utf8)),
      Date().timeIntervalSince(started) < 5
    {
      let count = recv(descriptor, &buffer, buffer.count, 0)
      if count > 0 {
        acknowledgement.append(contentsOf: buffer.prefix(count))
        continue
      }
      if count < 0, errno == EINTR { continue }
      break
    }
    XCTAssertTrue(
      acknowledgement.contains(Data("subscriptions/acknowledged".utf8)),
      "subscription did not start streaming"
    )

    // Discard the socket with a reset so the next server write cannot be absorbed by any buffer.
    var linger = linger(l_onoff: 1, l_linger: 0)
    XCTAssertEqual(
      setsockopt(
        descriptor, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size)),
      0
    )
    closed = true
    _ = close(descriptor)

    for _ in 0..<8 {
      try await Task.sleep(for: .milliseconds(20))
      try await server.notifyToolsChanged()
    }
    try await Task.sleep(for: .milliseconds(100))

    // Reaching this point at all means no signal was raised. The server must still be serving.
    let survivor = try request(
      method: try server.registry.require("tools/list"),
      params: MCPListToolsParams().json.objectValue ?? [:],
      host: "127.0.0.1:\(port)"
    )
    var follow = Data("POST /mcp HTTP/1.1\r\n".utf8)
    var followHeaders = survivor.headers.values
    followHeaders["content-length"] = String(survivor.body.count)
    followHeaders["connection"] = "close"
    for (name, value) in followHeaders.sorted(by: { $0.key < $1.key }) {
      follow.append(Data("\(name): \(value)\r\n".utf8))
    }
    follow.append(Data("\r\n".utf8))
    follow.append(survivor.body)

    let response = try sendRawHTTP11Request(follow, to: endpoint)
    let headerEnd = response.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? response.endIndex
    let head = String(decoding: response[..<headerEnd], as: UTF8.self)
    XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)

    await httpServer.shutdown()
  }

  func testClientRejectsRedirectWithoutForwardingAuthorization() async throws {
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("redirect-client")
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(1),
      method: "server/discover",
      params: metadata.inserting(into: [:])
    )
    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream()
    let delegate = try MCPHTTPExchangeDelegate(
      request: request,
      catalog: MCPHTTPToolCatalog(),
      jsonLimits: .default,
      maximumResponseBytes: 1_024,
      maximumEventBytes: 1_024,
      continuation: pair.continuation
    )
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    delegate.install(session: session)
    let originalURL = try XCTUnwrap(URL(string: "http://127.0.0.1/original"))
    let redirectedURL = try XCTUnwrap(URL(string: "http://127.0.0.1/redirected"))
    let task = session.dataTask(with: originalURL)
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: originalURL,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": redirectedURL.absoluteString]
      )
    )
    let capture = HTTPRedirectCompletionCapture()

    delegate.urlSession(
      session,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: redirectedURL),
      completionHandler: { capture.record($0) }
    )

    XCTAssertNil(capture.followedRequest)
    do {
      for try await _ in pair.stream {}
      XCTFail("expected redirect rejection")
    } catch let error as MCPHTTPError {
      XCTAssertEqual(error, .redirectRejected(redirectedURL.absoluteString))
    }
  }

  func testRemoteBindingRequiresExplicitAuthorizationVerifier() throws {
    XCTAssertThrowsError(try MCPHTTPConfiguration(bindAddress: "0.0.0.0")) { error in
      guard case MCPHTTPServerError.invalidConfiguration(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("authorization verifier"))
    }

    XCTAssertNoThrow(
      try MCPHTTPConfiguration(
        bindAddress: "0.0.0.0",
        authorizationVerifier: MCPHTTPStaticBearerVerifier(
          token: "secret",
          context: MCPAuthorizationContext(subject: "test")
        )
      )
    )
  }

}
