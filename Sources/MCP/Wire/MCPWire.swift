import Foundation

public enum MCPRequestID: Sendable, Hashable, CustomStringConvertible {
  case string(String)
  case integer(MCPJSONNumber)

  public init(_ value: Int64) {
    self = .integer(MCPJSONNumber(validated: String(value)))
  }

  public init(json: MCPJSONValue) throws {
    switch json {
    case .string(let value): self = .string(value)
    case .number(let value) where value.isInteger: self = .integer(value)
    case .number: throw MCPWireError.floatingRequestID
    case .null: throw MCPWireError.nullRequestID
    default: throw MCPWireError.invalidRequestID
    }
  }

  public var json: MCPJSONValue {
    switch self {
    case .string(let value): .string(value)
    case .integer(let value): .number(value)
    }
  }

  public var description: String {
    switch self {
    case .string(let value): value
    case .integer(let value): value.rawValue
    }
  }
}

public enum MCPResultType: Sendable, Hashable, Equatable {
  case complete
  case inputRequired
  case extensionValue(String)

  public init(rawValue: String) throws {
    guard !rawValue.isEmpty else {
      throw MCPWireError.invalidResultType(rawValue)
    }
    switch rawValue {
    case "complete": self = .complete
    case "input_required": self = .inputRequired
    default: self = .extensionValue(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .complete: "complete"
    case .inputRequired: "input_required"
    case .extensionValue(let value): value
    }
  }
}

public struct MCPRPCErrorCode: Sendable, Hashable, CustomStringConvertible,
  ExpressibleByIntegerLiteral
{
  public let rawValue: MCPJSONNumber

  public init(_ value: Int) {
    rawValue = MCPJSONNumber(value)
  }

  public init(_ value: Int64) {
    rawValue = MCPJSONNumber(value)
  }

  public init(_ value: UInt64) {
    rawValue = MCPJSONNumber(value)
  }

  public init(rawValue: MCPJSONNumber) throws {
    guard rawValue.isMathematicalInteger else { throw MCPWireError.invalidErrorCode }
    self.rawValue = rawValue
  }

  public init(integerLiteral value: Int) {
    self.init(value)
  }

  public var int64Value: Int64? {
    rawValue.exactIntValue.map(Int64.init)
  }

  public var description: String { rawValue.rawValue }

  public static prefix func - (value: Self) -> Self {
    let rawValue = value.rawValue.rawValue
    let negated =
      rawValue.first == "-"
      ? String(rawValue.dropFirst())
      : "-" + rawValue
    return Self(validatedRawValue: negated)
  }

  private init(validatedRawValue: String) {
    rawValue = MCPJSONNumber(validated: validatedRawValue)
  }
}

public struct MCPRPCError: Error, Sendable, Hashable, CustomStringConvertible {
  public let code: MCPRPCErrorCode
  public let message: String
  public let data: MCPJSONValue?

  public init(code: MCPRPCErrorCode, message: String, data: MCPJSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }

  public var description: String { "RPC error \(code): \(message)" }

  public static let parseError = MCPRPCError(code: -32700, message: "Parse error")
  public static let invalidRequest = MCPRPCError(code: -32600, message: "Invalid Request")
  public static let methodNotFound = MCPRPCError(code: -32601, message: "Method not found")
  public static let invalidParams = MCPRPCError(code: -32602, message: "Invalid params")
  public static let internalError = MCPRPCError(code: -32603, message: "Internal error")

  public static func headerMismatch(_ message: String, data: MCPJSONValue? = nil) -> MCPRPCError {
    MCPRPCError(code: -32020, message: message, data: data)
  }

  public static func missingRequiredClientCapabilities(
    _ message: String,
    requiredCapabilities: MCPClientCapabilities? = nil
  ) -> MCPRPCError {
    let data = requiredCapabilities.map { capabilities in
      MCPJSONValue.object(["requiredCapabilities": capabilities.json])
    }
    return MCPRPCError(code: -32021, message: message, data: data)
  }

  public static func unsupportedProtocolVersion(_ version: String) -> MCPRPCError {
    MCPRPCError(
      code: -32022, message: "Unsupported protocol version",
      data: .object([
        "requested": .string(version),
        "supported": .array([.string(MCPProtocolVersion.current.rawValue)]),
      ]))
  }
}

public enum MCPWireError: Error, Sendable, Equatable, CustomStringConvertible {
  case batchNotSupported
  case topLevelMustBeObject
  case invalidJSONRPCVersion
  case ambiguousEnvelope
  case missingID
  case nullRequestID
  case floatingRequestID
  case invalidRequestID
  case invalidErrorCode
  /// A result omitted the required discriminator for this strict stateless profile.
  case missingResultType
  case invalidResultType(String)
  case resultMustBeObject
  case paramsMustBeObject
  case invalidMethod
  case unexpectedMessage(String)

  public var description: String {
    switch self {
    case .batchNotSupported: "JSON-RPC batch messages are not supported"
    case .topLevelMustBeObject: "JSON-RPC envelope must be an object"
    case .invalidJSONRPCVersion: "jsonrpc must equal 2.0"
    case .ambiguousEnvelope: "JSON-RPC envelope has an ambiguous discriminator"
    case .missingID: "JSON-RPC response is missing id"
    case .nullRequestID: "JSON-RPC null id is rejected by strict mode"
    case .floatingRequestID: "JSON-RPC floating-point id is rejected by strict mode"
    case .invalidRequestID: "JSON-RPC id must be a string or integer"
    case .invalidErrorCode: "JSON-RPC error code must be an integer"
    case .missingResultType:
      "MCP result is missing resultType"
    case .invalidResultType(let value): "Invalid resultType \(value.debugDescription)"
    case .resultMustBeObject: "MCP successful result must be an object"
    case .paramsMustBeObject: "MCP params must be an object"
    case .invalidMethod: "JSON-RPC method must be a non-empty string"
    case .unexpectedMessage(let message): message
    }
  }
}

/// A transport error whose concrete, sendable value must remain available to an MCP client host.
///
/// Transports use this only for errors that require caller action beyond diagnostics. Other
/// transport failures remain descriptive `MCPClientError.transport` values.
public protocol MCPClientTransportFailure: Error, Sendable {}

public enum MCPClientError: Error, Sendable, CustomStringConvertible {
  case transport(String)
  case transportFailure(any MCPClientTransportFailure)
  case wire(MCPWireError)
  case json(MCPJSONError)
  case rpc(MCPRPCError)
  case cancelled
  case peerCancelled(reason: String?)
  case timeout
  case protocolViolation(String)
  case inputRequiredButNoProvider
  case maximumRoundTripsExceeded(Int)

  public var description: String {
    switch self {
    case .transport(let message): "Transport error: \(message)"
    case .transportFailure(let error): "Transport error: \(error)"
    case .wire(let error): error.description
    case .json(let error): error.description
    case .rpc(let error): error.description
    case .cancelled: "Request cancelled"
    case .peerCancelled(let reason):
      if let reason, !reason.isEmpty {
        "Server cancelled the subscription: \(reason)"
      } else {
        "Server cancelled the subscription"
      }
    case .timeout: "Request timed out"
    case .protocolViolation(let message): "Protocol violation: \(message)"
    case .inputRequiredButNoProvider:
      "Server requires input but no elicitation provider is configured"
    case .maximumRoundTripsExceeded(let value): "Multi-round-trip limit exceeded (\(value))"
    }
  }
}

public struct MCPWireRequest: Sendable, Hashable {
  public let id: MCPRequestID
  public let method: String
  public let params: [String: MCPJSONValue]

  public init(id: MCPRequestID, method: String, params: [String: MCPJSONValue]) throws {
    guard !method.isEmpty else { throw MCPWireError.invalidMethod }
    self.id = id
    self.method = method
    self.params = params
  }
}

public struct MCPWireNotification: Sendable, Hashable {
  public let method: String
  public let params: [String: MCPJSONValue]

  public init(method: String, params: [String: MCPJSONValue] = [:]) throws {
    guard !method.isEmpty else { throw MCPWireError.invalidMethod }
    self.method = method
    self.params = params
  }
}

public struct MCPWireResult: Sendable, Hashable {
  public let id: MCPRequestID
  public let resultType: MCPResultType
  public let value: [String: MCPJSONValue]

  public init(
    id: MCPRequestID, resultType: MCPResultType = .complete, value: [String: MCPJSONValue]
  ) {
    self.id = id
    self.resultType = resultType
    var value = value
    value["resultType"] = .string(resultType.rawValue)
    self.value = value
  }
}

public struct MCPWireErrorResponse: Sendable, Hashable {
  /// The peer request ID when it could be decoded. MCP error responses may omit `id` when the
  /// incoming request was malformed before its ID could be recovered.
  public let id: MCPRequestID?
  public let error: MCPRPCError

  public init(id: MCPRequestID? = nil, error: MCPRPCError) {
    self.id = id
    self.error = error
  }
}

public enum MCPWireMessage: Sendable, Hashable {
  case request(MCPWireRequest)
  case notification(MCPWireNotification)
  case result(MCPWireResult)
  case error(MCPWireErrorResponse)

  public static func decode(_ data: Data, limits: MCPJSONLimits = .default) throws -> MCPWireMessage
  {
    let value = try MCPJSONValue.parse(data, limits: limits)
    if case .array = value { throw MCPWireError.batchNotSupported }
    guard case .object(let object) = value else { throw MCPWireError.topLevelMustBeObject }
    guard object["jsonrpc"] == .string("2.0") else { throw MCPWireError.invalidJSONRPCVersion }

    let hasMethod = object["method"] != nil
    let hasResult = object["result"] != nil
    let hasError = object["error"] != nil
    guard [hasMethod, hasResult, hasError].filter({ $0 }).count == 1 else {
      throw MCPWireError.ambiguousEnvelope
    }

    if hasMethod {
      guard case .string(let method)? = object["method"], !method.isEmpty else {
        throw MCPWireError.invalidMethod
      }
      let params: [String: MCPJSONValue]
      if let rawParams = object["params"] {
        guard case .object(let value) = rawParams else { throw MCPWireError.paramsMustBeObject }
        params = value
      } else {
        params = [:]
      }
      if let rawID = object["id"] {
        return .request(
          try MCPWireRequest(id: MCPRequestID(json: rawID), method: method, params: params))
      }
      return .notification(try MCPWireNotification(method: method, params: params))
    }

    if hasResult {
      guard let rawID = object["id"] else { throw MCPWireError.missingID }
      let id = try MCPRequestID(json: rawID)
      guard case .object(let result)? = object["result"] else {
        throw MCPWireError.resultMustBeObject
      }
      guard let rawResultType = result["resultType"] else {
        throw MCPWireError.missingResultType
      }
      guard case .string(let value) = rawResultType else {
        throw MCPWireError.invalidResultType("non-string resultType")
      }
      let resultType = try MCPResultType(rawValue: value)
      return .result(MCPWireResult(id: id, resultType: resultType, value: result))
    }

    guard case .object(let errorObject)? = object["error"] else {
      throw MCPWireError.ambiguousEnvelope
    }
    let id = try object["id"].map(MCPRequestID.init(json:))
    let error = try MCPRPCError(json: .object(errorObject))
    return .error(MCPWireErrorResponse(id: id, error: error))
  }

  public func encoded(limits: MCPJSONLimits = .default) throws -> Data {
    try json.encoded(limits: limits)
  }

  public var json: MCPJSONValue {
    switch self {
    case .request(let request):
      return .object([
        "jsonrpc": .string("2.0"), "id": request.id.json, "method": .string(request.method),
        "params": .object(request.params),
      ])
    case .notification(let notification):
      return .object([
        "jsonrpc": .string("2.0"), "method": .string(notification.method),
        "params": .object(notification.params),
      ])
    case .result(let result):
      return .object([
        "jsonrpc": .string("2.0"), "id": result.id.json, "result": .object(result.value),
      ])
    case .error(let response):
      return mcpObject([
        ("jsonrpc", .string("2.0")),
        ("id", response.id?.json),
        ("error", response.error.json),
      ])
    }
  }
}

extension MCPRPCError: MCPJSONModel {
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard let codeNumber = object.values["code"]?.numberValue,
      codeNumber.isMathematicalInteger
    else { throw MCPWireError.invalidErrorCode }
    self.init(
      code: try MCPRPCErrorCode(rawValue: codeNumber),
      message: try object.requiredString("message"),
      data: object.values["data"])
  }

  public var json: MCPJSONValue {
    mcpObject([("code", .number(code.rawValue)), ("message", .string(message)), ("data", data)])
  }
}
