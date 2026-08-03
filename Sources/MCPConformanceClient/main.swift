import Foundation
import MCP
import MCPStdioClient

@main
enum MCPConformanceClient {
  static func main() async throws {
    guard CommandLine.arguments.count >= 2 else {
      throw MCPClientError.transport("usage: mcp-conformance-client <server-executable>")
    }
    let transport = MCPStdioClientTransport(
      configuration: try MCPStdioClientConfiguration(
        executableURL: URL(fileURLWithPath: CommandLine.arguments[1]),
        arguments: Array(CommandLine.arguments.dropFirst(2)),
        diagnosticHandler: { line in
          FileHandle.standardError.write(Data("server: \(line)\n".utf8))
        }
      ))
    let client = try MCPClient(
      transport: transport,
      configuration: MCPClientConfiguration(
        implementation: try MCPImplementation(name: "mcp-conformance-client", version: "1.0.0"),
        capabilities: MCPClientCapabilities(),
        requestTimeout: .seconds(5)
      )
    )
    let discovery = try await client.discover()
    guard discovery.supportedVersions == [MCPProtocolVersion.current.rawValue] else {
      throw MCPClientError.protocolViolation("strict protocol version was not advertised")
    }
    let tools = try await client.listTools()
    guard tools.tools.contains(where: { $0.name == "echo" }) else {
      throw MCPClientError.protocolViolation("echo tool was not listed")
    }
    let result = try await client.callTool(
      MCPCallToolParams(name: "echo", arguments: ["text": .string("conformance")]))
    guard result.isError == false,
      result.content.contains(where: {
        if case .text(let text) = $0 { return text.text == "conformance" }
        return false
      })
    else {
      throw MCPClientError.protocolViolation("echo result did not match")
    }
    await transport.shutdown()
    print("PASS stdio strict discovery/list/call")
  }
}
