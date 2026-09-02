public struct MCPLoggingMessageParams: Sendable, Hashable, MCPJSONModel {
  public let level: MCPLoggingLevel
  public let logger: String?
  public let data: MCPJSONValue
  public let metadata: MCPNotificationMetadata?

  public init(
    level: MCPLoggingLevel,
    logger: String? = nil,
    data: MCPJSONValue,
    metadata: MCPNotificationMetadata? = nil
  ) throws {
    guard metadata?.subscriptionID == nil else {
      throw MCPJSONError.invalidField(
        field: "_meta",
        reason: "request-scoped logging notifications cannot carry a subscription id"
      )
    }
    self.level = level
    self.logger = logger
    self.data = data
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      level: MCPLoggingLevel(
        json: object.values["level"] ?? { throw MCPJSONError.missingField("level") }()),
      logger: try object.optionalString("logger"),
      data: object.values["data"] ?? { throw MCPJSONError.missingField("data") }(),
      metadata: try object.values["_meta"].map(MCPNotificationMetadata.init(json:))
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("level", level.json),
      ("logger", logger.map(MCPJSONValue.string)),
      ("data", data),
      ("_meta", metadata?.json),
    ])
  }
}

/// Request-scoped server logger for MCP 2026-07-28.
///
/// A logger exists only when the client explicitly opts in with
/// `io.modelcontextprotocol/logLevel`. It cannot outlive its request exchange.
public struct MCPRequestLogger: Sendable {
  private let body: @Sendable (MCPLoggingMessageParams) async throws -> Void

  public init(
    _ body: @escaping @Sendable (MCPLoggingMessageParams) async throws -> Void
  ) {
    self.body = body
  }

  public func log(
    _ level: MCPLoggingLevel,
    logger: String? = nil,
    data: MCPJSONValue,
    metadata: MCPNotificationMetadata? = nil
  ) async throws {
    try await body(
      MCPLoggingMessageParams(
        level: level,
        logger: logger,
        data: data,
        metadata: metadata
      )
    )
  }
}
