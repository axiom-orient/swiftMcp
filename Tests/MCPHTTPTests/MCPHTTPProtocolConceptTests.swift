@preconcurrency import Foundation
import XCTest

@testable import MCP
@testable import MCPHTTPServer
@testable import MCPHTTPShared

final class MCPHTTPProtocolConceptTests: XCTestCase {
  private func discoverRequest(
    contentType: String = "application/json",
    accept: String
  ) throws -> MCPHTTPRequest {
    let implementation = try MCPImplementation(name: "http-concept-client", version: "1.0.0")
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation
    )
    let wire = try MCPWireRequest(
      id: MCPRequestID(1),
      method: "server/discover",
      params: metadata.inserting(into: [:])
    )
    return MCPHTTPRequest(
      method: "POST",
      target: "/mcp",
      headers: MCPHTTPHeaders([
        "host": "127.0.0.1",
        "content-type": contentType,
        "accept": accept,
        MCPHTTPHeaderName.protocolVersion: MCPProtocolVersion.current.rawValue,
        MCPHTTPHeaderName.method: wire.method,
      ]),
      body: try MCPWireMessage.request(wire).encoded()
    )
  }

  private func rawRequest(
    method: String,
    params: [String: MCPJSONValue],
    headerVersion: String = MCPProtocolVersion.current.rawValue,
    headerMethod: String? = nil
  ) throws -> MCPHTTPRequest {
    let wire = try MCPWireRequest(id: MCPRequestID(9), method: method, params: params)
    return MCPHTTPRequest(
      method: "POST",
      target: "/mcp",
      headers: MCPHTTPHeaders([
        "host": "127.0.0.1",
        "content-type": "application/json",
        "accept": "application/json, text/event-stream",
        MCPHTTPHeaderName.protocolVersion: headerVersion,
        MCPHTTPHeaderName.method: headerMethod ?? method,
      ]),
      body: try MCPWireMessage.request(wire).encoded()
    )
  }

  private func errorResponse(in response: MCPHTTPResponse) throws -> MCPWireErrorResponse {
    guard case .bytes(let body) = response.body,
      case .error(let error) = try MCPWireMessage.decode(body)
    else {
      throw MCPHTTPError.io("expected a JSON-RPC error response")
    }
    return error
  }

  private func handler() throws -> MCPHTTPServerHandler {
    let server = try MCPServerBuilder(
      implementation: MCPImplementation(name: "http-concept-server", version: "1.0.0")
    ).build()
    return MCPHTTPServerHandler(
      server: server,
      configuration: try MCPHTTPConfiguration(
        publicEndpoint: URL(string: "http://127.0.0.1/mcp")!
      )
    )
  }

  func testPostContentNegotiationRejectsExplicitlyUnacceptableRequiredMediaType() async throws {
    let handler = try handler()

    let accepted = await handler.handle(
      try discoverRequest(
        contentType: "Application/JSON; charset=utf-8",
        accept: "application/json; q=1, text/event-stream; q=0.5"
      )
    )
    XCTAssertEqual(accepted.status, 200)

    for unacceptableAccept in [
      "application/json, text/event-stream; q=0",
      "application/json, text/event-stream; q=1.1",
      "application/json, text/event-stream; q=Infinity",
      "application/json, text/event-stream; q=.5",
      "application/json, text/event-stream; q=0.1234",
      "application/json, text/event-stream; q=1.001",
      "application/json, text/event-stream; q=1.0000",
    ] {
      let rejected = await handler.handle(
        try discoverRequest(accept: unacceptableAccept)
      )
      XCTAssertEqual(rejected.status, 406, unacceptableAccept)
    }
  }

  func testRawPostAuthorityFailuresHaveTheSpecifiedHTTPAndJSONRPCIdentities() async throws {
    let handler = try handler()
    let implementation = try MCPImplementation(name: "raw-authority-client", version: "1.0.0")
    let capabilities = try MCPClientCapabilities()
    let currentMetadata = try MCPRequestMetadata(
      clientCapabilities: capabilities,
      clientInfo: implementation
    ).inserting(into: [:])
    let unknownVersion = "2099-01-01"
    let unknownMetadata: [String: MCPJSONValue] = [
      "_meta": .object([
        MCPMetaKey.protocolVersion: .string(unknownVersion),
        MCPMetaKey.clientCapabilities: capabilities.json,
        MCPMetaKey.clientInfo: implementation.json,
      ])
    ]

    let missingMetadata = await handler.handle(
      try rawRequest(method: "server/discover", params: [:])
    )
    XCTAssertEqual(missingMetadata.status, 400)
    XCTAssertEqual(try errorResponse(in: missingMetadata).error.code, -32602)

    let unsupported = await handler.handle(
      try rawRequest(
        method: "server/discover",
        params: unknownMetadata,
        headerVersion: unknownVersion
      )
    )
    XCTAssertEqual(unsupported.status, 400)
    let unsupportedError = try errorResponse(in: unsupported).error
    XCTAssertEqual(unsupportedError.code, -32022)
    guard case .object(let unsupportedData)? = unsupportedError.data else {
      return XCTFail("UnsupportedProtocolVersion must identify requested and supported versions")
    }
    XCTAssertEqual(unsupportedData["requested"], .string(unknownVersion))
    XCTAssertEqual(
      unsupportedData["supported"],
      .array([.string(MCPProtocolVersion.current.rawValue)])
    )

    let unknownBodyWithCurrentHeader = await handler.handle(
      try rawRequest(method: "server/discover", params: unknownMetadata)
    )
    XCTAssertEqual(unknownBodyWithCurrentHeader.status, 400)
    XCTAssertEqual(
      try errorResponse(in: unknownBodyWithCurrentHeader).error.code,
      -32020
    )

    let mismatched = await handler.handle(
      try rawRequest(
        method: "server/discover",
        params: currentMetadata,
        headerMethod: "tools/list"
      )
    )
    XCTAssertEqual(mismatched.status, 400)
    XCTAssertEqual(try errorResponse(in: mismatched).error.code, -32020)

    let unknownMethod = await handler.handle(
      try rawRequest(method: "experimental/not-registered", params: currentMetadata)
    )
    XCTAssertEqual(unknownMethod.status, 404)
    XCTAssertEqual(try errorResponse(in: unknownMethod).error.code, -32601)
  }
}
