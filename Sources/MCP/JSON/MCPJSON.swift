import Foundation

public struct MCPJSONLimits: Sendable, Hashable {
  public var maximumDocumentBytes: Int
  public var maximumDepth: Int
  public var maximumStringBytes: Int
  public var maximumContainerElements: Int
  public var maximumNumberBytes: Int

  public init(
    maximumDocumentBytes: Int = 16 * 1024 * 1024,
    maximumDepth: Int = 128,
    maximumStringBytes: Int = 8 * 1024 * 1024,
    maximumContainerElements: Int = 1_000_000,
    maximumNumberBytes: Int = 1_024
  ) {
    self.maximumDocumentBytes = maximumDocumentBytes
    self.maximumDepth = maximumDepth
    self.maximumStringBytes = maximumStringBytes
    self.maximumContainerElements = maximumContainerElements
    self.maximumNumberBytes = maximumNumberBytes
  }

  public static let `default` = MCPJSONLimits()

  public func validate() throws {
    guard maximumDocumentBytes > 0 else {
      throw MCPJSONError.invalidLimit("maximumDocumentBytes")
    }
    guard maximumDepth > 0 else { throw MCPJSONError.invalidLimit("maximumDepth") }
    guard maximumStringBytes >= 0 else { throw MCPJSONError.invalidLimit("maximumStringBytes") }
    guard maximumContainerElements >= 0 else {
      throw MCPJSONError.invalidLimit("maximumContainerElements")
    }
    guard maximumNumberBytes > 0 else { throw MCPJSONError.invalidLimit("maximumNumberBytes") }
  }
}

public enum MCPJSONError: Error, Sendable, Equatable, CustomStringConvertible {
  case documentTooLarge(limit: Int)
  case depthExceeded(limit: Int)
  case stringTooLarge(limit: Int)
  case containerTooLarge(limit: Int)
  case numberTooLarge(limit: Int)
  case invalidLimit(String)
  case unexpectedEnd
  case unexpectedByte(UInt8, offset: Int)
  case trailingData(offset: Int)
  case invalidUTF8(offset: Int)
  case invalidEscape(offset: Int)
  case invalidUnicodeEscape(offset: Int)
  case unpairedSurrogate(offset: Int)
  case invalidNumber(offset: Int)
  case duplicateKey(String)
  case expectedObject
  case expectedArray(field: String)
  case expectedString(field: String)
  case expectedBool(field: String)
  case expectedNumber(field: String)
  case expectedInteger(field: String)
  case missingField(String)
  case invalidField(field: String, reason: String)

  public var description: String {
    switch self {
    case .documentTooLarge(let limit): "JSON document exceeds \(limit) bytes"
    case .depthExceeded(let limit): "JSON nesting exceeds \(limit)"
    case .stringTooLarge(let limit): "JSON string exceeds \(limit) UTF-8 bytes"
    case .containerTooLarge(let limit): "JSON container exceeds \(limit) elements"
    case .numberTooLarge(let limit): "JSON number exceeds \(limit) bytes"
    case .invalidLimit(let name): "Invalid JSON limit: \(name)"
    case .unexpectedEnd: "Unexpected end of JSON"
    case .unexpectedByte(let byte, let offset):
      "Unexpected JSON byte 0x\(String(byte, radix: 16)) at offset \(offset)"
    case .trailingData(let offset): "Trailing JSON data at offset \(offset)"
    case .invalidUTF8(let offset): "Invalid UTF-8 at offset \(offset)"
    case .invalidEscape(let offset): "Invalid JSON escape at offset \(offset)"
    case .invalidUnicodeEscape(let offset): "Invalid Unicode escape at offset \(offset)"
    case .unpairedSurrogate(let offset): "Unpaired Unicode surrogate at offset \(offset)"
    case .invalidNumber(let offset): "Invalid JSON number at offset \(offset)"
    case .duplicateKey(let key): "Duplicate JSON object key \(key.debugDescription)"
    case .expectedObject: "Expected JSON object"
    case .expectedArray(let field): "Expected array for \(field)"
    case .expectedString(let field): "Expected string for \(field)"
    case .expectedBool(let field): "Expected boolean for \(field)"
    case .expectedNumber(let field): "Expected number for \(field)"
    case .expectedInteger(let field): "Expected integer for \(field)"
    case .missingField(let field): "Missing required field \(field)"
    case .invalidField(let field, let reason): "Invalid field \(field): \(reason)"
    }
  }
}

public struct MCPJSONNumber: Sendable, Hashable, CustomStringConvertible {
  public let rawValue: String

  /// Internal construction path for literals already proven valid by their source.
  /// Callers are restricted to integer formatting and the strict JSON parser.
  init(validated rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ value: Int) { self.init(validated: String(value)) }
  public init(_ value: Int64) { self.init(validated: String(value)) }
  public init(_ value: UInt64) { self.init(validated: String(value)) }

  public init(_ value: Double) throws {
    guard value.isFinite else {
      throw MCPJSONError.invalidField(field: "number", reason: "must be finite")
    }
    let text = String(value)
    guard Self.isValid(text) else { throw MCPJSONError.invalidNumber(offset: 0) }
    self.rawValue = text
  }

  public init(rawValue: String) throws {
    guard Self.isValid(rawValue) else { throw MCPJSONError.invalidNumber(offset: 0) }
    self.rawValue = rawValue
  }

  /// Whether the literal uses the JSON integer lexical form. This is intentionally
  /// stricter than `isMathematicalInteger` and is used for JSON-RPC identifiers.
  public var isInteger: Bool {
    !rawValue.contains(".") && !rawValue.contains("e") && !rawValue.contains("E")
  }

  /// Whether the exact decimal value is an integer, regardless of lexical form.
  /// For example, `1`, `1.0`, and `10e-1` are mathematical integers.
  public var isMathematicalInteger: Bool { normalized.isMathematicalInteger }

  public var int64Value: Int64? { isInteger ? Int64(rawValue) : nil }
  public var uint64Value: UInt64? { isInteger ? UInt64(rawValue) : nil }
  public var doubleValue: Double? {
    guard let value = Double(rawValue), value.isFinite else { return nil }
    return value
  }

  /// Compares two JSON numbers without converting through binary floating point.
  public func compare(to other: MCPJSONNumber) -> ComparisonResult {
    normalized.compare(to: other.normalized)
  }

  public func isNumericallyEqual(to other: MCPJSONNumber) -> Bool {
    compare(to: other) == .orderedSame
  }

  /// Returns the exact integer value when the decimal value is integral and fits in `Int`.
  public var exactIntValue: Int? { normalized.exactIntValue }

  /// Exact decimal divisibility used by JSON Schema's `multipleOf` keyword.
  /// Returns `nil` when the requested decimal expansion exceeds the supplied work bound.
  public func isMultiple(
    of divisor: MCPJSONNumber,
    maximumPowerExpansion: Int = 4_096
  ) -> Bool? {
    normalized.isMultiple(of: divisor.normalized, maximumPowerExpansion: maximumPowerExpansion)
  }

  public var description: String { rawValue }

  var schemaSemanticKey: String { normalized.semanticKey }

  private var normalized: MCPNormalizedDecimal {
    // Construction validates the grammar, so normalization cannot fail.
    MCPNormalizedDecimal(rawValue)
  }

  fileprivate static func isValid(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard !bytes.isEmpty else { return false }
    var index = 0
    if bytes[index] == 0x2D {
      index += 1
      guard index < bytes.count else { return false }
    }
    if bytes[index] == 0x30 {
      index += 1
      if index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { return false }
    } else {
      guard bytes[index] >= 0x31, bytes[index] <= 0x39 else { return false }
      index += 1
      while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
    }
    if index < bytes.count, bytes[index] == 0x2E {
      index += 1
      guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else { return false }
      while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
    }
    if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
      index += 1
      if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
      guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else { return false }
      while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
    }
    return index == bytes.count
  }
}

private struct MCPBigSignedInteger: Sendable, Equatable {
  /// Base-10 digits in least-significant-first order.
  private var digits: [UInt8]
  private var sign: Int

  static let zero = MCPBigSignedInteger(sign: 0, digits: [])

  init(sign: Int, decimalDigits: ArraySlice<UInt8>) {
    let parsed = decimalDigits.map { $0 - 0x30 }
    guard let firstNonzero = parsed.firstIndex(where: { $0 != 0 }) else {
      self = .zero
      return
    }
    self.sign = sign < 0 ? -1 : 1
    self.digits = parsed[firstNonzero...].reversed()
  }

  private init(sign: Int, digits: [UInt8]) {
    var normalized = digits
    while normalized.last == 0 { normalized.removeLast() }
    if normalized.isEmpty {
      self.sign = 0
      self.digits = []
    } else {
      self.sign = sign < 0 ? -1 : 1
      self.digits = normalized
    }
  }

  init(_ value: Int) {
    if value == 0 {
      self = .zero
      return
    }
    let negative = value < 0
    var magnitude = value.magnitude
    var digits: [UInt8] = []
    while magnitude > 0 {
      digits.append(UInt8(magnitude % 10))
      magnitude /= 10
    }
    self.init(sign: negative ? -1 : 1, digits: digits)
  }

  func adding(_ value: Int) -> MCPBigSignedInteger {
    adding(MCPBigSignedInteger(value))
  }

  func subtracting(_ other: MCPBigSignedInteger) -> MCPBigSignedInteger {
    adding(MCPBigSignedInteger(sign: -other.sign, digits: other.digits))
  }

  var exactIntValue: Int? {
    guard sign != 0 else { return 0 }
    var magnitude: UInt = 0
    for digit in digits.reversed() {
      let multiplied = magnitude.multipliedReportingOverflow(by: 10)
      guard !multiplied.overflow else { return nil }
      let added = multiplied.partialValue.addingReportingOverflow(UInt(digit))
      guard !added.overflow else { return nil }
      magnitude = added.partialValue
    }
    if sign > 0 {
      guard magnitude <= UInt(Int.max) else { return nil }
      return Int(magnitude)
    }
    let minimumMagnitude = UInt(Int.max) + 1
    if magnitude == minimumMagnitude { return Int.min }
    guard magnitude <= UInt(Int.max) else { return nil }
    return -Int(magnitude)
  }

  var semanticKey: String {
    guard sign != 0 else { return "0" }
    let magnitude = digits.reversed().map(String.init).joined()
    return sign < 0 ? "-\(magnitude)" : magnitude
  }

  func compare(to other: MCPBigSignedInteger) -> ComparisonResult {
    if sign != other.sign {
      return sign < other.sign ? .orderedAscending : .orderedDescending
    }
    guard sign != 0 else { return .orderedSame }
    let magnitude = Self.compareMagnitude(digits, other.digits)
    if sign > 0 { return magnitude }
    switch magnitude {
    case .orderedAscending: return .orderedDescending
    case .orderedDescending: return .orderedAscending
    case .orderedSame: return .orderedSame
    }
  }

  private func adding(_ other: MCPBigSignedInteger) -> MCPBigSignedInteger {
    if sign == 0 { return other }
    if other.sign == 0 { return self }
    if sign == other.sign {
      return MCPBigSignedInteger(sign: sign, digits: Self.addMagnitude(digits, other.digits))
    }
    switch Self.compareMagnitude(digits, other.digits) {
    case .orderedSame:
      return .zero
    case .orderedDescending:
      return MCPBigSignedInteger(sign: sign, digits: Self.subtractMagnitude(digits, other.digits))
    case .orderedAscending:
      return MCPBigSignedInteger(
        sign: other.sign,
        digits: Self.subtractMagnitude(other.digits, digits)
      )
    }
  }

  private static func compareMagnitude(_ lhs: [UInt8], _ rhs: [UInt8]) -> ComparisonResult {
    if lhs.count != rhs.count {
      return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }
    for index in lhs.indices.reversed() where lhs[index] != rhs[index] {
      return lhs[index] < rhs[index] ? .orderedAscending : .orderedDescending
    }
    return .orderedSame
  }

  private static func addMagnitude(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
    let count = max(lhs.count, rhs.count)
    var result: [UInt8] = []
    result.reserveCapacity(count + 1)
    var carry: UInt8 = 0
    for index in 0..<count {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      let sum = left + right + carry
      result.append(sum % 10)
      carry = sum / 10
    }
    if carry > 0 { result.append(carry) }
    return result
  }

  /// Subtracts rhs from lhs. The caller guarantees lhs >= rhs.
  private static func subtractMagnitude(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
    var result = lhs
    var borrow = 0
    for index in result.indices {
      let right = index < rhs.count ? Int(rhs[index]) : 0
      var value = Int(result[index]) - right - borrow
      if value < 0 {
        value += 10
        borrow = 1
      } else {
        borrow = 0
      }
      result[index] = UInt8(value)
    }
    while result.last == 0 { result.removeLast() }
    return result
  }
}

private struct MCPNormalizedDecimal: Sendable {
  private let sign: Int
  /// Significant base-10 digits in most-significant-first order, without
  /// leading or trailing zeroes. Zero is represented by an empty array.
  private let digits: [UInt8]
  /// The power of ten applied after the significant digits.
  private let exponent: MCPBigSignedInteger

  init(_ literal: String) {
    let bytes = Array(literal.utf8)
    var index = 0
    var sign = 1
    if bytes[index] == 0x2D {
      sign = -1
      index += 1
    }

    let exponentMarker = bytes[index...].firstIndex { $0 == 0x65 || $0 == 0x45 }
    let significandEnd = exponentMarker ?? bytes.endIndex
    let decimalPoint = bytes[index..<significandEnd].firstIndex(of: 0x2E)
    let fractionCount = decimalPoint.map { significandEnd - $0 - 1 } ?? 0

    var coefficient: [UInt8] = []
    coefficient.reserveCapacity(significandEnd - index)
    for byte in bytes[index..<significandEnd] where byte != 0x2E {
      coefficient.append(byte - 0x30)
    }
    if let firstNonzero = coefficient.firstIndex(where: { $0 != 0 }) {
      if firstNonzero > coefficient.startIndex {
        coefficient.removeFirst(firstNonzero)
      }
    } else {
      self.sign = 0
      self.digits = []
      self.exponent = .zero
      return
    }

    var trailingZeroes = 0
    while coefficient.last == 0 {
      coefficient.removeLast()
      trailingZeroes += 1
    }

    let explicitExponent: MCPBigSignedInteger
    if let marker = exponentMarker {
      var exponentIndex = marker + 1
      var exponentSign = 1
      if bytes[exponentIndex] == 0x2B {
        exponentIndex += 1
      } else if bytes[exponentIndex] == 0x2D {
        exponentSign = -1
        exponentIndex += 1
      }
      explicitExponent = MCPBigSignedInteger(
        sign: exponentSign,
        decimalDigits: bytes[exponentIndex...]
      )
    } else {
      explicitExponent = .zero
    }

    self.sign = sign
    self.digits = coefficient
    self.exponent = explicitExponent.adding(trailingZeroes - fractionCount)
  }

  var isMathematicalInteger: Bool {
    sign == 0 || exponent.compare(to: .zero) != .orderedAscending
  }

  var exactIntValue: Int? {
    guard sign != 0 else { return 0 }
    guard let power = exponent.exactIntValue, power >= 0 else { return nil }
    var magnitude: UInt = 0
    for digit in digits {
      let multiplied = magnitude.multipliedReportingOverflow(by: 10)
      guard !multiplied.overflow else { return nil }
      let added = multiplied.partialValue.addingReportingOverflow(UInt(digit))
      guard !added.overflow else { return nil }
      magnitude = added.partialValue
    }
    for _ in 0..<power {
      let multiplied = magnitude.multipliedReportingOverflow(by: 10)
      guard !multiplied.overflow else { return nil }
      magnitude = multiplied.partialValue
    }
    if sign > 0 {
      guard magnitude <= UInt(Int.max) else { return nil }
      return Int(magnitude)
    }
    let minimumMagnitude = UInt(Int.max) + 1
    if magnitude == minimumMagnitude { return Int.min }
    guard magnitude <= UInt(Int.max) else { return nil }
    return -Int(magnitude)
  }

  var semanticKey: String {
    guard sign != 0 else { return "0e0" }
    return "\(sign < 0 ? "-" : "+")\(digits.map(String.init).joined())e\(exponent.semanticKey)"
  }

  func isMultiple(
    of divisor: MCPNormalizedDecimal,
    maximumPowerExpansion: Int
  ) -> Bool? {
    guard divisor.sign != 0 else { return false }
    guard sign != 0 else { return true }
    let powerDifference = exponent.subtracting(divisor.exponent)
    guard let power = powerDifference.exactIntValue,
      power >= -maximumPowerExpansion,
      power <= maximumPowerExpansion
    else { return nil }

    var numerator = digits
    var denominator = divisor.digits
    if power >= 0 {
      numerator.append(contentsOf: repeatElement(0, count: power))
    } else {
      denominator.append(contentsOf: repeatElement(0, count: -power))
    }
    guard let remainder = Self.decimalRemainder(numerator, dividedBy: denominator) else {
      return false
    }
    return remainder.allSatisfy { $0 == 0 }
  }

  func compare(to other: MCPNormalizedDecimal) -> ComparisonResult {
    if sign != other.sign {
      return sign < other.sign ? .orderedAscending : .orderedDescending
    }
    guard sign != 0 else { return .orderedSame }

    let leftOrder = exponent.adding(digits.count - 1)
    let rightOrder = other.exponent.adding(other.digits.count - 1)
    let orderComparison = leftOrder.compare(to: rightOrder)
    if orderComparison != .orderedSame {
      return sign > 0 ? orderComparison : Self.reversed(orderComparison)
    }

    let length = max(digits.count, other.digits.count)
    for index in 0..<length {
      let left = index < digits.count ? digits[index] : 0
      let right = index < other.digits.count ? other.digits[index] : 0
      if left != right {
        let comparison: ComparisonResult = left < right ? .orderedAscending : .orderedDescending
        return sign > 0 ? comparison : Self.reversed(comparison)
      }
    }
    return .orderedSame
  }

  private static func decimalRemainder(
    _ numerator: [UInt8],
    dividedBy denominator: [UInt8]
  ) -> [UInt8]? {
    guard !denominator.isEmpty, denominator.contains(where: { $0 != 0 }) else {
      return nil
    }
    var remainder: [UInt8] = []
    remainder.reserveCapacity(denominator.count)
    for digit in numerator {
      if !remainder.isEmpty || digit != 0 { remainder.append(digit) }
      while compareMagnitude(remainder, denominator) != .orderedAscending {
        remainder = subtractMagnitude(remainder, denominator)
      }
    }
    return remainder
  }

  private static func compareMagnitude(_ lhs: [UInt8], _ rhs: [UInt8]) -> ComparisonResult {
    let leftStart = lhs.firstIndex(where: { $0 != 0 }) ?? lhs.endIndex
    let rightStart = rhs.firstIndex(where: { $0 != 0 }) ?? rhs.endIndex
    let leftCount = lhs.distance(from: leftStart, to: lhs.endIndex)
    let rightCount = rhs.distance(from: rightStart, to: rhs.endIndex)
    if leftCount != rightCount {
      return leftCount < rightCount ? .orderedAscending : .orderedDescending
    }
    for offset in 0..<leftCount {
      let left = lhs[leftStart + offset]
      let right = rhs[rightStart + offset]
      if left != right { return left < right ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
  }

  /// Subtracts rhs from lhs. The caller guarantees lhs >= rhs. Digits are MSF.
  private static func subtractMagnitude(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
    var result = lhs
    var leftIndex = result.count - 1
    var rightIndex = rhs.count - 1
    var borrow = 0
    while true {
      let right = rightIndex >= 0 ? Int(rhs[rightIndex]) : 0
      var value = Int(result[leftIndex]) - right - borrow
      if value < 0 {
        value += 10
        borrow = 1
      } else {
        borrow = 0
      }
      result[leftIndex] = UInt8(value)
      if leftIndex == 0 { break }
      leftIndex -= 1
      rightIndex -= 1
    }
    let first = result.firstIndex(where: { $0 != 0 }) ?? result.endIndex
    return Array(result[first...])
  }

  private static func reversed(_ value: ComparisonResult) -> ComparisonResult {
    switch value {
    case .orderedAscending: .orderedDescending
    case .orderedDescending: .orderedAscending
    case .orderedSame: .orderedSame
    }
  }
}

public enum MCPJSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(MCPJSONNumber)
  case string(String)
  case array([MCPJSONValue])
  case object([String: MCPJSONValue])

  public static func integer(_ value: Int) -> MCPJSONValue { .number(MCPJSONNumber(value)) }
  public static func integer(_ value: Int64) -> MCPJSONValue { .number(MCPJSONNumber(value)) }
  public static func unsignedInteger(_ value: UInt64) -> MCPJSONValue {
    .number(MCPJSONNumber(value))
  }
  public static func double(_ value: Double) throws -> MCPJSONValue {
    .number(try MCPJSONNumber(value))
  }

  public var objectValue: [String: MCPJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }
  public var arrayValue: [MCPJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }
  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }
  public var numberValue: MCPJSONNumber? {
    guard case .number(let value) = self else { return nil }
    return value
  }

  public static func parse(_ data: Data, limits: MCPJSONLimits = .default) throws -> MCPJSONValue {
    try limits.validate()
    guard data.count <= limits.maximumDocumentBytes else {
      throw MCPJSONError.documentTooLarge(limit: limits.maximumDocumentBytes)
    }
    var parser = MCPJSONParser(bytes: Array(data), limits: limits)
    return try parser.parse()
  }

  public static func parse(_ text: String, limits: MCPJSONLimits = .default) throws -> MCPJSONValue
  {
    try parse(Data(text.utf8), limits: limits)
  }

  public func encoded(limits: MCPJSONLimits = .default) throws -> Data {
    try limits.validate()
    var output: [UInt8] = []
    output.reserveCapacity(256)
    try MCPJSONEncoder.encode(self, into: &output, depth: 0, limits: limits)
    guard output.count <= limits.maximumDocumentBytes else {
      throw MCPJSONError.documentTooLarge(limit: limits.maximumDocumentBytes)
    }
    return Data(output)
  }
}

public protocol MCPJSONModel: Sendable {
  init(json: MCPJSONValue) throws
  var json: MCPJSONValue { get }
}

public struct MCPJSONObject: Sendable {
  public let values: [String: MCPJSONValue]

  public init(_ json: MCPJSONValue) throws {
    guard case .object(let values) = json else { throw MCPJSONError.expectedObject }
    self.values = values
  }

  public func requiredString(_ key: String) throws -> String {
    guard let value = values[key] else { throw MCPJSONError.missingField(key) }
    guard case .string(let string) = value else { throw MCPJSONError.expectedString(field: key) }
    return string
  }

  public func requiredNonEmptyString(_ key: String) throws -> String {
    let value = try requiredString(key)
    guard !value.isEmpty else {
      throw MCPJSONError.invalidField(field: key, reason: "must not be empty")
    }
    return value
  }

  public func optionalString(_ key: String) throws -> String? {
    guard let value = values[key] else { return nil }
    guard case .string(let string) = value else { throw MCPJSONError.expectedString(field: key) }
    return string
  }

  public func requiredBool(_ key: String) throws -> Bool {
    guard let value = values[key] else { throw MCPJSONError.missingField(key) }
    guard case .bool(let bool) = value else { throw MCPJSONError.expectedBool(field: key) }
    return bool
  }

  public func optionalBool(_ key: String) throws -> Bool? {
    guard let value = values[key] else { return nil }
    guard case .bool(let bool) = value else { throw MCPJSONError.expectedBool(field: key) }
    return bool
  }

  public func requiredArray(_ key: String) throws -> [MCPJSONValue] {
    guard let value = values[key] else { throw MCPJSONError.missingField(key) }
    guard case .array(let array) = value else { throw MCPJSONError.expectedArray(field: key) }
    return array
  }

  public func optionalArray(_ key: String) throws -> [MCPJSONValue]? {
    guard let value = values[key] else { return nil }
    guard case .array(let array) = value else { throw MCPJSONError.expectedArray(field: key) }
    return array
  }

  public func requiredObject(_ key: String) throws -> [String: MCPJSONValue] {
    guard let value = values[key] else { throw MCPJSONError.missingField(key) }
    guard case .object(let object) = value else {
      throw MCPJSONError.invalidField(field: key, reason: "expected object")
    }
    return object
  }

  public func optionalObject(_ key: String) throws -> [String: MCPJSONValue]? {
    guard let value = values[key] else { return nil }
    guard case .object(let object) = value else {
      throw MCPJSONError.invalidField(field: key, reason: "expected object")
    }
    return object
  }

  public func requiredInteger(_ key: String) throws -> Int64 {
    guard let value = values[key] else { throw MCPJSONError.missingField(key) }
    guard case .number(let number) = value, number.isInteger, let integer = number.int64Value else {
      throw MCPJSONError.expectedInteger(field: key)
    }
    return integer
  }

  public func optionalInteger(_ key: String) throws -> Int64? {
    guard let value = values[key] else { return nil }
    guard case .number(let number) = value, number.isInteger, let integer = number.int64Value else {
      throw MCPJSONError.expectedInteger(field: key)
    }
    return integer
  }

  public func requiredNumber(_ key: String) throws -> MCPJSONNumber {
    guard let value = values[key] else { throw MCPJSONError.missingField(key) }
    guard case .number(let number) = value else { throw MCPJSONError.expectedNumber(field: key) }
    return number
  }

  public func optionalNumber(_ key: String) throws -> MCPJSONNumber? {
    guard let value = values[key] else { return nil }
    guard case .number(let number) = value else { throw MCPJSONError.expectedNumber(field: key) }
    return number
  }
}

@inline(__always)
public func mcpObject(_ fields: [(String, MCPJSONValue?)]) -> MCPJSONValue {
  var object: [String: MCPJSONValue] = [:]
  object.reserveCapacity(fields.count)
  for (key, value) in fields {
    if let value { object[key] = value }
  }
  return .object(object)
}

@inline(__always)
public func mcpStringArray(_ values: [String]) -> MCPJSONValue {
  .array(values.map(MCPJSONValue.string))
}

private struct MCPJSONParser {
  let bytes: [UInt8]
  let limits: MCPJSONLimits
  var index = 0

  mutating func parse() throws -> MCPJSONValue {
    skipWhitespace()
    let value = try parseValue(depth: 0)
    skipWhitespace()
    guard index == bytes.count else { throw MCPJSONError.trailingData(offset: index) }
    return value
  }

  mutating func parseValue(depth: Int) throws -> MCPJSONValue {
    guard depth <= limits.maximumDepth else {
      throw MCPJSONError.depthExceeded(limit: limits.maximumDepth)
    }
    guard index < bytes.count else { throw MCPJSONError.unexpectedEnd }
    switch bytes[index] {
    case 0x6E:
      try consumeLiteral("null")
      return .null
    case 0x74:
      try consumeLiteral("true")
      return .bool(true)
    case 0x66:
      try consumeLiteral("false")
      return .bool(false)
    case 0x22: return .string(try parseString())
    case 0x5B: return try parseArray(depth: depth + 1)
    case 0x7B: return try parseObject(depth: depth + 1)
    case 0x2D, 0x30...0x39: return .number(try parseNumber())
    default: throw MCPJSONError.unexpectedByte(bytes[index], offset: index)
    }
  }

  mutating func parseArray(depth: Int) throws -> MCPJSONValue {
    index += 1
    skipWhitespace()
    var result: [MCPJSONValue] = []
    if consumeIf(0x5D) { return .array(result) }
    while true {
      guard result.count < limits.maximumContainerElements else {
        throw MCPJSONError.containerTooLarge(limit: limits.maximumContainerElements)
      }
      result.append(try parseValue(depth: depth))
      skipWhitespace()
      if consumeIf(0x5D) { return .array(result) }
      guard consumeIf(0x2C) else {
        if index >= bytes.count { throw MCPJSONError.unexpectedEnd }
        throw MCPJSONError.unexpectedByte(bytes[index], offset: index)
      }
      skipWhitespace()
    }
  }

  mutating func parseObject(depth: Int) throws -> MCPJSONValue {
    index += 1
    skipWhitespace()
    var result: [String: MCPJSONValue] = [:]
    if consumeIf(0x7D) { return .object(result) }
    while true {
      guard result.count < limits.maximumContainerElements else {
        throw MCPJSONError.containerTooLarge(limit: limits.maximumContainerElements)
      }
      guard index < bytes.count, bytes[index] == 0x22 else {
        if index >= bytes.count { throw MCPJSONError.unexpectedEnd }
        throw MCPJSONError.unexpectedByte(bytes[index], offset: index)
      }
      let key = try parseString()
      guard result[key] == nil else { throw MCPJSONError.duplicateKey(key) }
      skipWhitespace()
      guard consumeIf(0x3A) else {
        if index >= bytes.count { throw MCPJSONError.unexpectedEnd }
        throw MCPJSONError.unexpectedByte(bytes[index], offset: index)
      }
      skipWhitespace()
      result[key] = try parseValue(depth: depth)
      skipWhitespace()
      if consumeIf(0x7D) { return .object(result) }
      guard consumeIf(0x2C) else {
        if index >= bytes.count { throw MCPJSONError.unexpectedEnd }
        throw MCPJSONError.unexpectedByte(bytes[index], offset: index)
      }
      skipWhitespace()
    }
  }

  mutating func parseString() throws -> String {
    index += 1
    var scalars = String.UnicodeScalarView()
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 0x22 {
        index += 1
        let value = String(scalars)
        guard value.utf8.count <= limits.maximumStringBytes else {
          throw MCPJSONError.stringTooLarge(limit: limits.maximumStringBytes)
        }
        return value
      }
      if byte == 0x5C {
        index += 1
        guard index < bytes.count else { throw MCPJSONError.unexpectedEnd }
        let escaped = bytes[index]
        index += 1
        switch escaped {
        case 0x22: scalars.append("\"")
        case 0x5C: scalars.append("\\")
        case 0x2F: scalars.append("/")
        case 0x62: scalars.append("\u{0008}")
        case 0x66: scalars.append("\u{000C}")
        case 0x6E: scalars.append("\n")
        case 0x72: scalars.append("\r")
        case 0x74: scalars.append("\t")
        case 0x75:
          let firstOffset = index - 2
          let first = try parseHexQuad()
          if (0xD800...0xDBFF).contains(first) {
            guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
              throw MCPJSONError.unpairedSurrogate(offset: firstOffset)
            }
            index += 2
            let second = try parseHexQuad()
            guard (0xDC00...0xDFFF).contains(second) else {
              throw MCPJSONError.unpairedSurrogate(offset: index - 4)
            }
            let code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let scalar = UnicodeScalar(code) else {
              throw MCPJSONError.invalidUnicodeEscape(offset: firstOffset)
            }
            scalars.append(scalar)
          } else if (0xDC00...0xDFFF).contains(first) {
            throw MCPJSONError.unpairedSurrogate(offset: firstOffset)
          } else if let scalar = UnicodeScalar(first) {
            scalars.append(scalar)
          } else {
            throw MCPJSONError.invalidUnicodeEscape(offset: firstOffset)
          }
        default: throw MCPJSONError.invalidEscape(offset: index - 1)
        }
        continue
      }
      guard byte >= 0x20 else { throw MCPJSONError.invalidUTF8(offset: index) }
      let start = index
      let length: Int
      switch byte {
      case 0x00...0x7F: length = 1
      case 0xC2...0xDF: length = 2
      case 0xE0...0xEF: length = 3
      case 0xF0...0xF4: length = 4
      default: throw MCPJSONError.invalidUTF8(offset: index)
      }
      guard index + length <= bytes.count else { throw MCPJSONError.invalidUTF8(offset: index) }
      let chunk = Array(bytes[index..<(index + length)])
      guard let text = String(bytes: chunk, encoding: .utf8), text.unicodeScalars.count == 1,
        let scalar = text.unicodeScalars.first
      else { throw MCPJSONError.invalidUTF8(offset: start) }
      scalars.append(scalar)
      index += length
    }
    throw MCPJSONError.unexpectedEnd
  }

  mutating func parseHexQuad() throws -> UInt32 {
    guard index + 4 <= bytes.count else { throw MCPJSONError.unexpectedEnd }
    let offset = index
    var value: UInt32 = 0
    for _ in 0..<4 {
      let byte = bytes[index]
      index += 1
      let digit: UInt32
      switch byte {
      case 0x30...0x39: digit = UInt32(byte - 0x30)
      case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
      case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
      default: throw MCPJSONError.invalidUnicodeEscape(offset: offset)
      }
      value = (value << 4) | digit
    }
    return value
  }

  mutating func parseNumber() throws -> MCPJSONNumber {
    let start = index
    if consumeIf(0x2D), index >= bytes.count { throw MCPJSONError.invalidNumber(offset: start) }
    guard index < bytes.count else { throw MCPJSONError.invalidNumber(offset: start) }
    if bytes[index] == 0x30 {
      index += 1
      if index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
        throw MCPJSONError.invalidNumber(offset: start)
      }
    } else {
      guard bytes[index] >= 0x31, bytes[index] <= 0x39 else {
        throw MCPJSONError.invalidNumber(offset: start)
      }
      index += 1
      while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
    }
    if index < bytes.count, bytes[index] == 0x2E {
      index += 1
      guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else {
        throw MCPJSONError.invalidNumber(offset: start)
      }
      while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
    }
    if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
      index += 1
      if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
      guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else {
        throw MCPJSONError.invalidNumber(offset: start)
      }
      while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
    }
    let length = index - start
    guard length <= limits.maximumNumberBytes else {
      throw MCPJSONError.numberTooLarge(limit: limits.maximumNumberBytes)
    }
    let text = String(decoding: bytes[start..<index], as: UTF8.self)
    return try MCPJSONNumber(rawValue: text)
  }

  mutating func consumeLiteral(_ literal: StaticString) throws {
    let expected = Array(String(describing: literal).utf8)
    guard index + expected.count <= bytes.count else { throw MCPJSONError.unexpectedEnd }
    for byte in expected {
      guard bytes[index] == byte else {
        throw MCPJSONError.unexpectedByte(bytes[index], offset: index)
      }
      index += 1
    }
  }

  mutating func skipWhitespace() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x20, 0x09, 0x0A, 0x0D: index += 1
      default: return
      }
    }
  }

  mutating func consumeIf(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }
}

private enum MCPJSONEncoder {
  // Encoding can run inside a transport task. Periodic checks keep cancellation bounded for
  // large strings without adding a check for every emitted byte.
  static func encode(
    _ value: MCPJSONValue,
    into output: inout [UInt8],
    depth: Int,
    limits: MCPJSONLimits
  ) throws {
    try Task.checkCancellation()
    guard depth <= limits.maximumDepth else {
      throw MCPJSONError.depthExceeded(limit: limits.maximumDepth)
    }
    switch value {
    case .null: output += [0x6E, 0x75, 0x6C, 0x6C]
    case .bool(true): output += [0x74, 0x72, 0x75, 0x65]
    case .bool(false): output += [0x66, 0x61, 0x6C, 0x73, 0x65]
    case .number(let number):
      let bytes = Array(number.rawValue.utf8)
      guard bytes.count <= limits.maximumNumberBytes else {
        throw MCPJSONError.numberTooLarge(limit: limits.maximumNumberBytes)
      }
      output += bytes
    case .string(let string): try encodeString(string, into: &output, limits: limits)
    case .array(let values):
      guard values.count <= limits.maximumContainerElements else {
        throw MCPJSONError.containerTooLarge(limit: limits.maximumContainerElements)
      }
      output.append(0x5B)
      for index in values.indices {
        if index > values.startIndex { output.append(0x2C) }
        try encode(values[index], into: &output, depth: depth + 1, limits: limits)
      }
      output.append(0x5D)
    case .object(let object):
      guard object.count <= limits.maximumContainerElements else {
        throw MCPJSONError.containerTooLarge(limit: limits.maximumContainerElements)
      }
      output.append(0x7B)
      let keys = object.keys.sorted()
      for index in keys.indices {
        if index > keys.startIndex { output.append(0x2C) }
        let key = keys[index]
        try encodeString(key, into: &output, limits: limits)
        output.append(0x3A)
        guard let child = object[key] else {
          throw MCPJSONError.invalidField(field: key, reason: "dictionary changed during encoding")
        }
        try encode(child, into: &output, depth: depth + 1, limits: limits)
      }
      output.append(0x7D)
    }
  }

  static func encodeString(_ string: String, into output: inout [UInt8], limits: MCPJSONLimits)
    throws
  {
    let utf8Count = string.utf8.count
    try Task.checkCancellation()
    guard utf8Count <= limits.maximumStringBytes else {
      throw MCPJSONError.stringTooLarge(limit: limits.maximumStringBytes)
    }
    output.append(0x22)
    var scalarIndex = 0
    for scalar in string.unicodeScalars {
      if scalarIndex & 0x0FFF == 0 { try Task.checkCancellation() }
      scalarIndex += 1
      switch scalar.value {
      case 0x22: output += [0x5C, 0x22]
      case 0x5C: output += [0x5C, 0x5C]
      case 0x08: output += [0x5C, 0x62]
      case 0x0C: output += [0x5C, 0x66]
      case 0x0A: output += [0x5C, 0x6E]
      case 0x0D: output += [0x5C, 0x72]
      case 0x09: output += [0x5C, 0x74]
      case 0x00...0x1F:
        let text = String(format: "\\u%04X", scalar.value)
        output += text.utf8
      default: output += String(scalar).utf8
      }
    }
    output.append(0x22)
  }
}
