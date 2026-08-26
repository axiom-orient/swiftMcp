import Foundation
import MCP
import MCPHTTPClient
import MCPStdioClient

/// Cross-implementation conformance fixture.
///
/// The assertion sequence is deliberately transport-agnostic and implementation-tolerant:
/// it exercises the strict stateless surface (discovery, listing, tool call, and a negative
/// unknown-tool path) while leaving room for legitimate peer choices such as reporting an
/// unknown tool as an RPC error or as an `isError` result. It must pass unchanged against
/// this repository's own fixture server and against an external reference SDK server.
@main
enum MCPConformanceClient {
  static func main() async throws {
    let arguments = CommandLine.arguments.dropFirst()
    guard let mode = arguments.first else {
      throw MCPClientError.transport(
        "usage: mcp-conformance-client <server-executable> [args...] | --http <endpoint-url>")
    }
    switch mode {
    case "--http":
      guard let rawEndpoint = arguments.dropFirst().first,
        let endpoint = URL(string: rawEndpoint)
      else {
        throw MCPClientError.transport("usage: mcp-conformance-client --http <endpoint-url>")
      }
      let transport = MCPHTTPClientTransport(
        configuration: try MCPHTTPClientConfiguration(endpoint: endpoint))
      try await run(MCPClient(transport: transport, configuration: configuration()))
    default:
      let transport = MCPStdioClientTransport(
        configuration: try MCPStdioClientConfiguration(
          executableURL: URL(fileURLWithPath: mode),
          arguments: Array(arguments.dropFirst()),
          diagnosticHandler: { line in
            FileHandle.standardError.write(Data("server: \(line)\n".utf8))
          }
        ))
      defer { Task { await transport.shutdown() } }
      try await run(
        MCPClient(transport: transport, configuration: try configuration()))
    }
    print("PASS strict discovery/list/call/unknown-tool")
  }

  private static func configuration() throws -> MCPClientConfiguration {
    try MCPClientConfiguration(
      implementation: try MCPImplementation(name: "mcp-conformance-client", version: "1.0.0"),
      capabilities: MCPClientCapabilities(),
      requestTimeout: .seconds(10)
    )
  }

  private static func run(_ client: MCPClient) async throws {
    // 1. Discovery advertises exactly the strict protocol version.
    let discovery = try await client.discover()
    guard discovery.supportedVersions == [MCPProtocolVersion.current.rawValue] else {
      throw MCPClientError.protocolViolation("strict protocol version was not advertised")
    }

    // 2. Listing exposes either the shared echo fixture or a safe zero-input tool.
    let tools = try await client.listTools()
    let result: MCPCallToolResult
    if tools.tools.contains(where: { $0.name == "echo" }) {
      result = try await client.callTool(
        MCPCallToolParams(name: "echo", arguments: ["text": .string("conformance")]))
      guard result.isError == false, result.resultType == .complete,
        result.content.contains(where: {
          if case .text(let text) = $0 { return text.text == "conformance" }
          return false
        })
      else {
        throw MCPClientError.protocolViolation("echo result did not match")
      }
    } else {
      guard let probe = tools.tools.first(where: isSafeZeroInputTool) else {
        throw MCPClientError.protocolViolation(
          "no echo or explicitly read-only zero-input tool was listed")
      }
      result = try await client.callTool(MCPCallToolParams(name: probe.name))
      guard result.isError == false, result.resultType == .complete else {
        throw MCPClientError.protocolViolation("safe tool probe failed")
      }
    }

    // 4. An unknown tool fails without hanging. Peers legitimately differ between an RPC
    // error and an isError result; conformance only requires one of them.
    do {
      let unknown = try await client.callTool(
        MCPCallToolParams(name: "definitely-not-registered", arguments: [:]))
      guard unknown.isError || unknown.resultType != .complete else {
        throw MCPClientError.protocolViolation("unknown tool unexpectedly succeeded")
      }
    } catch let error as MCPClientError {
      guard case .rpc = error else { throw error }
    }
  }

  private static func isSafeZeroInputTool(_ tool: MCPTool) -> Bool {
    let requiredIsEmpty: Bool
    switch tool.inputSchema["required"] {
    case nil: requiredIsEmpty = true
    case .array(let fields): requiredIsEmpty = fields.isEmpty
    default: requiredIsEmpty = false
    }
    return requiredIsEmpty
      && tool.annotations?["readOnlyHint"] == .bool(true)
      && tool.annotations?["destructiveHint"] != .bool(true)
  }
}
