import MCP

public enum MCPTasksClientError: Error, Sendable, Equatable, CustomStringConvertible {
  case capabilityNotDeclared

  public var description: String {
    switch self {
    case .capabilityNotDeclared:
      "MCPTasksClient requires io.modelcontextprotocol/tasks in client capabilities"
    }
  }
}

/// Typed Tasks extension client over the core request-scoped MCP transport.
///
/// HTTP callers must construct `MCPHTTPClientTransport` with
/// `MCPTasksExtension.methodRegistry()` so task IDs are emitted as `Mcp-Name`. Construction fails
/// when a registry-reporting transport is configured with a different method registry.
public struct MCPTasksClient: Sendable {
  private let client: MCPClient

  public init(
    transport: any MCPClientTransport,
    configuration: MCPClientConfiguration,
    startingRequestID: Int64 = 1,
    diagnostics: any MCPDiagnosticSink = MCPNoopDiagnosticSink()
  ) throws {
    guard MCPTasksExtension.supportsTasks(configuration.capabilities) else {
      throw MCPTasksClientError.capabilityNotDeclared
    }
    let registry = try MCPTasksExtension.methodRegistry()
    client = try MCPClient(
      transport: transport,
      configuration: configuration,
      registry: registry,
      startingRequestID: startingRequestID,
      diagnostics: diagnostics
    )
  }

  public func callTool(
    _ params: MCPCallToolParams,
    progress: MCPProgressHandler? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPTasksCallToolResult {
    try await client.call(
      MCPTasksMethods.callTool,
      params: params,
      progress: progress,
      metadataExtensions: metadataExtensions
    )
  }

  public func getTask(
    taskID: String,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPGetTaskResult {
    try await client.call(
      MCPTasksMethods.get,
      params: MCPGetTaskParams(taskID: taskID),
      metadataExtensions: metadataExtensions
    )
  }

  /// A successful response only acknowledges accepted input. The caller must continue polling;
  /// the acknowledgement does not prove that the task status has changed yet.
  public func updateTask(
    taskID: String,
    inputResponses: [String: MCPJSONValue],
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPTaskAcknowledgement {
    try await client.call(
      MCPTasksMethods.update,
      params: MCPUpdateTaskParams(taskID: taskID, inputResponses: inputResponses),
      metadataExtensions: metadataExtensions
    )
  }

  /// Cancellation is cooperative and eventually consistent. This acknowledgement must not be
  /// interpreted as proof that the task reached the cancelled state.
  public func cancelTask(
    taskID: String,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPTaskAcknowledgement {
    try await client.call(
      MCPTasksMethods.cancel,
      params: MCPCancelTaskParams(taskID: taskID),
      metadataExtensions: metadataExtensions
    )
  }
}
