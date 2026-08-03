import Foundation
import MCP
import MCPHTTPServer
import MCPStdioServer

private struct StderrDiagnostics: MCPDiagnosticSink {
  func record(_ event: MCPDiagnosticEvent) async {
    let fields = event.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(
      separator: " ")
    FileHandle.standardError.write(Data("\(event.level.rawValue) \(event.id) \(fields)\n".utf8))
  }
}

private enum ConformanceServerError: Error, CustomStringConvertible {
  case usage(String)

  var description: String {
    switch self {
    case .usage(let message): message
    }
  }
}

private enum LaunchMode {
  case stdio
  case http(bindAddress: String, port: UInt16)

  init(arguments: [String]) throws {
    guard !arguments.isEmpty else {
      self = .stdio
      return
    }
    guard arguments.count == 3, arguments[0] == "--http" else {
      throw ConformanceServerError.usage(
        "usage: mcp-conformance-server [--http <ipv4-address> <port>]"
      )
    }
    guard let port = UInt16(arguments[2]) else {
      throw ConformanceServerError.usage("port must be an integer between 0 and 65535")
    }
    self = .http(bindAddress: arguments[1], port: port)
  }
}

private actor ConformanceMutationHooks {
  private var server: MCPServer?

  func install(server: MCPServer) {
    self.server = server
  }

  func notifyToolsChanged() async throws {
    guard let server else {
      throw MCPClientError.transport("conformance mutation hooks are not installed")
    }
    try await server.notifyToolsChanged()
  }
}

@main
enum MCPConformanceServer {
  static func main() async throws {
    let mode = try LaunchMode(arguments: Array(CommandLine.arguments.dropFirst()))
    let hooks = ConformanceMutationHooks()
    let cache = try MCPCachePolicy(ttlMilliseconds: 1_000, scope: .public)
    let echo = try MCPTool(
      name: "echo",
      description: "Deterministic conformance echo tool.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "text": .object(["type": .string("string")])
        ]),
        "required": .array([.string("text")]),
        "additionalProperties": .bool(false),
      ]
    )
    let wait = try MCPTool(
      name: "wait",
      description: "Cancellable delay used to verify timeout recovery.",
      inputSchema: [
        "type": .string("object"),
        "additionalProperties": .bool(false),
      ]
    )
    let streamingElicitation = try MCPTool(
      name: "test_streaming_elicitation",
      description: "Returns a response without emitting independent server requests.",
      inputSchema: [
        "type": .string("object"),
        "additionalProperties": .bool(false),
      ]
    )
    let logging = try MCPTool(
      name: "test_logging_tool",
      description: "Exercises the request-scoped logging boundary.",
      inputSchema: [
        "type": .string("object"),
        "additionalProperties": .bool(false),
      ]
    )
    let triggerToolChange = try MCPTool(
      name: "test_trigger_tool_change",
      description: "Publishes a tools/list_changed notification to active subscriptions.",
      inputSchema: [
        "type": .string("object"),
        "additionalProperties": .bool(false),
      ]
    )
    let missingCapability = try MCPTool(
      name: "test_missing_capability",
      description: "Returns the standard missing-client-capability error.",
      inputSchema: [
        "type": .string("object"),
        "additionalProperties": .bool(false),
      ]
    )
    let tools = [echo, wait, streamingElicitation, logging, triggerToolChange, missingCapability]

    var builder = try MCPServerBuilder(
      implementation: try MCPImplementation(name: "mcp-conformance-server", version: "1.0.0"),
      instructions: "Deterministic MCP 2026-07-28 strict conformance fixture."
    )
    builder.setToolResolver { name, _ in
      switch name {
      case echo.name: echo
      case wait.name: wait
      case streamingElicitation.name: streamingElicitation
      case logging.name: logging
      case triggerToolChange.name: triggerToolChange
      case missingCapability.name: missingCapability
      default: nil
      }
    }
    builder.enableToolListChanged()
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: tools, cache: cache)
    }
    try builder.register(MCPStandardMethods.callTool) { params, context in
      switch params.name {
      case "echo":
        guard case .string(let text)? = params.arguments["text"] else {
          return try MCPCallToolResult(
            content: [.text(MCPTextContent(text: "invalid echo request"))],
            isError: true
          )
        }
        try await context.progress?.report(progress: 0.5, total: 1, message: "half")
        try await context.progress?.report(progress: 1, total: 1, message: "done")
        return try MCPCallToolResult(
          content: [.text(MCPTextContent(text: text))],
          structuredContent: .object(["text": .string(text)])
        )

      case "wait":
        try await Task.sleep(for: .seconds(2))
        return try MCPCallToolResult(
          content: [.text(MCPTextContent(text: "wait completed"))]
        )

      case "test_streaming_elicitation":
        return try MCPCallToolResult(
          content: [.text(MCPTextContent(text: "stream observed: result frames only"))]
        )

      case "test_logging_tool":
        return try MCPCallToolResult(
          content: [.text(MCPTextContent(text: "logging evaluated"))]
        )

      case "test_trigger_tool_change":
        try await hooks.notifyToolsChanged()
        return try MCPCallToolResult(
          content: [.text(MCPTextContent(text: "tools_list_changed published"))]
        )

      case "test_missing_capability":
        throw MCPRPCError(
          code: -32021,
          message: "Missing required client capability sampling",
          data: .object([
            "requiredCapabilities": .object(["sampling": .object([:])])
          ])
        )

      default:
        return try MCPCallToolResult(
          content: [.text(MCPTextContent(text: "unknown tool \(params.name)"))],
          isError: true
        )
      }
    }
    let server = try builder.build(diagnostics: StderrDiagnostics())
    await hooks.install(server: server)
    switch mode {
    case .stdio:
      try await MCPStdioServerRunner(server: server).run()

    case .http(let bindAddress, let port):
      let configuration = try MCPHTTPConfiguration(
        bindAddress: bindAddress,
        port: port,
        endpointPath: "/mcp"
      )
      let httpServer = MCPHTTPServer(server: server, configuration: configuration)
      let endpoint = try httpServer.start()
      FileHandle.standardError.write(
        Data("mcp-conformance-server listening at \(endpoint.absoluteString)\n".utf8)
      )
      do {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(3_600))
        }
      } catch is CancellationError {
        // Cancellation is the graceful in-process shutdown path.
      }
      await httpServer.shutdown()
    }
  }
}
