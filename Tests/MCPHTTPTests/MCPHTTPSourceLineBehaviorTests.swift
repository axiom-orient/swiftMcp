@preconcurrency import Foundation
import XCTest

@testable import MCP
@testable import MCPHTTPClient
@testable import MCPHTTPServer
@testable import MCPHTTPShared

#if canImport(FoundationNetworking)
  @preconcurrency import FoundationNetworking
#endif

final class MCPHTTPSourceLineBehaviorTests: XCTestCase {
  private let endpoint = URL(string: "http://127.0.0.1:9000/mcp")!

  private func request(id: Int64 = 1) throws -> MCPWireRequest {
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: MCPImplementation(name: "http-source-client", version: "1.0.0")
    )
    return try MCPWireRequest(
      id: MCPRequestID(id),
      method: "server/discover",
      params: metadata.inserting(into: [:])
    )
  }

  private func exchange(request: MCPWireRequest) throws -> (
    delegate: MCPHTTPExchangeDelegate,
    frames: AsyncThrowingStream<MCPWireMessage, Error>,
    task: URLSessionDataTask
  ) {
    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream()
    let delegate = try MCPHTTPExchangeDelegate(
      request: request,
      catalog: MCPHTTPToolCatalog(),
      jsonLimits: .default,
      maximumResponseBytes: 1_024,
      maximumEventBytes: 1_024,
      continuation: pair.continuation
    )
    return (
      delegate,
      pair.stream,
      URLSession.shared.dataTask(with: endpoint)
    )
  }

  private func response(
    status: Int,
    headers: [String: String] = [:]
  ) throws -> HTTPURLResponse {
    try XCTUnwrap(
      HTTPURLResponse(
        url: endpoint,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )
    )
  }

  private func receive(
    _ exchange: (
      delegate: MCPHTTPExchangeDelegate,
      frames: AsyncThrowingStream<MCPWireMessage, Error>,
      task: URLSessionDataTask
    ),
    response: HTTPURLResponse,
    body: Data = Data()
  ) {
    exchange.delegate.urlSession(
      URLSession.shared,
      dataTask: exchange.task,
      didReceive: response,
      completionHandler: { _ in }
    )
    if !body.isEmpty {
      exchange.delegate.urlSession(URLSession.shared, dataTask: exchange.task, didReceive: body)
    }
    exchange.delegate.urlSession(URLSession.shared, task: exchange.task, didCompleteWithError: nil)
  }

  private func annotatedTool(name: String, header: String) throws -> MCPTool {
    try MCPTool(
      name: name,
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "tenant": .object([
            "type": .string("string"),
            "x-mcp-header": .string(header),
          ])
        ]),
      ]
    )
  }

  func testClientRejectsSuccessfulResponseWithUnsupportedContentType() async throws {
    let request = try request()
    let exchange = try exchange(request: request)
    receive(
      exchange,
      response: try response(status: 200, headers: ["Content-Type": "text/plain"])
    )

    var iterator = exchange.frames.makeAsyncIterator()
    do {
      _ = try await iterator.next()
      XCTFail("successful HTTP responses must be JSON or request-scoped SSE")
    } catch let error as MCPHTTPError {
      XCTAssertEqual(error, .unsupportedContentType("text/plain"))
    }
  }

  func testClientPreservesJSONRPCFailuresButReportsNonProtocolHTTPFailures() async throws {
    let request = try request(id: 7)
    let protocolExchange = try exchange(request: request)
    let protocolError = MCPWireMessage.error(
      MCPWireErrorResponse(id: MCPRequestID(7), error: .methodNotFound)
    )
    receive(
      protocolExchange,
      response: try response(status: 404, headers: ["Content-Type": "application/json"]),
      body: try protocolError.encoded()
    )

    var protocolIterator = protocolExchange.frames.makeAsyncIterator()
    guard case .error(let receivedError)? = try await protocolIterator.next() else {
      return XCTFail("a JSON-RPC error response must remain available to the MCP client")
    }
    XCTAssertEqual(receivedError.id, MCPRequestID(7))
    XCTAssertEqual(receivedError.error, .methodNotFound)
    let protocolEnd = try await protocolIterator.next()
    XCTAssertNil(protocolEnd)

    let nonProtocolExchange = try exchange(request: request)
    receive(
      nonProtocolExchange,
      response: try response(
        status: 401,
        headers: ["WWW-Authenticate": "Bearer resource_metadata=\"https://auth.example/meta\""]
      ),
      body: Data("access denied".utf8)
    )

    var nonProtocolIterator = nonProtocolExchange.frames.makeAsyncIterator()
    do {
      _ = try await nonProtocolIterator.next()
      XCTFail("a non-JSON-RPC HTTP error must not become a terminal MCP frame")
    } catch let error as MCPHTTPUnauthorizedResponse {
      XCTAssertEqual(
        error,
        MCPHTTPUnauthorizedResponse(
          wwwAuthenticate: "Bearer resource_metadata=\"https://auth.example/meta\"",
          body: "access denied"
        )
      )
    }
  }

  func testClientRejectsTruncatedSSEAndConnectionsClosedBeforeHeaders() async throws {
    let request = try request()
    let truncatedExchange = try exchange(request: request)
    receive(
      truncatedExchange,
      response: try response(status: 200, headers: ["Content-Type": "text/event-stream"]),
      body: Data("data: {\"jsonrpc\":\"2.0\"}\n".utf8)
    )

    var truncatedIterator = truncatedExchange.frames.makeAsyncIterator()
    do {
      _ = try await truncatedIterator.next()
      XCTFail("an SSE event without its terminating blank line must be rejected")
    } catch let error as MCPHTTPError {
      XCTAssertEqual(error, .malformedSSE("stream ended before an event delimiter"))
    }

    let unopenedExchange = try exchange(request: request)
    unopenedExchange.delegate.urlSession(
      URLSession.shared,
      task: unopenedExchange.task,
      didCompleteWithError: nil
    )
    var unopenedIterator = unopenedExchange.frames.makeAsyncIterator()
    do {
      _ = try await unopenedIterator.next()
      XCTFail("a connection ending before HTTP response headers must fail the exchange")
    } catch let error as MCPHTTPError {
      XCTAssertEqual(error, .connectionClosed)
    }
  }

  func testPaginatedToolListsRetainEarlierHeaderSchemasForLaterToolCalls() async throws {
    let toolA = try annotatedTool(name: "first", header: "First-Tenant")
    let toolB = try annotatedTool(name: "second", header: "Second-Tenant")
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "pagination-server", version: "1.0.0")
    )
    builder.setToolResolver { name, _ in
      switch name {
      case toolA.name: toolA
      case toolB.name: toolB
      default: nil
      }
    }
    try builder.register(MCPStandardMethods.listTools) { params, _ in
      switch params.cursor {
      case nil: MCPListToolsResult(tools: [toolA], nextCursor: "cursor-2")
      case "cursor-2": MCPListToolsResult(tools: [toolB])
      default: throw MCPRPCError.invalidParams
      }
    }
    try builder.register(MCPStandardMethods.callTool) { params, _ in
      try MCPCallToolResult(content: [.text(MCPTextContent(text: params.name))])
    }
    let server = try builder.build()
    let httpServer = MCPHTTPServer(
      server: server,
      configuration: try MCPHTTPConfiguration(socketTimeout: 2)
    )
    let endpoint = try httpServer.start()

    do {
      let transport = MCPHTTPClientTransport(
        configuration: try MCPHTTPClientConfiguration(endpoint: endpoint, networkTimeout: 2)
      )
      let client = try MCPClient(
        transport: transport,
        configuration: MCPClientConfiguration(
          implementation: MCPImplementation(name: "pagination-client", version: "1.0.0"),
          capabilities: MCPClientCapabilities(),
          requestTimeout: .seconds(2)
        )
      )

      _ = try await client.discover()
      let firstPage = try await client.listTools()
      XCTAssertEqual(firstPage.tools.map(\.name), [toolA.name])
      XCTAssertEqual(firstPage.nextCursor, "cursor-2")
      let secondPage = try await client.listTools(cursor: firstPage.nextCursor)
      XCTAssertEqual(secondPage.tools.map(\.name), [toolB.name])
      XCTAssertNil(secondPage.nextCursor)

      let result = try await client.callTool(
        try MCPCallToolParams(
          name: toolA.name,
          arguments: ["tenant": .string("alpha")]
        )
      )
      XCTAssertEqual(result.resultType, .complete)
    } catch {
      await httpServer.shutdown()
      throw error
    }
    await httpServer.shutdown()
  }

  func testDirectToolCallWithoutListingIsRejectedWhenToolHeadersAreRequired() async throws {
    let tool = try annotatedTool(name: "direct", header: "Tenant")
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "direct-http-server", version: "1.0.0")
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: [tool]) }
    try builder.register(MCPStandardMethods.callTool) { _, _ in try MCPCallToolResult(content: []) }
    let httpServer = MCPHTTPServer(
      server: try builder.build(),
      configuration: try MCPHTTPConfiguration(socketTimeout: 2)
    )
    let endpoint = try httpServer.start()

    do {
      let client = try MCPClient(
        transport: MCPHTTPClientTransport(
          configuration: try MCPHTTPClientConfiguration(endpoint: endpoint, networkTimeout: 2)
        ),
        configuration: MCPClientConfiguration(
          implementation: MCPImplementation(name: "direct-http-client", version: "1.0.0"),
          capabilities: MCPClientCapabilities(),
          requestTimeout: .seconds(2)
        )
      )

      do {
        _ = try await client.callTool(
          MCPCallToolParams(name: tool.name, arguments: ["tenant": .string("alpha")])
        )
        XCTFail("expected the server to require the declared Mcp-Param header")
      } catch let error as MCPClientError {
        guard case .rpc(let rpc) = error else { throw error }
        XCTAssertEqual(rpc.code, -32020)
      }
    } catch {
      await httpServer.shutdown()
      throw error
    }
    await httpServer.shutdown()
  }
}
