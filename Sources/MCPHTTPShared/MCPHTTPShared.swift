import Foundation
import MCP

public enum MCPHTTPHeaderName {
  public static let protocolVersion = "Mcp-Protocol-Version"
  public static let method = "Mcp-Method"
  public static let name = "Mcp-Name"
  public static let parameterPrefix = "Mcp-Param-"
}

public struct MCPHTTPHeaders: Sendable, Hashable {
  private var storage: [String: String]
  private var ambiguousNames: Set<String>

  public init(_ values: [String: String] = [:]) {
    var normalized: [String: String] = [:]
    var ambiguous = Set<String>()
    for (name, value) in values.sorted(by: { $0.key < $1.key }) {
      let key = name.lowercased()
      if let existing = normalized[key], existing != value {
        ambiguous.insert(key)
      } else if normalized[key] == nil {
        normalized[key] = value
      }
    }
    storage = normalized
    ambiguousNames = ambiguous
  }

  public subscript(_ name: String) -> String? {
    get { storage[name.lowercased()] }
    set {
      let key = name.lowercased()
      storage[key] = newValue
      ambiguousNames.remove(key)
    }
  }

  public var values: [String: String] { storage }

  /// Rejects dictionary inputs that contained conflicting values for the same case-insensitive
  /// field name. Raw HTTP parsers should reject duplicates before constructing this value; this
  /// check protects programmatic callers without trapping in a public initializer.
  public func validate() throws {
    guard ambiguousNames.isEmpty else {
      throw MCPHTTPError.invalidHeaderName(
        "conflicting case-insensitive header names: \(ambiguousNames.sorted().joined(separator: ", "))"
      )
    }
    for (name, value) in storage {
      guard Self.isValidFieldName(name) else {
        throw MCPHTTPError.invalidHeaderName(name)
      }
      guard value.utf8.allSatisfy({ $0 == 0x09 || (0x20...0x7E).contains($0) }) else {
        throw MCPHTTPError.invalidHeaderEncoding(name)
      }
    }
  }

  public mutating func merge(_ other: MCPHTTPHeaders) {
    ambiguousNames.formUnion(other.ambiguousNames)
    for (key, value) in other.storage {
      storage[key] = value
      if !other.ambiguousNames.contains(key) { ambiguousNames.remove(key) }
    }
  }

  private static func isValidFieldName(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy { byte in
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
          0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E,
          0x5E, 0x5F, 0x60, 0x7C, 0x7E:
          true
        default:
          false
        }
      }
  }
}

public enum MCPHTTPError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidEndpoint
  case invalidHeaderName(String)
  case invalidHeaderEncoding(String)
  case headerMismatch(String)
  case unsupportedContentType(String?)
  case redirectRejected(String?)
  case invalidStatus(Int, body: String?)
  case responseTooLarge(Int)
  case eventTooLarge(Int)
  case malformedSSE(String)
  case connectionClosed
  case io(String)

  public var description: String {
    switch self {
    case .invalidEndpoint: "invalid MCP HTTP endpoint"
    case .invalidHeaderName(let value): "invalid MCP HTTP header name \(value)"
    case .invalidHeaderEncoding(let value): "invalid MCP HTTP Base64 header value \(value)"
    case .headerMismatch(let value): "MCP HTTP header mismatch: \(value)"
    case .unsupportedContentType(let value):
      "unsupported MCP HTTP content type \(value ?? "<missing>")"
    case .redirectRejected(let value):
      "MCP HTTP redirect rejected\(value.map { ": \($0)" } ?? "")"
    case .invalidStatus(let code, let body): "MCP HTTP status \(code): \(body ?? "")"
    case .responseTooLarge(let limit): "MCP HTTP response exceeds \(limit) bytes"
    case .eventTooLarge(let limit): "MCP SSE event exceeds \(limit) bytes"
    case .malformedSSE(let reason): "malformed MCP SSE stream: \(reason)"
    case .connectionClosed: "MCP HTTP connection closed before a terminal response"
    case .io(let value): "MCP HTTP I/O error: \(value)"
    }
  }
}

package enum MCPHTTPAuthorizationHeader {
  package static func bearer(token: String) throws -> String {
    guard isValidBearerToken(token) else {
      throw MCPHTTPError.invalidHeaderEncoding("invalid bearer token")
    }
    return "Bearer \(token)"
  }

  package static func bearerToken(from value: String) -> String? {
    guard let separator = value.firstIndex(of: " ") else { return nil }
    let scheme = value[..<separator]
    var tokenStart = separator
    while tokenStart < value.endIndex, value[tokenStart] == " " {
      tokenStart = value.index(after: tokenStart)
    }
    guard scheme.caseInsensitiveCompare("Bearer") == .orderedSame,
      tokenStart < value.endIndex
    else { return nil }
    let token = String(value[tokenStart...])
    guard isValidBearerToken(token) else { return nil }
    return token
  }

  private static func isValidBearerToken(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    var padding = false
    for byte in value.utf8 {
      if byte == 0x3D {
        padding = true
        continue
      }
      guard !padding else { return false }
      switch byte {
      case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E, 0x2B, 0x2F:
        continue
      default:
        return false
      }
    }
    return true
  }
}

public enum MCPHTTPHeaderValueCodec {
  private static let prefix = "=?base64?"
  private static let suffix = "?="

  public static func encode(_ value: String) -> String {
    guard requiresBase64(value) else { return value }
    return prefix + Data(value.utf8).base64EncodedString() + suffix
  }

  public static func decode(_ value: String) throws -> String {
    guard value.hasPrefix(prefix) else {
      guard !requiresBase64(value) else {
        throw MCPHTTPError.invalidHeaderEncoding(value)
      }
      return value
    }
    guard value.hasSuffix(suffix) else {
      throw MCPHTTPError.invalidHeaderEncoding(value)
    }
    let start = value.index(value.startIndex, offsetBy: prefix.count)
    let end = value.index(value.endIndex, offsetBy: -suffix.count)
    guard start <= end,
      let data = Data(base64Encoded: String(value[start..<end])),
      let decoded = String(data: data, encoding: .utf8)
    else {
      throw MCPHTTPError.invalidHeaderEncoding(value)
    }
    return decoded
  }

  private static func requiresBase64(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    if value.first == " " || value.first == "\t" || value.last == " " || value.last == "\t" {
      return true
    }
    if value.hasPrefix(prefix), value.hasSuffix(suffix) { return true }
    return value.utf8.contains { $0 < 0x20 || $0 > 0x7E }
  }
}

public enum MCPHTTPHeaderPrimitive: Sendable, Hashable {
  case string(String)
  case integer(Int64)
  case boolean(Bool)

  public init?(json: MCPJSONValue) {
    switch json {
    case .string(let value): self = .string(value)
    case .bool(let value): self = .boolean(value)
    case .number(let number):
      guard let value = number.int64Value,
        value >= -9_007_199_254_740_991,
        value <= 9_007_199_254_740_991
      else { return nil }
      self = .integer(value)
    default:
      return nil
    }
  }

  public var stringValue: String {
    switch self {
    case .string(let value): value
    case .integer(let value): String(value)
    case .boolean(let value): value ? "true" : "false"
    }
  }
}

public struct MCPHTTPToolHeaderBinding: Sendable, Hashable {
  public let path: [String]
  public let headerName: String
  public let type: String
}

public struct MCPHTTPToolHeaderSchema: Sendable, Hashable {
  public let toolName: String
  public let bindings: [MCPHTTPToolHeaderBinding]

  public init(tool: MCPTool) throws {
    toolName = tool.name
    var collected: [MCPHTTPToolHeaderBinding] = []
    var seen = Set<String>()
    try Self.walkSchema(
      .object(tool.inputSchema),
      path: [],
      isReachableProperty: false,
      output: &collected,
      seenHeaders: &seen
    )
    bindings = collected.sorted { lhs, rhs in
      if lhs.headerName.lowercased() == rhs.headerName.lowercased() {
        return lhs.path.lexicographicallyPrecedes(rhs.path)
      }
      return lhs.headerName.lowercased() < rhs.headerName.lowercased()
    }
  }

  public func generatedHeaders(arguments: [String: MCPJSONValue]) throws -> MCPHTTPHeaders {
    var result = MCPHTTPHeaders()
    for binding in bindings {
      guard let value = Self.lookup(arguments, path: binding.path), value != .null else {
        continue
      }
      let primitive = try Self.primitive(value, binding: binding)
      result[MCPHTTPHeaderName.parameterPrefix + binding.headerName] =
        MCPHTTPHeaderValueCodec.encode(primitive.stringValue)
    }
    return result
  }

  public func validate(headers: MCPHTTPHeaders, arguments: [String: MCPJSONValue]) throws {
    for binding in bindings {
      let fullName = MCPHTTPHeaderName.parameterPrefix + binding.headerName
      let body = Self.lookup(arguments, path: binding.path)
      let rawHeader = headers[fullName]
      if body == nil || body == .null {
        guard rawHeader == nil else {
          throw MCPHTTPError.headerMismatch("unexpected \(fullName) for absent parameter")
        }
        continue
      }
      guard let body else {
        throw MCPHTTPError.headerMismatch("missing body value for \(fullName)")
      }
      let primitive = try Self.primitive(body, binding: binding)
      guard let rawHeader else {
        throw MCPHTTPError.headerMismatch("missing \(fullName)")
      }
      let decoded = try MCPHTTPHeaderValueCodec.decode(rawHeader)
      let matches: Bool =
        switch primitive {
        case .integer(let expected):
          if let number = try? MCPJSONNumber(rawValue: decoded) {
            number.isNumericallyEqual(to: MCPJSONNumber(expected))
          } else {
            false
          }
        case .string, .boolean:
          decoded == primitive.stringValue
        }
      guard matches else {
        throw MCPHTTPError.headerMismatch("\(fullName) does not match the request body")
      }
    }
  }

  private static func primitive(
    _ value: MCPJSONValue,
    binding: MCPHTTPToolHeaderBinding
  ) throws -> MCPHTTPHeaderPrimitive {
    let fullName = MCPHTTPHeaderName.parameterPrefix + binding.headerName
    switch (binding.type, value) {
    case ("string", .string(let text)):
      return .string(text)
    case ("boolean", .bool(let flag)):
      return .boolean(flag)
    case ("integer", .number(let number)):
      guard let exact = number.exactIntValue,
        exact >= -9_007_199_254_740_991,
        exact <= 9_007_199_254_740_991
      else {
        throw MCPHTTPError.headerMismatch(
          "\(fullName) is not an exact JavaScript-safe integer")
      }
      return .integer(Int64(exact))
    default:
      throw MCPHTTPError.headerMismatch(
        "\(fullName) does not match declared schema type \(binding.type)")
    }
  }

  /// Walks only concrete object-property paths. Header annotations placed under arrays,
  /// combinators, definitions, or any other non-property schema branch are rejected because
  /// they cannot be deterministically mapped to one request parameter header.
  private static func walkSchema(
    _ value: MCPJSONValue,
    path: [String],
    isReachableProperty: Bool,
    output: inout [MCPHTTPToolHeaderBinding],
    seenHeaders: inout Set<String>
  ) throws {
    guard case .object(let definition) = value else { return }

    if let annotation = definition["x-mcp-header"] {
      guard isReachableProperty else {
        throw MCPHTTPError.invalidHeaderName(
          "x-mcp-header is not attached to a reachable object property")
      }
      guard case .string(let header) = annotation, !header.isEmpty else {
        throw MCPHTTPError.invalidHeaderName(
          "x-mcp-header at \(path.joined(separator: "."))")
      }
      guard isValidHeaderToken(header) else {
        throw MCPHTTPError.invalidHeaderName(header)
      }
      guard case .string(let type)? = definition["type"],
        ["string", "integer", "boolean"].contains(type)
      else {
        throw MCPHTTPError.invalidHeaderName(
          "x-mcp-header at \(path.joined(separator: ".")) requires string, integer, or boolean")
      }
      guard seenHeaders.insert(header.lowercased()).inserted else {
        throw MCPHTTPError.invalidHeaderName("duplicate x-mcp-header \(header)")
      }
      output.append(MCPHTTPToolHeaderBinding(path: path, headerName: header, type: type))
    }

    if let propertiesValue = definition["properties"] {
      guard case .object(let properties) = propertiesValue else {
        throw MCPHTTPError.invalidHeaderName(
          "properties at \(path.joined(separator: ".")) must be an object")
      }
      for key in properties.keys.sorted() {
        guard let child = properties[key] else { continue }
        try walkSchema(
          child,
          path: path + [key],
          isReachableProperty: true,
          output: &output,
          seenHeaders: &seenHeaders
        )
      }
    }

    for (key, child) in definition where key != "properties" && key != "x-mcp-header" {
      try rejectUnreachableAnnotations(in: child, path: path + [key])
    }
  }

  private static func rejectUnreachableAnnotations(
    in value: MCPJSONValue,
    path: [String]
  ) throws {
    switch value {
    case .object(let object):
      if object["x-mcp-header"] != nil {
        throw MCPHTTPError.invalidHeaderName(
          "x-mcp-header at \(path.joined(separator: ".")) is outside a reachable object property")
      }
      for (key, child) in object {
        try rejectUnreachableAnnotations(in: child, path: path + [key])
      }
    case .array(let array):
      for (index, child) in array.enumerated() {
        try rejectUnreachableAnnotations(in: child, path: path + [String(index)])
      }
    default:
      break
    }
  }

  private static func lookup(
    _ arguments: [String: MCPJSONValue],
    path: [String]
  ) -> MCPJSONValue? {
    guard let first = path.first, var value = arguments[first] else { return nil }
    for component in path.dropFirst() {
      guard case .object(let object) = value, let next = object[component] else { return nil }
      value = next
    }
    return value
  }

  private static func isValidHeaderToken(_ value: String) -> Bool {
    !value.isEmpty
      && value.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...90, 97...122:
          true
        case 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
          true
        default:
          false
        }
      }
  }
}

public enum MCPHTTPStandardHeaders {
  public static func make(
    for request: MCPWireRequest,
    descriptor: MCPMethodDescriptor,
    toolSchema: MCPHTTPToolHeaderSchema? = nil
  ) throws -> MCPHTTPHeaders {
    var headers = MCPHTTPHeaders([
      MCPHTTPHeaderName.protocolVersion: MCPProtocolVersion.current.rawValue,
      MCPHTTPHeaderName.method: request.method,
    ])
    if let name = try descriptor.httpName(from: request.params) {
      headers[MCPHTTPHeaderName.name] = MCPHTTPHeaderValueCodec.encode(name)
    }
    if request.method == "tools/call", let toolSchema {
      let params = try MCPCallToolParams(json: .object(request.params))
      headers.merge(try toolSchema.generatedHeaders(arguments: params.arguments))
    }
    return headers
  }

  public static func validate(
    _ headers: MCPHTTPHeaders,
    request: MCPWireRequest,
    descriptor: MCPMethodDescriptor,
    toolSchema: MCPHTTPToolHeaderSchema? = nil
  ) throws {
    try headers.validate()
    guard headers[MCPHTTPHeaderName.protocolVersion] == MCPProtocolVersion.current.rawValue else {
      throw MCPHTTPError.headerMismatch("missing or unsupported Mcp-Protocol-Version")
    }
    guard headers[MCPHTTPHeaderName.method] == request.method else {
      throw MCPHTTPError.headerMismatch("Mcp-Method does not match the request body")
    }
    if let expectedName = try descriptor.httpName(from: request.params) {
      guard let raw = headers[MCPHTTPHeaderName.name] else {
        throw MCPHTTPError.headerMismatch("missing Mcp-Name")
      }
      guard try MCPHTTPHeaderValueCodec.decode(raw) == expectedName else {
        throw MCPHTTPError.headerMismatch("Mcp-Name does not match the request body")
      }
    } else if headers[MCPHTTPHeaderName.name] != nil {
      throw MCPHTTPError.headerMismatch("unexpected Mcp-Name")
    }
    if request.method == "tools/call", let toolSchema {
      let params = try MCPCallToolParams(json: .object(request.params))
      try toolSchema.validate(headers: headers, arguments: params.arguments)
    }
  }
}

public enum MCPSSEEncoder {
  /// Encodes one SSE data event. Every input line is emitted as its own `data:` field and the
  /// event is terminated by a blank line as required by the SSE framing rules.
  public static func dataEvent(_ payload: Data) -> Data {
    let bytes = [UInt8](payload)
    var output = Data()
    var lineStart = 0
    var index = 0
    while index <= bytes.count {
      let isBoundary = index == bytes.count || bytes[index] == 0x0A
      if isBoundary {
        output.append(Data("data: ".utf8))
        if lineStart < index {
          var end = index
          if end > lineStart, bytes[end - 1] == 0x0D { end -= 1 }
          if lineStart < end { output.append(contentsOf: bytes[lineStart..<end]) }
        }
        output.append(0x0A)
        lineStart = index + 1
      }
      index += 1
    }
    output.append(0x0A)
    return output
  }

  /// Encodes an SSE comment/keep-alive event. Embedded line breaks are rejected so one logical
  /// comment cannot smuggle additional SSE fields.
  public static func comment(_ value: String = "") throws -> Data {
    guard !value.contains("\n"), !value.contains("\r") else {
      throw MCPHTTPError.malformedSSE("comment must not contain line breaks")
    }
    return Data((value.isEmpty ? ":\n\n" : ": " + value + "\n\n").utf8)
  }
}

public struct MCPSSEDecoder: Sendable {
  private var buffer = Data()
  private var dataLines: [Data] = []
  private var currentDataBytes = 0
  private var currentEventFramingBytes = 0
  private let maximumEventBytes: Int

  public init(maximumEventBytes: Int = MCPJSONLimits.default.maximumDocumentBytes) throws {
    guard maximumEventBytes > 0 else {
      throw MCPJSONError.invalidField(field: "maximumEventBytes", reason: "must be positive")
    }
    self.maximumEventBytes = maximumEventBytes
  }

  public mutating func append(_ chunk: Data) throws -> [Data] {
    buffer.append(chunk)
    var events: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      var line = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if line.last == 0x0D { line.removeLast() }

      // A line beginning with a colon is an SSE comment. MCP recommends comment keep-alives on
      // long-lived streams and requires clients to ignore them rather than treat them as malformed
      // input, so a comment must neither advance the current event's framing budget nor leave the
      // decoder in a state that reports a clean end-of-stream as a truncated event.
      if line.first == 0x3A {
        guard line.count <= maximumEventBytes else {
          throw MCPHTTPError.eventTooLarge(maximumEventBytes)
        }
        continue
      }

      currentEventFramingBytes += line.count + 1
      guard currentEventFramingBytes <= maximumEventBytes else {
        throw MCPHTTPError.eventTooLarge(maximumEventBytes)
      }

      if line.isEmpty {
        if !dataLines.isEmpty {
          var event = Data()
          for (index, part) in dataLines.enumerated() {
            if index > 0 { event.append(0x0A) }
            event.append(part)
          }
          events.append(event)
        }
        dataLines.removeAll(keepingCapacity: true)
        currentDataBytes = 0
        currentEventFramingBytes = 0
        continue
      }
      guard let colon = line.firstIndex(of: 0x3A) else { continue }
      let field = String(decoding: line[..<colon], as: UTF8.self)
      guard field == "data" else { continue }
      var value = Data(line[line.index(after: colon)...])
      if value.first == 0x20 { value.removeFirst() }
      let separatorBytes = dataLines.isEmpty ? 0 : 1
      guard value.count <= maximumEventBytes - currentDataBytes - separatorBytes else {
        throw MCPHTTPError.eventTooLarge(maximumEventBytes)
      }
      currentDataBytes += separatorBytes + value.count
      dataLines.append(value)
    }
    // A network read may contain many complete small events. Bound only the unfinished event/line,
    // not the aggregate transport chunk that happened to deliver them.
    guard buffer.count <= maximumEventBytes else {
      throw MCPHTTPError.eventTooLarge(maximumEventBytes)
    }
    return events
  }

  public mutating func finish() throws -> [Data] {
    guard buffer.isEmpty else {
      throw MCPHTTPError.malformedSSE("stream ended in the middle of a line")
    }
    guard dataLines.isEmpty, currentEventFramingBytes == 0 else {
      throw MCPHTTPError.malformedSSE("stream ended before an event delimiter")
    }
    return []
  }
}
