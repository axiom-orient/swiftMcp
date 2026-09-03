import Foundation

/// Resource bounds for schema compilation and instance validation.
public struct MCPJSONSchemaLimits: Sendable, Hashable {
  public var maximumSchemaDepth: Int
  public var maximumInstanceDepth: Int
  public var maximumEvaluations: Int
  public var maximumIssues: Int
  public var maximumRegexBytes: Int
  public var maximumRegexInputBytes: Int
  public var maximumUniqueItems: Int
  public var maximumPowerExpansion: Int

  public init(
    maximumSchemaDepth: Int = 128,
    maximumInstanceDepth: Int = 128,
    maximumEvaluations: Int = 100_000,
    maximumIssues: Int = 128,
    maximumRegexBytes: Int = 64 * 1024,
    maximumRegexInputBytes: Int = 64 * 1024,
    maximumUniqueItems: Int = 100_000,
    maximumPowerExpansion: Int = 4_096
  ) {
    self.maximumSchemaDepth = maximumSchemaDepth
    self.maximumInstanceDepth = maximumInstanceDepth
    self.maximumEvaluations = maximumEvaluations
    self.maximumIssues = maximumIssues
    self.maximumRegexBytes = maximumRegexBytes
    self.maximumRegexInputBytes = maximumRegexInputBytes
    self.maximumUniqueItems = maximumUniqueItems
    self.maximumPowerExpansion = maximumPowerExpansion
  }

  public static let `default` = MCPJSONSchemaLimits()

  fileprivate func validate() throws {
    guard maximumSchemaDepth > 0 else {
      throw MCPJSONSchemaError.invalidLimit("maximumSchemaDepth")
    }
    guard maximumInstanceDepth > 0 else {
      throw MCPJSONSchemaError.invalidLimit("maximumInstanceDepth")
    }
    guard maximumEvaluations > 0 else {
      throw MCPJSONSchemaError.invalidLimit("maximumEvaluations")
    }
    guard maximumIssues > 0 else { throw MCPJSONSchemaError.invalidLimit("maximumIssues") }
    guard maximumRegexBytes > 0 else { throw MCPJSONSchemaError.invalidLimit("maximumRegexBytes") }
    guard maximumRegexInputBytes > 0 else {
      throw MCPJSONSchemaError.invalidLimit("maximumRegexInputBytes")
    }
    guard maximumUniqueItems > 0 else {
      throw MCPJSONSchemaError.invalidLimit("maximumUniqueItems")
    }
    guard maximumPowerExpansion > 0 else {
      throw MCPJSONSchemaError.invalidLimit("maximumPowerExpansion")
    }
  }
}

public struct MCPJSONSchemaIssue: Sendable, Hashable, CustomStringConvertible {
  public let keyword: String
  public let instanceLocation: String
  public let schemaLocation: String
  public let message: String

  public init(
    keyword: String,
    instanceLocation: String,
    schemaLocation: String,
    message: String
  ) {
    self.keyword = keyword
    self.instanceLocation = instanceLocation
    self.schemaLocation = schemaLocation
    self.message = message
  }

  public var description: String {
    "\(instanceLocation): \(message) [\(keyword) at \(schemaLocation)]"
  }
}

public enum MCPJSONSchemaError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidLimit(String)
  case invalidSchema([MCPJSONSchemaIssue])
  case validationFailed([MCPJSONSchemaIssue])
  case resourceLimit(String)

  public var description: String {
    switch self {
    case .invalidLimit(let name):
      "Invalid JSON Schema limit: \(name)"
    case .invalidSchema(let issues):
      "Invalid JSON Schema: \(issues.map(\.description).joined(separator: "; "))"
    case .validationFailed(let issues):
      "JSON Schema validation failed: \(issues.map(\.description).joined(separator: "; "))"
    case .resourceLimit(let reason):
      "JSON Schema resource limit exceeded: \(reason)"
    }
  }
}

/// An immutable, reusable validation plan produced by a schema compiler.
///
/// Tool catalogs keep these plans instead of recompiling the same schema for every call. Plans must
/// be safe to invoke concurrently; one validation must not retain mutable state for the next.
public protocol MCPJSONSchemaValidationPlan: Sendable {
  func validate(_ instance: MCPJSONValue) throws
}

/// A replaceable schema compilation boundary. Hosts may provide a third-party implementation when
/// they need remote reference resolution, custom formats, or a dialect outside this package's
/// built-in self-contained 2020-12 and draft-07 profile.
public protocol MCPJSONSchemaValidating: Sendable {
  func compile(_ schema: MCPJSONValue) throws -> any MCPJSONSchemaValidationPlan
}

extension MCPJSONSchemaValidating {
  public func validateSchema(_ schema: MCPJSONValue) throws {
    _ = try compile(schema)
  }

  public func validate(_ instance: MCPJSONValue, against schema: MCPJSONValue) throws {
    try compile(schema).validate(instance)
  }
}

/// Accepts a JSON Schema document without interpreting its validation vocabulary.
///
/// MCP tool schemas are protocol payloads, not a mandate that an SDK implement every JSON Schema
/// dialect or reference retrieval strategy. Use this validator only when the host deliberately
/// accepts schemas without local validation. It is never the runtime default.
public struct MCPOpaqueJSONSchemaValidator: MCPJSONSchemaValidating, Sendable {
  public init() {}

  public func compile(_ schema: MCPJSONValue) throws -> any MCPJSONSchemaValidationPlan {
    guard schema.isSchema else {
      throw MCPJSONSchemaError.invalidSchema([
        MCPJSONSchemaIssue(
          keyword: "schema",
          instanceLocation: "#",
          schemaLocation: "#",
          message: "schema must be an object or boolean"
        )
      ])
    }
    return MCPOpaqueJSONSchemaValidationPlan()
  }
}

private struct MCPOpaqueJSONSchemaValidationPlan: MCPJSONSchemaValidationPlan, Sendable {
  func validate(_ instance: MCPJSONValue) throws {}
}

/// Uses the built-in validator where its self-contained profile applies, while preserving tool
/// schemas that require a host-provided dialect or external-reference resolver.
///
/// This is the runtime interoperability default. It continues to validate supported schemas, but
/// treats a schema with an unsupported dialect or external reference as an opaque MCP payload.
/// No network retrieval is performed, so advertising a valid externally-referenced schema never
/// becomes an implicit network or SSRF boundary.
public struct MCPInteroperableJSONSchemaValidator: MCPJSONSchemaValidating, Sendable {
  private let builtIn: MCPJSONSchemaValidator

  public init(limits: MCPJSONSchemaLimits = .default) {
    builtIn = MCPJSONSchemaValidator(limits: limits)
  }

  public func compile(_ schema: MCPJSONValue) throws -> any MCPJSONSchemaValidationPlan {
    do {
      return try builtIn.compile(schema)
    } catch let error as MCPJSONSchemaError {
      guard Self.requiresHostValidator(error) else { throw error }
      return try MCPOpaqueJSONSchemaValidator().compile(schema)
    }
  }

  private static func requiresHostValidator(_ error: MCPJSONSchemaError) -> Bool {
    guard case .invalidSchema(let issues) = error, !issues.isEmpty else { return false }
    return issues.allSatisfy { issue in
      issue.message.contains("requires a custom schema validator")
        || issue.message.contains("unsupported JSON Schema dialect")
    }
  }
}

/// Validates self-contained JSON Schema 2020-12 and draft-07 documents without network I/O.
///
/// Fragment JSON Pointers, local anchors, and self-contained 2020-12 dynamic references are
/// supported. External references are rejected rather than fetched implicitly, preventing schema
/// validation from becoming an SSRF or unbounded network boundary. A host that needs external
/// retrieval or a dialect outside this profile can inject a different
/// `MCPJSONSchemaValidating` implementation.
///
/// Since `compile(_:)` has no retrieval URL, a relative root `$id` is resolved against the stable,
/// non-retrievable synthetic base `https://mcp.invalid/json-schema/`. The synthetic base is used
/// only for deterministic reference identity and never enables network access.
public struct MCPJSONSchemaValidator: MCPJSONSchemaValidating, Sendable {
  public let limits: MCPJSONSchemaLimits

  public init(limits: MCPJSONSchemaLimits = .default) {
    self.limits = limits
  }

  public func compile(_ schema: MCPJSONValue) throws -> any MCPJSONSchemaValidationPlan {
    try limits.validate()
    return try MCPBuiltInJSONSchemaValidationPlan(
      compiled: MCPCompiledJSONSchema(root: schema, limits: limits),
      limits: limits
    )
  }
}

private struct MCPBuiltInJSONSchemaValidationPlan: MCPJSONSchemaValidationPlan, Sendable {
  let compiled: MCPCompiledJSONSchema
  let limits: MCPJSONSchemaLimits

  func validate(_ instance: MCPJSONValue) throws {
    var evaluator = MCPJSONSchemaEvaluator(compiled: compiled, limits: limits)
    let result = try evaluator.evaluate(
      schema: compiled.root,
      schemaLocation: "#",
      instance: instance,
      instanceLocation: "#",
      depth: 0
    )
    guard result.valid else {
      throw MCPJSONSchemaError.validationFailed(result.issues)
    }
  }
}

private enum MCPJSONSchemaDialect: Sendable {
  case draft202012
  case draft7

  static func detect(from schema: MCPJSONValue) throws -> MCPJSONSchemaDialect {
    guard case .object(let object) = schema, let declared = object["$schema"] else {
      return .draft202012
    }
    guard case .string(let identifier) = declared else {
      throw MCPJSONSchemaError.invalidSchema([
        MCPJSONSchemaIssue(
          keyword: "$schema",
          instanceLocation: "#",
          schemaLocation: "#/$schema",
          message: "expected string"
        )
      ])
    }

    switch identifier {
    case "https://json-schema.org/draft/2020-12/schema",
      "https://json-schema.org/draft/2020-12/schema#":
      return .draft202012
    case "http://json-schema.org/draft-07/schema#",
      "https://json-schema.org/draft-07/schema#":
      return .draft7
    default:
      throw MCPJSONSchemaError.invalidSchema([
        MCPJSONSchemaIssue(
          keyword: "$schema",
          instanceLocation: "#",
          schemaLocation: "#/$schema",
          message: "unsupported JSON Schema dialect \(identifier)"
        )
      ])
    }
  }
}

private struct MCPResolvedJSONSchema: Sendable {
  let value: MCPJSONValue
  let location: String
  let resourceIdentifier: String
}

private struct MCPCompiledJSONSchema: Sendable {
  let root: MCPJSONValue
  let dialect: MCPJSONSchemaDialect
  let anchors: [String: MCPResolvedJSONSchema]
  let dynamicAnchors: [String: MCPResolvedJSONSchema]
  let identifiers: [String: MCPResolvedJSONSchema]
  let rootIdentifier: String
  let regularExpressions: [String: NSRegularExpression]

  init(root: MCPJSONValue, limits: MCPJSONSchemaLimits) throws {
    guard root.isSchema else {
      throw MCPJSONSchemaError.invalidSchema([
        MCPJSONSchemaIssue(
          keyword: "schema",
          instanceLocation: "#",
          schemaLocation: "#",
          message: "schema must be an object or boolean"
        )
      ])
    }
    let dialect = try MCPJSONSchemaDialect.detect(from: root)
    var compiler = MCPJSONSchemaCompiler(root: root, dialect: dialect, limits: limits)
    try compiler.compile()
    if !compiler.issues.isEmpty {
      throw MCPJSONSchemaError.invalidSchema(compiler.issues)
    }
    self.root = root
    self.dialect = dialect
    self.anchors = compiler.anchors
    self.dynamicAnchors = compiler.dynamicAnchors
    self.identifiers = compiler.identifiers
    self.rootIdentifier = compiler.rootIdentifier
    self.regularExpressions = compiler.regularExpressions
  }

  func regularExpression(at location: String) throws -> NSRegularExpression {
    guard let expression = regularExpressions[location] else {
      throw MCPJSONSchemaError.invalidSchema([
        MCPJSONSchemaIssue(
          keyword: "pattern",
          instanceLocation: "#",
          schemaLocation: location,
          message: "compiled regular expression is missing"
        )
      ])
    }
    return expression
  }

  func resolve(reference: String, from resourceIdentifier: String) throws -> MCPResolvedJSONSchema {
    guard let source = identifiers[resourceIdentifier] else { throw externalReference(reference) }
    if reference.isEmpty || reference == "#" { return source }

    guard let base = URL(string: resourceIdentifier),
      let resolvedURL = URL(string: reference, relativeTo: base)?.absoluteURL
    else { throw externalReference(reference) }
    var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)
    let fragment = components?.fragment
    components?.fragment = nil
    let targetIdentifier = components?.url?.absoluteString ?? resolvedURL.absoluteString
    guard let target = identifiers[targetIdentifier] else { throw externalReference(reference) }
    guard let fragment, !fragment.isEmpty else { return target }
    if fragment.hasPrefix("/") {
      guard let value = target.value.value(atJSONPointer: fragment) else {
        throw unresolved(reference)
      }
      return MCPResolvedJSONSchema(
        value: value,
        location: target.location + fragment,
        resourceIdentifier: target.resourceIdentifier
      )
    }
    guard
      let anchored = anchors[Self.anchorKey(resourceIdentifier: targetIdentifier, anchor: fragment)]
    else { throw unresolved(reference) }
    return anchored
  }

  func resolveDynamic(reference: String, from resourceIdentifier: String, scope: [String]) throws
    -> MCPResolvedJSONSchema
  {
    let staticallyResolved = try resolve(reference: reference, from: resourceIdentifier)
    guard let anchor = Self.plainNameFragment(in: reference),
      dynamicAnchors[
        Self.anchorKey(
          resourceIdentifier: staticallyResolved.resourceIdentifier,
          anchor: anchor
        )
      ] != nil
    else { return staticallyResolved }
    for identifier in scope {
      if let dynamic = dynamicAnchors[
        Self.anchorKey(resourceIdentifier: identifier, anchor: anchor)]
      {
        return dynamic
      }
    }
    return staticallyResolved
  }

  func resourceIdentifier(for schemaLocation: String) -> String {
    identifiers.values
      .filter { schemaLocation == $0.location || schemaLocation.hasPrefix($0.location + "/") }
      .max { $0.location.count < $1.location.count }?
      .resourceIdentifier ?? rootIdentifier
  }

  static func anchorKey(resourceIdentifier: String, anchor: String) -> String {
    resourceIdentifier + "#" + anchor
  }

  private static func plainNameFragment(in reference: String) -> String? {
    guard let hash = reference.lastIndex(of: "#") else { return nil }
    let fragment = String(reference[reference.index(after: hash)...])
    return !fragment.isEmpty && !fragment.hasPrefix("/") ? fragment : nil
  }

  private func unresolved(_ reference: String) -> MCPJSONSchemaError {
    .invalidSchema([
      MCPJSONSchemaIssue(
        keyword: "$ref",
        instanceLocation: "#",
        schemaLocation: "#",
        message: "unresolved local reference \(reference)"
      )
    ])
  }

  private func externalReference(_ reference: String) -> MCPJSONSchemaError {
    .invalidSchema([
      MCPJSONSchemaIssue(
        keyword: "$ref",
        instanceLocation: "#",
        schemaLocation: "#",
        message: "external reference \(reference) requires a custom schema validator"
      )
    ])
  }
}

/// Foundation's regular-expression engine is backtracking based. The built-in validator accepts
/// a conservative subset of expression constructs so a remote tool schema cannot install a
/// pattern with the usual catastrophic-backtracking shape. Hosts that deliberately need the
/// rejected constructs can inject a validator with an engine that provides its own execution
/// bound.
private enum MCPJSONSchemaRegexSafety {
  private struct Group {
    var branchStart: Int
    var branches: [Range<Int>] = []
    var hasQuantifier = false
    var hasAlternation = false
    var safeAlternation = false
    var atomCount = 0
    /// Character sets of atoms this group must match exactly once. Only atoms whose set is known
    /// are recorded, because an opaque atom cannot be proven to delimit anything.
    var separatorCandidates: [Set<UInt8>] = []
    /// Union of the character sets every repeated atom in this group can consume.
    var quantifiedCharacters: Set<UInt8> = []
    /// A repeated atom whose character set is unknown, which no candidate can be disjoint from.
    var hasOpaqueQuantifiedAtom = false
    var lastAtomIsSeparatorCandidate = false
    /// Union of everything this group can consume, used when the whole group is repeated.
    var consumableCharacters: Set<UInt8> = []
    var hasOpaqueAtom = false
    var firstCharacters: Set<UInt8>?
    var lastCharacters: Set<UInt8>?
    var lastQuantifiedCharacters: Set<UInt8>?
    var lastAtomWasQuantified = false

    init(contentStart: Int) {
      branchStart = contentStart
    }

    /// Whether repeating this group keeps a unique split of the input.
    ///
    /// Counting mandatory atoms is not enough: in `([a-z]+a)` the mandatory `a` is also matched by
    /// the repeated `[a-z]`, so every iteration boundary stays ambiguous and an enclosing
    /// quantifier backtracks exponentially. A separator only delimits when no repeated atom in the
    /// same group can consume it.
    var canProvideMandatorySeparator: Bool {
      guard !hasOpaqueQuantifiedAtom else { return false }
      guard quantifiedCharacters.isEmpty else {
        return separatorCandidates.contains { $0.isDisjoint(with: quantifiedCharacters) }
      }
      return !separatorCandidates.isEmpty
    }
  }

  private enum Atom {
    case simple(Set<UInt8>?)
    case group(Group)

    var characters: Set<UInt8>? {
      switch self {
      case .simple(let characters): characters
      case .group(let group): group.firstCharacters
      }
    }
  }

  static func rejectionReason(for pattern: String) -> String? {
    let bytes = Array(pattern.utf8)
    // Keep a synthetic root so the same adjacency checks apply outside groups.
    var groups: [Group] = [Group(contentStart: 0)]
    var lastAtom: Atom?
    var index = 0

    func trailingCharacters(_ atom: Atom) -> Set<UInt8>? {
      if case .group(let group) = atom, group.canProvideMandatorySeparator {
        return group.lastCharacters ?? group.firstCharacters
      }
      return atom.characters
    }

    /// The character set an atom contributes when it stands as a mandatory separator, or `nil`
    /// when the atom cannot be proven to delimit an iteration.
    func separatorCharacters(_ atom: Atom) -> Set<UInt8>? {
      switch atom {
      case .simple(let characters): characters
      case .group(let group): group.canProvideMandatorySeparator ? group.firstCharacters : nil
      }
    }

    /// Everything an atom can consume. A group is summarised by its whole content rather than its
    /// leading atom, because repeating the group repeats all of it.
    func consumedCharacters(_ atom: Atom) -> Set<UInt8>? {
      switch atom {
      case .simple(let characters): characters
      case .group(let group): group.hasOpaqueAtom ? nil : group.consumableCharacters
      }
    }

    func beginAtom(_ atom: Atom, groups: inout [Group]) {
      let current = groups.index(before: groups.endIndex)
      if !groups[current].lastAtomWasQuantified {
        groups[current].lastQuantifiedCharacters = nil
      }
      if let characters = separatorCharacters(atom) {
        groups[current].separatorCandidates.append(characters)
        groups[current].lastAtomIsSeparatorCandidate = true
      } else {
        groups[current].lastAtomIsSeparatorCandidate = false
      }
      if let characters = consumedCharacters(atom) {
        groups[current].consumableCharacters.formUnion(characters)
      } else {
        groups[current].hasOpaqueAtom = true
      }
      if groups[current].atomCount == 0 {
        groups[current].firstCharacters = atom.characters
      }
      groups[current].atomCount += 1
      groups[current].lastCharacters = trailingCharacters(atom)
      groups[current].lastAtomWasQuantified = false
    }

    func markQuantifier(_ atom: Atom, groups: inout [Group]) -> String? {
      let current = groups.index(before: groups.endIndex)
      let group = groups[current]
      if let previous = group.lastQuantifiedCharacters {
        guard let currentCharacters = atom.characters,
          previous.isDisjoint(with: currentCharacters)
        else {
          return "adjacent overlapping quantifiers may cause excessive backtracking"
        }
      }
      if case .group(let nested) = atom {
        if nested.hasAlternation && !nested.safeAlternation {
          return "overlapping regular expression alternation may cause excessive backtracking"
        }
        if nested.hasQuantifier && !nested.canProvideMandatorySeparator {
          return "nested regular expression quantifiers may cause excessive backtracking"
        }
      }
      // The atom was recorded as mandatory when it began; a quantifier makes it optional and
      // turns its characters into ones every later separator must avoid.
      if groups[current].lastAtomIsSeparatorCandidate {
        groups[current].separatorCandidates.removeLast()
        groups[current].lastAtomIsSeparatorCandidate = false
      }
      if let characters = consumedCharacters(atom) {
        groups[current].quantifiedCharacters.formUnion(characters)
      } else {
        groups[current].hasOpaqueQuantifiedAtom = true
      }
      groups[current].hasQuantifier = true
      groups[current].lastQuantifiedCharacters = trailingCharacters(atom)
      groups[current].lastCharacters = trailingCharacters(atom)
      groups[current].lastAtomWasQuantified = true
      return nil
    }

    func escapedCharacters(_ byte: UInt8) -> Set<UInt8>? {
      switch byte {
      case 100: return Set(48...57)  // \d
      case 119:
        return Set(48...57).union(65...90).union(97...122).union([95])  // \w
      case 115: return [9, 10, 11, 12, 13, 32]  // \s
      case 116: return [9]
      case 110: return [10]
      case 114: return [13]
      case 102: return [12]
      case 118: return [11]
      case 68, 87, 83: return nil  // Negated character classes are broad.
      case 98, 66: return nil  // Word-boundary assertions consume no character.
      default:
        return byte < 128 ? [byte] : nil
      }
    }

    func characterClassEnd(_ start: Int) -> Int? {
      var escaped = false
      var index = start + 1
      while index < bytes.count {
        let byte = bytes[index]
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 93 {
          return index
        }
        index += 1
      }
      return nil
    }

    func classCharacters(_ range: Range<Int>) -> Set<UInt8>? {
      guard range.lowerBound < range.upperBound,
        bytes[range.lowerBound] == 91,
        bytes[range.upperBound - 1] == 93
      else { return nil }
      var index = range.lowerBound + 1
      if index < range.upperBound - 1, bytes[index] == 94 { return nil }
      var characters = Set<UInt8>()
      while index < range.upperBound - 1 {
        let first: Set<UInt8>?
        if bytes[index] == 92, index + 1 < range.upperBound - 1 {
          first = escapedCharacters(bytes[index + 1])
          index += 2
        } else {
          let byte = bytes[index]
          first = byte < 128 ? [byte] : nil
          index += 1
        }
        guard let first else { return nil }
        if index < range.upperBound - 1, bytes[index] == 45, index + 1 < range.upperBound - 1 {
          let second: Set<UInt8>?
          if bytes[index + 1] == 92, index + 2 < range.upperBound - 1 {
            second = escapedCharacters(bytes[index + 2])
            index += 3
          } else {
            let byte = bytes[index + 1]
            second = byte < 128 ? [byte] : nil
            index += 2
          }
          guard let second, first.count == 1, second.count == 1,
            let lower = first.first, let upper = second.first, lower <= upper
          else { return nil }
          characters.formUnion(lower...upper)
        } else {
          characters.formUnion(first)
        }
      }
      return characters
    }

    func simpleAtomCharacters(_ range: Range<Int>) -> Set<UInt8>? {
      guard range.lowerBound < range.upperBound else { return nil }
      if bytes[range.lowerBound] == 91 {
        return classCharacters(range)
      }
      if bytes[range.lowerBound] == 92, range.count == 2 {
        return escapedCharacters(bytes[range.lowerBound + 1])
      }
      guard range.count == 1 else { return nil }
      let byte = bytes[range.lowerBound]
      return byte == 46 || byte >= 128 ? nil : [byte]
    }

    func isDisjointSimpleAlternation(_ group: Group) -> Bool {
      guard group.branches.count > 1 else { return false }
      var branchSets: [Set<UInt8>] = []
      for branch in group.branches {
        guard let characters = simpleAtomCharacters(branch) else { return false }
        branchSets.append(characters)
      }
      for index in branchSets.indices {
        for other in branchSets.dropFirst(index + 1) {
          if !branchSets[index].isDisjoint(with: other) { return false }
        }
      }
      return true
    }

    while index < bytes.count {
      let byte = bytes[index]
      // A trailing '?' after another quantifier is the lazy modifier, not a
      // second repetition operator.
      if byte == 63, index > 0, [42, 43, 63, 125].contains(bytes[index - 1]) {
        index += 1
        continue
      }
      if byte == 91 {
        guard let close = characterClassEnd(index) else {
          lastAtom = .simple(nil)
          index += 1
          continue
        }
        let characters = classCharacters(index..<close + 1)
        let atom = Atom.simple(characters)
        beginAtom(atom, groups: &groups)
        lastAtom = atom
        index = close + 1
        continue
      }

      switch byte {
      case 40:  // (
        let contentStart: Int
        if index + 1 < bytes.count, bytes[index + 1] == 63 {  // ?
          guard index + 2 < bytes.count, bytes[index + 2] == 58 else {  // :
            return "regular expression extensions are not supported by the bounded validator"
          }
          contentStart = index + 3
          index += 2
        } else {
          contentStart = index + 1
        }
        groups.append(Group(contentStart: contentStart))
        lastAtom = nil
      case 41:  // )
        guard groups.count > 1, var group = groups.popLast() else {
          lastAtom = nil
          index += 1
          continue
        }
        if group.hasAlternation {
          group.branches.append(group.branchStart..<index)
          group.safeAlternation = isDisjointSimpleAlternation(group)
          if group.safeAlternation {
            var firstCharacters = Set<UInt8>()
            for branch in group.branches {
              if let characters = simpleAtomCharacters(branch) {
                firstCharacters.formUnion(characters)
              }
            }
            group.firstCharacters = firstCharacters
          }
        }
        let atom = Atom.group(group)
        beginAtom(atom, groups: &groups)
        lastAtom = atom
      case 124:  // |
        let current = groups.index(before: groups.endIndex)
        groups[current].hasAlternation = true
        groups[current].branches.append(groups[current].branchStart..<index)
        groups[current].branchStart = index + 1
        lastAtom = nil
        groups[current].lastAtomWasQuantified = false
        groups[current].lastQuantifiedCharacters = nil
      case 42, 43, 63:  // *, +, ?
        if let lastAtom, let reason = markQuantifier(lastAtom, groups: &groups) {
          return reason
        }
      case 123:  // {
        guard let atom = lastAtom else {
          index += 1
          continue
        }
        guard let close = bytes[index...].firstIndex(of: 125), close > index + 1 else {
          lastAtom = .simple(nil)
          index += 1
          continue
        }
        let body = bytes[(index + 1)..<close]
        guard body.allSatisfy({ $0 == 44 || (48...57).contains($0) }) else {
          lastAtom = .simple(nil)
          index += 1
          continue
        }
        if let reason = markQuantifier(atom, groups: &groups) { return reason }
        index = close
      case 94, 36:  // ^, $
        lastAtom = nil
        let current = groups.index(before: groups.endIndex)
        groups[current].lastAtomWasQuantified = false
        groups[current].lastQuantifiedCharacters = nil
      default:
        if byte == 92 {
          guard index + 1 < bytes.count else {
            lastAtom = .simple(nil)
            index += 1
            continue
          }
          let escaped = bytes[index + 1]
          if escaped == 107 || escaped == 103 || (48...57).contains(escaped) {
            return "regular expression backreferences are not supported by the bounded validator"
          }
          let atom = Atom.simple(escapedCharacters(escaped))
          beginAtom(atom, groups: &groups)
          lastAtom = atom
          index += 1
        } else {
          let atom = Atom.simple(
            byte == 46 || byte >= 128 ? nil : [byte])
          beginAtom(atom, groups: &groups)
          lastAtom = atom
        }
      }
      index += 1
    }
    return nil
  }
}

private struct MCPJSONSchemaCompiler {
  private static let syntheticRootBaseIdentifier = "https://mcp.invalid/json-schema/"

  private struct Reference {
    let value: String
    let location: String
    let resourceIdentifier: String
    let keyword: String
  }

  let root: MCPJSONValue
  let dialect: MCPJSONSchemaDialect
  let limits: MCPJSONSchemaLimits
  var anchors: [String: MCPResolvedJSONSchema] = [:]
  var dynamicAnchors: [String: MCPResolvedJSONSchema] = [:]
  var identifiers: [String: MCPResolvedJSONSchema] = [:]
  var rootIdentifier = syntheticRootBaseIdentifier
  var issues: [MCPJSONSchemaIssue] = []
  var regularExpressions: [String: NSRegularExpression] = [:]
  private var references: [Reference] = []

  init(root: MCPJSONValue, dialect: MCPJSONSchemaDialect, limits: MCPJSONSchemaLimits) {
    self.root = root
    self.dialect = dialect
    self.limits = limits
  }

  mutating func compile() throws {
    try inspect(
      root,
      location: "#",
      depth: 0,
      resourceIdentifier: Self.syntheticRootBaseIdentifier,
      isRoot: true
    )
    guard issues.isEmpty else { return }
    try inspectReferencedAlternateDialectSchemas()
    guard issues.isEmpty else { return }
    let compiled = MCPCompiledReferenceView(
      root: root,
      anchors: anchors,
      identifiers: identifiers,
      rootIdentifier: rootIdentifier
    )
    for reference in references {
      if compiled.canResolve(reference.value, from: reference.resourceIdentifier) { continue }
      addIssue(
        keyword: reference.keyword,
        location: reference.location,
        message: reference.value.hasPrefix("#")
          ? "unresolved local reference \(reference.value)"
          : "external reference \(reference.value) requires a custom schema validator"
      )
    }
  }

  private mutating func inspect(
    _ schema: MCPJSONValue,
    location: String,
    depth: Int,
    resourceIdentifier: String,
    isRoot: Bool = false
  ) throws {
    guard depth <= limits.maximumSchemaDepth else {
      throw MCPJSONSchemaError.resourceLimit("schema depth exceeds \(limits.maximumSchemaDepth)")
    }
    guard case .object(let object) = schema else { return }

    var currentResourceIdentifier = resourceIdentifier
    if let rawID = object["$id"] {
      guard case .string(let identifier) = rawID,
        !identifier.contains("#"),
        let base = URL(string: resourceIdentifier),
        let resolvedURL = URL(string: identifier, relativeTo: base)?.absoluteURL
      else {
        addIssue(
          keyword: "$id",
          location: location + "/$id",
          message: "expected a valid URI-reference without a fragment"
        )
        return
      }
      currentResourceIdentifier = resolvedURL.absoluteString
      if identifiers[currentResourceIdentifier] != nil {
        addIssue(
          keyword: "$id",
          location: location + "/$id",
          message: "duplicate schema resource identifier \(currentResourceIdentifier)"
        )
        return
      }
      identifiers[currentResourceIdentifier] = MCPResolvedJSONSchema(
        value: schema,
        location: location,
        resourceIdentifier: currentResourceIdentifier
      )
      if isRoot { rootIdentifier = currentResourceIdentifier }
    } else if isRoot {
      identifiers[currentResourceIdentifier] = MCPResolvedJSONSchema(
        value: schema,
        location: location,
        resourceIdentifier: currentResourceIdentifier
      )
    }

    if dialect == .draft202012, let rawAnchor = object["$anchor"] {
      guard case .string(let anchor) = rawAnchor, Self.isValidAnchor(anchor) else {
        addIssue(keyword: "$anchor", location: location + "/$anchor", message: "invalid anchor")
        return
      }
      let key = MCPCompiledJSONSchema.anchorKey(
        resourceIdentifier: currentResourceIdentifier,
        anchor: anchor
      )
      if anchors[key] != nil {
        addIssue(
          keyword: "$anchor", location: location + "/$anchor", message: "duplicate anchor \(anchor)"
        )
      } else {
        anchors[key] = MCPResolvedJSONSchema(
          value: schema,
          location: location,
          resourceIdentifier: currentResourceIdentifier
        )
      }
    }

    if dialect == .draft202012, let rawAnchor = object["$dynamicAnchor"] {
      guard case .string(let anchor) = rawAnchor, Self.isValidAnchor(anchor) else {
        addIssue(
          keyword: "$dynamicAnchor", location: location + "/$dynamicAnchor",
          message: "invalid anchor")
        return
      }
      let key = MCPCompiledJSONSchema.anchorKey(
        resourceIdentifier: currentResourceIdentifier,
        anchor: anchor
      )
      if dynamicAnchors[key] != nil || anchors[key] != nil {
        addIssue(
          keyword: "$dynamicAnchor", location: location + "/$dynamicAnchor",
          message: "duplicate anchor \(anchor)")
      } else {
        let resolved = MCPResolvedJSONSchema(
          value: schema,
          location: location,
          resourceIdentifier: currentResourceIdentifier
        )
        dynamicAnchors[key] = resolved
        anchors[key] = resolved
      }
    }

    if dialect == .draft202012, let vocabulary = object["$vocabulary"] {
      guard case .object(let entries) = vocabulary,
        entries.values.allSatisfy({ if case .bool = $0 { true } else { false } })
      else {
        addIssue(
          keyword: "$vocabulary", location: location + "/$vocabulary",
          message: "expected object of booleans")
        return
      }
      if entries["https://json-schema.org/draft/2020-12/vocab/format-assertion"] == .bool(true) {
        addIssue(
          keyword: "$vocabulary",
          location: location + "/$vocabulary",
          message: "format assertion vocabulary requires a custom schema validator"
        )
      }
    }

    if let ref = object["$ref"] {
      guard case .string(let reference) = ref else {
        addIssue(keyword: "$ref", location: location + "/$ref", message: "expected string")
        return
      }
      references.append(
        Reference(
          value: reference,
          location: location + "/$ref",
          resourceIdentifier: currentResourceIdentifier,
          keyword: "$ref"
        ))
    }
    if let dynamicRef = object["$dynamicRef"] {
      guard case .string(let reference) = dynamicRef else {
        addIssue(
          keyword: "$dynamicRef", location: location + "/$dynamicRef", message: "expected string")
        return
      }
      references.append(
        Reference(
          value: reference,
          location: location + "/$dynamicRef",
          resourceIdentifier: currentResourceIdentifier,
          keyword: "$dynamicRef"
        ))
    }

    inspectType(object["type"], location: location + "/type")
    try inspectSchemaArray(
      object["allOf"], keyword: "allOf", location: location, depth: depth,
      resourceIdentifier: currentResourceIdentifier)
    try inspectSchemaArray(
      object["anyOf"], keyword: "anyOf", location: location, depth: depth,
      resourceIdentifier: currentResourceIdentifier)
    try inspectSchemaArray(
      object["oneOf"], keyword: "oneOf", location: location, depth: depth,
      resourceIdentifier: currentResourceIdentifier)

    var schemaKeywords = [
      "not", "if", "then", "else", "contains", "propertyNames", "additionalProperties",
    ]
    if dialect == .draft202012 {
      schemaKeywords.append(contentsOf: ["unevaluatedProperties", "unevaluatedItems"])
    }
    for keyword in schemaKeywords {
      if let value = object[keyword] {
        if value.isSchema {
          try inspect(
            value, location: location + "/" + Self.escape(keyword), depth: depth + 1,
            resourceIdentifier: currentResourceIdentifier)
        } else {
          addIssue(
            keyword: keyword, location: location + "/" + Self.escape(keyword),
            message: "expected schema")
        }
      }
    }

    if let items = object["items"] {
      switch dialect {
      case .draft202012:
        if items.isSchema {
          try inspect(
            items, location: location + "/items", depth: depth + 1,
            resourceIdentifier: currentResourceIdentifier)
        } else {
          addIssue(keyword: "items", location: location + "/items", message: "expected schema")
        }
      case .draft7:
        if items.isSchema {
          try inspect(
            items, location: location + "/items", depth: depth + 1,
            resourceIdentifier: currentResourceIdentifier)
        } else if case .array(let schemas) = items {
          for (index, child) in schemas.enumerated() {
            if child.isSchema {
              try inspect(
                child, location: location + "/items/\(index)", depth: depth + 1,
                resourceIdentifier: currentResourceIdentifier)
            } else {
              addIssue(
                keyword: "items", location: location + "/items/\(index)", message: "expected schema"
              )
            }
          }
        } else {
          addIssue(
            keyword: "items", location: location + "/items",
            message: "expected schema or schema array")
        }
      }
    }

    if dialect == .draft7, let additionalItems = object["additionalItems"] {
      if additionalItems.isSchema {
        try inspect(
          additionalItems, location: location + "/additionalItems", depth: depth + 1,
          resourceIdentifier: currentResourceIdentifier)
      } else {
        addIssue(
          keyword: "additionalItems", location: location + "/additionalItems",
          message: "expected schema")
      }
    }

    if let prefixItems = object["prefixItems"] {
      if dialect == .draft7 {
        // Unknown keywords are annotations in draft-07 and are ignored.
      } else {
        try inspectSchemaArray(
          prefixItems, keyword: "prefixItems", location: location, depth: depth,
          resourceIdentifier: currentResourceIdentifier, permitsEmpty: true)
      }
    }

    var schemaMapKeywords = ["properties", "patternProperties"]
    switch dialect {
    case .draft202012:
      schemaMapKeywords.append(contentsOf: ["dependentSchemas", "$defs"])
    case .draft7:
      schemaMapKeywords.append("definitions")
    }
    for keyword in schemaMapKeywords {
      guard let raw = object[keyword] else { continue }
      guard case .object(let schemas) = raw else {
        addIssue(
          keyword: keyword, location: location + "/" + Self.escape(keyword),
          message: "expected object")
        continue
      }
      for (key, child) in schemas.sorted(by: { $0.key < $1.key }) {
        if keyword == "patternProperties" {
          inspectRegex(
            key, keyword: keyword, location: location + "/patternProperties/" + Self.escape(key))
        }
        if child.isSchema {
          try inspect(
            child,
            location: location + "/" + Self.escape(keyword) + "/" + Self.escape(key),
            depth: depth + 1,
            resourceIdentifier: currentResourceIdentifier
          )
        } else {
          addIssue(
            keyword: keyword,
            location: location + "/" + Self.escape(keyword) + "/" + Self.escape(key),
            message: "expected schema"
          )
        }
      }
    }

    if dialect == .draft7, let dependencies = object["dependencies"] {
      guard case .object(let values) = dependencies else {
        addIssue(
          keyword: "dependencies", location: location + "/dependencies", message: "expected object")
        return
      }
      for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        if value.isSchema {
          try inspect(
            value, location: location + "/dependencies/" + Self.escape(key), depth: depth + 1,
            resourceIdentifier: currentResourceIdentifier)
        } else {
          inspectUniqueStringArray(
            value, keyword: "dependencies", location: location + "/dependencies/" + Self.escape(key)
          )
        }
      }
    }

    if let required = object["required"] {
      inspectUniqueStringArray(required, keyword: "required", location: location + "/required")
    }
    if dialect == .draft202012, let dependentRequired = object["dependentRequired"] {
      guard case .object(let dependencies) = dependentRequired else {
        addIssue(
          keyword: "dependentRequired", location: location + "/dependentRequired",
          message: "expected object")
        return
      }
      for (key, value) in dependencies.sorted(by: { $0.key < $1.key }) {
        inspectUniqueStringArray(
          value,
          keyword: "dependentRequired",
          location: location + "/dependentRequired/" + Self.escape(key)
        )
      }
    }

    var nonnegativeIntegerKeywords = [
      "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties",
    ]
    if dialect == .draft202012 {
      nonnegativeIntegerKeywords.append(contentsOf: ["minContains", "maxContains"])
    }
    for keyword in nonnegativeIntegerKeywords {
      if let value = object[keyword] {
        inspectNonnegativeInteger(value, keyword: keyword, location: location + "/" + keyword)
      }
    }
    if let multipleOf = object["multipleOf"] {
      guard case .number(let number) = multipleOf,
        number.compare(to: MCPJSONNumber(0)) == .orderedDescending
      else {
        addIssue(
          keyword: "multipleOf", location: location + "/multipleOf",
          message: "expected a number greater than zero")
        return
      }
    }
    for keyword in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
      if let value = object[keyword], case .number = value { continue }
      if object[keyword] != nil {
        addIssue(keyword: keyword, location: location + "/" + keyword, message: "expected number")
      }
    }
    if let unique = object["uniqueItems"], case .bool = unique {
    } else if object["uniqueItems"] != nil {
      addIssue(
        keyword: "uniqueItems", location: location + "/uniqueItems", message: "expected boolean")
    }
    if let pattern = object["pattern"] {
      guard case .string(let value) = pattern else {
        addIssue(keyword: "pattern", location: location + "/pattern", message: "expected string")
        return
      }
      inspectRegex(value, keyword: "pattern", location: location + "/pattern")
    }
    if let enumValue = object["enum"] {
      guard case .array(let values) = enumValue else {
        addIssue(keyword: "enum", location: location + "/enum", message: "expected array")
        return
      }
      var semanticValues = Set<[UInt8]>()
      for value in values where !semanticValues.insert(value.schemaSemanticFingerprint).inserted {
        addIssue(keyword: "enum", location: location + "/enum", message: "values must be unique")
        return
      }
    }
  }

  /// `definitions` and `$defs` are annotations in the opposite dialect, but local JSON Pointers
  /// can still target them. Inspect only the concrete referenced schema after the normal traversal
  /// is complete. New references discovered in that schema are processed in turn, so compilation
  /// does not depend on object-key order and unrelated cross-dialect map siblings stay inert.
  private mutating func inspectReferencedAlternateDialectSchemas() throws {
    var nextReference = 0
    var inspectedTargets = Set<String>()
    while nextReference < references.count {
      let reference = references[nextReference]
      nextReference += 1
      guard reference.keyword == "$ref",
        let target = alternateDialectReferenceTarget(for: reference),
        inspectedTargets.insert(target.schema.location).inserted
      else { continue }
      guard target.schema.value.isSchema else {
        addIssue(
          keyword: "$ref", location: reference.location, message: "referenced value is not a schema"
        )
        continue
      }
      try inspect(
        target.schema.value, location: target.schema.location, depth: target.depth,
        resourceIdentifier: target.schema.resourceIdentifier)
      guard issues.isEmpty else { return }
    }
  }

  private func alternateDialectReferenceTarget(
    for reference: Reference
  ) -> (schema: MCPResolvedJSONSchema, depth: Int)? {
    guard reference.resourceIdentifier == rootIdentifier, reference.value.hasPrefix("#/") else {
      return nil
    }
    let pointer = String(reference.value.dropFirst())
    let components = pointer.split(separator: "/", omittingEmptySubsequences: false)
    let alternateDialectKeyword =
      switch dialect {
      case .draft202012: "definitions"
      case .draft7: "$defs"
      }
    guard
      components.dropLast().contains(where: {
        $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
          == alternateDialectKeyword
      }), let value = root.value(atJSONPointer: pointer)
    else { return nil }
    // The pointer also gives a conservative lower bound for the schema's nesting level. This
    // preserves the schema-depth resource cap for deeply nested alternate-dialect branches.
    return (
      MCPResolvedJSONSchema(
        value: value,
        location: "#" + pointer,
        resourceIdentifier: rootIdentifier
      ),
      max(1, components.count - 2)
    )
  }

  private mutating func inspectSchemaArray(
    _ raw: MCPJSONValue?,
    keyword: String,
    location: String,
    depth: Int,
    resourceIdentifier: String,
    permitsEmpty: Bool = false
  ) throws {
    guard let raw else { return }
    guard case .array(let schemas) = raw, permitsEmpty || !schemas.isEmpty else {
      addIssue(
        keyword: keyword, location: location + "/" + keyword,
        message: permitsEmpty ? "expected array" : "expected non-empty array")
      return
    }
    for (index, schema) in schemas.enumerated() {
      if schema.isSchema {
        try inspect(
          schema,
          location: location + "/" + keyword + "/\(index)",
          depth: depth + 1,
          resourceIdentifier: resourceIdentifier
        )
      } else {
        addIssue(
          keyword: keyword, location: location + "/" + keyword + "/\(index)",
          message: "expected schema")
      }
    }
  }

  private mutating func inspectType(_ raw: MCPJSONValue?, location: String) {
    guard let raw else { return }
    let valid = Set(["null", "boolean", "object", "array", "number", "string", "integer"])
    switch raw {
    case .string(let type):
      if !valid.contains(type) {
        addIssue(keyword: "type", location: location, message: "unknown type \(type)")
      }
    case .array(let values):
      guard !values.isEmpty else {
        addIssue(keyword: "type", location: location, message: "type array must not be empty")
        return
      }
      var seen: Set<String> = []
      for value in values {
        guard case .string(let type) = value, valid.contains(type), seen.insert(type).inserted
        else {
          addIssue(keyword: "type", location: location, message: "expected unique valid type names")
          return
        }
      }
    default:
      addIssue(keyword: "type", location: location, message: "expected string or string array")
    }
  }

  private mutating func inspectUniqueStringArray(
    _ raw: MCPJSONValue,
    keyword: String,
    location: String
  ) {
    guard case .array(let values) = raw else {
      addIssue(keyword: keyword, location: location, message: "expected string array")
      return
    }
    var seen: Set<String> = []
    for value in values {
      guard case .string(let string) = value, seen.insert(string).inserted else {
        addIssue(keyword: keyword, location: location, message: "expected unique strings")
        return
      }
    }
  }

  private mutating func inspectNonnegativeInteger(
    _ raw: MCPJSONValue,
    keyword: String,
    location: String
  ) {
    guard case .number(let number) = raw, number.isMathematicalInteger,
      number.compare(to: MCPJSONNumber(0)) != .orderedAscending
    else {
      addIssue(keyword: keyword, location: location, message: "expected non-negative integer")
      return
    }
  }

  private mutating func inspectRegex(_ pattern: String, keyword: String, location: String) {
    guard pattern.utf8.count <= limits.maximumRegexBytes else {
      addIssue(
        keyword: keyword, location: location, message: "regular expression exceeds byte limit")
      return
    }
    if let reason = MCPJSONSchemaRegexSafety.rejectionReason(for: pattern) {
      addIssue(keyword: keyword, location: location, message: reason)
      return
    }
    do { regularExpressions[location] = try NSRegularExpression(pattern: pattern) } catch {
      addIssue(keyword: keyword, location: location, message: "invalid regular expression")
    }
  }

  private mutating func addIssue(keyword: String, location: String, message: String) {
    guard issues.count < limits.maximumIssues else { return }
    issues.append(
      MCPJSONSchemaIssue(
        keyword: keyword,
        instanceLocation: "#",
        schemaLocation: location,
        message: message
      ))
  }

  private static func isValidAnchor(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
      CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first)
    else { return false }
    return value.unicodeScalars.dropFirst().allSatisfy {
      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._")).contains($0)
    }
  }

  fileprivate static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
  }
}

private struct MCPCompiledReferenceView {
  let root: MCPJSONValue
  let anchors: [String: MCPResolvedJSONSchema]
  let identifiers: [String: MCPResolvedJSONSchema]
  let rootIdentifier: String

  func canResolve(_ reference: String, from resourceIdentifier: String) -> Bool {
    guard identifiers[resourceIdentifier] != nil,
      let base = URL(string: resourceIdentifier),
      let resolved = URL(string: reference, relativeTo: base)?.absoluteURL
    else { return false }
    var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
    let fragment = components?.fragment
    components?.fragment = nil
    let targetIdentifier = components?.url?.absoluteString ?? resolved.absoluteString
    guard let target = identifiers[targetIdentifier] else { return false }
    guard let fragment, !fragment.isEmpty else { return true }
    if fragment.hasPrefix("/") { return target.value.value(atJSONPointer: fragment) != nil }
    return anchors[
      MCPCompiledJSONSchema.anchorKey(resourceIdentifier: targetIdentifier, anchor: fragment)]
      != nil
  }
}

private struct MCPJSONSchemaEvaluation {
  var issues: [MCPJSONSchemaIssue] = []
  var evaluatedProperties: Set<String> = []
  var evaluatedItems: Set<Int> = []

  var valid: Bool { issues.isEmpty }

  mutating func merge(_ other: MCPJSONSchemaEvaluation, annotations: Bool = true) {
    issues.append(contentsOf: other.issues)
    guard annotations else { return }
    evaluatedProperties.formUnion(other.evaluatedProperties)
    evaluatedItems.formUnion(other.evaluatedItems)
  }
}

private struct MCPJSONSchemaCycleKey: Hashable {
  let schemaLocation: String
  let instanceLocation: String
}

private struct MCPJSONSchemaEvaluator {
  let compiled: MCPCompiledJSONSchema
  let limits: MCPJSONSchemaLimits
  private var evaluations = 0
  private var active: Set<MCPJSONSchemaCycleKey> = []
  private var dynamicScope: [String] = []

  init(compiled: MCPCompiledJSONSchema, limits: MCPJSONSchemaLimits) {
    self.compiled = compiled
    self.limits = limits
  }

  mutating func evaluate(
    schema: MCPJSONValue,
    schemaLocation: String,
    instance: MCPJSONValue,
    instanceLocation: String,
    depth: Int
  ) throws -> MCPJSONSchemaEvaluation {
    evaluations += 1
    guard evaluations <= limits.maximumEvaluations else {
      throw MCPJSONSchemaError.resourceLimit(
        "validation evaluations exceed \(limits.maximumEvaluations)")
    }
    guard depth <= limits.maximumInstanceDepth else {
      throw MCPJSONSchemaError.resourceLimit(
        "instance depth exceeds \(limits.maximumInstanceDepth)")
    }
    let resourceIdentifier = compiled.resourceIdentifier(for: schemaLocation)
    let pushedResource = dynamicScope.last != resourceIdentifier
    if pushedResource { dynamicScope.append(resourceIdentifier) }
    defer {
      if pushedResource { _ = dynamicScope.popLast() }
    }

    switch schema {
    case .bool(true): return MCPJSONSchemaEvaluation()
    case .bool(false):
      return issue(
        keyword: "falseSchema",
        instanceLocation: instanceLocation,
        schemaLocation: schemaLocation,
        message: "value is rejected by false schema"
      )
    case .object(let object):
      return try evaluateObjectSchema(
        object,
        schemaLocation: schemaLocation,
        instance: instance,
        instanceLocation: instanceLocation,
        depth: depth
      )
    default:
      throw MCPJSONSchemaError.invalidSchema([
        MCPJSONSchemaIssue(
          keyword: "schema",
          instanceLocation: instanceLocation,
          schemaLocation: schemaLocation,
          message: "schema must be object or boolean"
        )
      ])
    }
  }

  private mutating func evaluateObjectSchema(
    _ schema: [String: MCPJSONValue],
    schemaLocation: String,
    instance: MCPJSONValue,
    instanceLocation: String,
    depth: Int
  ) throws -> MCPJSONSchemaEvaluation {
    let resourceIdentifier = compiled.resourceIdentifier(for: schemaLocation)
    let cycle = MCPJSONSchemaCycleKey(
      schemaLocation: schemaLocation, instanceLocation: instanceLocation)
    guard active.insert(cycle).inserted else {
      throw MCPJSONSchemaError.invalidSchema([
        MCPJSONSchemaIssue(
          keyword: "$ref",
          instanceLocation: instanceLocation,
          schemaLocation: schemaLocation,
          message: "reference cycle does not advance the instance"
        )
      ])
    }
    defer { active.remove(cycle) }

    if compiled.dialect == .draft7, case .string(let reference)? = schema["$ref"] {
      let resolved = try compiled.resolve(reference: reference, from: resourceIdentifier)
      return try evaluate(
        schema: resolved.value,
        schemaLocation: resolved.location,
        instance: instance,
        instanceLocation: instanceLocation,
        depth: depth + 1
      )
    }

    var result = MCPJSONSchemaEvaluation()
    if case .string(let reference)? = schema["$ref"] {
      let resolved = try compiled.resolve(reference: reference, from: resourceIdentifier)
      result.merge(
        try evaluate(
          schema: resolved.value,
          schemaLocation: resolved.location,
          instance: instance,
          instanceLocation: instanceLocation,
          depth: depth + 1
        ))
    }
    if compiled.dialect == .draft202012, case .string(let reference)? = schema["$dynamicRef"] {
      let resolved = try compiled.resolveDynamic(
        reference: reference,
        from: resourceIdentifier,
        scope: dynamicScope
      )
      result.merge(
        try evaluate(
          schema: resolved.value,
          schemaLocation: resolved.location,
          instance: instance,
          instanceLocation: instanceLocation,
          depth: depth + 1
        ))
    }

    if let type = schema["type"], !matchesType(instance, declared: type) {
      result.merge(
        issue(
          keyword: "type",
          instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/type",
          message: "value does not match declared type"
        ))
      return bounded(result)
    }

    if let constant = schema["const"], !instance.schemaSemanticEquals(constant) {
      result.merge(
        issue(
          keyword: "const", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/const", message: "value does not equal const"))
    }
    if case .array(let values)? = schema["enum"],
      !values.contains(where: { instance.schemaSemanticEquals($0) })
    {
      result.merge(
        issue(
          keyword: "enum", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/enum", message: "value is not in enum"))
    }

    result.merge(
      try evaluateCompositions(
        schema, schemaLocation: schemaLocation, instance: instance,
        instanceLocation: instanceLocation, depth: depth))

    switch instance {
    case .number(let number):
      result.merge(
        try evaluateNumber(
          number, schema: schema, schemaLocation: schemaLocation, instanceLocation: instanceLocation
        ))
    case .string(let string):
      result.merge(
        try evaluateString(
          string, schema: schema, schemaLocation: schemaLocation, instanceLocation: instanceLocation
        ))
    case .array(let array):
      result.merge(
        try evaluateArray(
          array, schema: schema, schemaLocation: schemaLocation, instanceLocation: instanceLocation,
          depth: depth))
    case .object(let object):
      result.merge(
        try evaluateInstanceObject(
          object, schema: schema, schemaLocation: schemaLocation,
          instanceLocation: instanceLocation, depth: depth))
    default:
      break
    }

    if compiled.dialect == .draft202012 {
      if case .object(let object) = instance, let unevaluated = schema["unevaluatedProperties"] {
        let remaining =
          object
          .filter { !result.evaluatedProperties.contains($0.key) }
          .sorted(by: { $0.key < $1.key })
        for (key, value) in remaining {
          let child = try evaluate(
            schema: unevaluated,
            schemaLocation: schemaLocation + "/unevaluatedProperties",
            instance: value,
            instanceLocation: instanceLocation + "/" + MCPJSONSchemaCompiler.escape(key),
            depth: depth + 1
          )
          result.merge(child, annotations: false)
          result.evaluatedProperties.insert(key)
        }
      }
      if case .array(let array) = instance, let unevaluated = schema["unevaluatedItems"] {
        for index in array.indices where !result.evaluatedItems.contains(index) {
          let child = try evaluate(
            schema: unevaluated,
            schemaLocation: schemaLocation + "/unevaluatedItems",
            instance: array[index],
            instanceLocation: instanceLocation + "/\(index)",
            depth: depth + 1
          )
          result.merge(child, annotations: false)
          result.evaluatedItems.insert(index)
        }
      }
    }
    return bounded(result)
  }

  private mutating func evaluateCompositions(
    _ schema: [String: MCPJSONValue],
    schemaLocation: String,
    instance: MCPJSONValue,
    instanceLocation: String,
    depth: Int
  ) throws -> MCPJSONSchemaEvaluation {
    var result = MCPJSONSchemaEvaluation()

    if case .array(let all)? = schema["allOf"] {
      for (index, childSchema) in all.enumerated() {
        result.merge(
          try evaluate(
            schema: childSchema,
            schemaLocation: schemaLocation + "/allOf/\(index)",
            instance: instance,
            instanceLocation: instanceLocation,
            depth: depth + 1
          ))
      }
    }

    if case .array(let any)? = schema["anyOf"] {
      var validBranches: [MCPJSONSchemaEvaluation] = []
      for (index, childSchema) in any.enumerated() {
        let branch = try evaluate(
          schema: childSchema,
          schemaLocation: schemaLocation + "/anyOf/\(index)",
          instance: instance,
          instanceLocation: instanceLocation,
          depth: depth + 1
        )
        if branch.valid { validBranches.append(branch) }
      }
      if validBranches.isEmpty {
        result.merge(
          issue(
            keyword: "anyOf", instanceLocation: instanceLocation,
            schemaLocation: schemaLocation + "/anyOf", message: "value does not match any branch"))
      } else {
        for branch in validBranches {
          result.evaluatedProperties.formUnion(branch.evaluatedProperties)
          result.evaluatedItems.formUnion(branch.evaluatedItems)
        }
      }
    }

    if case .array(let one)? = schema["oneOf"] {
      var validBranches: [MCPJSONSchemaEvaluation] = []
      for (index, childSchema) in one.enumerated() {
        let branch = try evaluate(
          schema: childSchema,
          schemaLocation: schemaLocation + "/oneOf/\(index)",
          instance: instance,
          instanceLocation: instanceLocation,
          depth: depth + 1
        )
        if branch.valid { validBranches.append(branch) }
      }
      if validBranches.count != 1 {
        result.merge(
          issue(
            keyword: "oneOf", instanceLocation: instanceLocation,
            schemaLocation: schemaLocation + "/oneOf",
            message: "value must match exactly one branch"))
      } else if let branch = validBranches.first {
        result.evaluatedProperties.formUnion(branch.evaluatedProperties)
        result.evaluatedItems.formUnion(branch.evaluatedItems)
      }
    }

    if let notSchema = schema["not"] {
      let branch = try evaluate(
        schema: notSchema, schemaLocation: schemaLocation + "/not", instance: instance,
        instanceLocation: instanceLocation, depth: depth + 1)
      if branch.valid {
        result.merge(
          issue(
            keyword: "not", instanceLocation: instanceLocation,
            schemaLocation: schemaLocation + "/not", message: "value matches forbidden schema"))
      }
    }

    if let ifSchema = schema["if"] {
      let condition = try evaluate(
        schema: ifSchema, schemaLocation: schemaLocation + "/if", instance: instance,
        instanceLocation: instanceLocation, depth: depth + 1)
      if condition.valid {
        result.evaluatedProperties.formUnion(condition.evaluatedProperties)
        result.evaluatedItems.formUnion(condition.evaluatedItems)
        if let thenSchema = schema["then"] {
          result.merge(
            try evaluate(
              schema: thenSchema, schemaLocation: schemaLocation + "/then", instance: instance,
              instanceLocation: instanceLocation, depth: depth + 1))
        }
      } else if let elseSchema = schema["else"] {
        result.merge(
          try evaluate(
            schema: elseSchema, schemaLocation: schemaLocation + "/else", instance: instance,
            instanceLocation: instanceLocation, depth: depth + 1))
      }
    }
    return result
  }

  private func evaluateNumber(
    _ value: MCPJSONNumber,
    schema: [String: MCPJSONValue],
    schemaLocation: String,
    instanceLocation: String
  ) throws -> MCPJSONSchemaEvaluation {
    var result = MCPJSONSchemaEvaluation()
    if case .number(let divisor)? = schema["multipleOf"] {
      guard
        let multiple = value.isMultiple(
          of: divisor, maximumPowerExpansion: limits.maximumPowerExpansion)
      else {
        throw MCPJSONSchemaError.resourceLimit(
          "multipleOf decimal expansion exceeds \(limits.maximumPowerExpansion)")
      }
      if !multiple {
        result.merge(
          issue(
            keyword: "multipleOf", instanceLocation: instanceLocation,
            schemaLocation: schemaLocation + "/multipleOf",
            message: "number is not a multiple of \(divisor.rawValue)"))
      }
    }
    if case .number(let minimum)? = schema["minimum"],
      value.compare(to: minimum) == .orderedAscending
    {
      result.merge(
        issue(
          keyword: "minimum", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/minimum", message: "number is below minimum"))
    }
    if case .number(let maximum)? = schema["maximum"],
      value.compare(to: maximum) == .orderedDescending
    {
      result.merge(
        issue(
          keyword: "maximum", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/maximum", message: "number is above maximum"))
    }
    if case .number(let minimum)? = schema["exclusiveMinimum"],
      value.compare(to: minimum) != .orderedDescending
    {
      result.merge(
        issue(
          keyword: "exclusiveMinimum", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/exclusiveMinimum",
          message: "number is not above exclusive minimum"))
    }
    if case .number(let maximum)? = schema["exclusiveMaximum"],
      value.compare(to: maximum) != .orderedAscending
    {
      result.merge(
        issue(
          keyword: "exclusiveMaximum", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/exclusiveMaximum",
          message: "number is not below exclusive maximum"))
    }
    return result
  }

  private func evaluateString(
    _ value: String,
    schema: [String: MCPJSONValue],
    schemaLocation: String,
    instanceLocation: String
  ) throws -> MCPJSONSchemaEvaluation {
    var result = MCPJSONSchemaEvaluation()
    let length = value.unicodeScalars.count
    if let minimum = schema["minLength"]?.numberValue?.exactIntValue, length < minimum {
      result.merge(
        issue(
          keyword: "minLength", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/minLength",
          message: "string is shorter than \(minimum) code points"))
    }
    if let maximum = schema["maxLength"]?.numberValue?.exactIntValue, length > maximum {
      result.merge(
        issue(
          keyword: "maxLength", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/maxLength",
          message: "string is longer than \(maximum) code points"))
    }
    if case .string? = schema["pattern"] {
      try ensureRegexInputWithinLimit(value)
      let expression = try compiled.regularExpression(at: schemaLocation + "/pattern")
      let range = NSRange(value.startIndex..<value.endIndex, in: value)
      if expression.firstMatch(in: value, range: range) == nil {
        result.merge(
          issue(
            keyword: "pattern", instanceLocation: instanceLocation,
            schemaLocation: schemaLocation + "/pattern", message: "string does not match pattern"))
      }
    }
    return result
  }

  private mutating func evaluateArray(
    _ values: [MCPJSONValue],
    schema: [String: MCPJSONValue],
    schemaLocation: String,
    instanceLocation: String,
    depth: Int
  ) throws -> MCPJSONSchemaEvaluation {
    var result = MCPJSONSchemaEvaluation()
    if let minimum = schema["minItems"]?.numberValue?.exactIntValue, values.count < minimum {
      result.merge(
        issue(
          keyword: "minItems", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/minItems",
          message: "array has fewer than \(minimum) items"))
    }
    if let maximum = schema["maxItems"]?.numberValue?.exactIntValue, values.count > maximum {
      result.merge(
        issue(
          keyword: "maxItems", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/maxItems",
          message: "array has more than \(maximum) items"))
    }
    if schema["uniqueItems"] == .bool(true) {
      guard values.count <= limits.maximumUniqueItems else {
        throw MCPJSONSchemaError.resourceLimit(
          "uniqueItems exceeds \(limits.maximumUniqueItems) values")
      }
      var semanticValues = Set<[UInt8]>()
      for value in values where !semanticValues.insert(value.schemaSemanticFingerprint).inserted {
        result.merge(
          issue(
            keyword: "uniqueItems",
            instanceLocation: instanceLocation,
            schemaLocation: schemaLocation + "/uniqueItems",
            message: "array items are not unique"
          ))
        break
      }
    }

    switch compiled.dialect {
    case .draft202012:
      let prefixes = schema["prefixItems"]?.arrayValue ?? []
      for index in 0..<min(prefixes.count, values.count) {
        result.merge(
          try evaluate(
            schema: prefixes[index], schemaLocation: schemaLocation + "/prefixItems/\(index)",
            instance: values[index], instanceLocation: instanceLocation + "/\(index)",
            depth: depth + 1), annotations: false)
        result.evaluatedItems.insert(index)
      }
      if let items = schema["items"] {
        // An instance shorter than prefixItems leaves no positions for items. The lower bound is
        // clamped so the empty case stays empty instead of forming an invalid range.
        for index in min(prefixes.count, values.count)..<values.count {
          result.merge(
            try evaluate(
              schema: items, schemaLocation: schemaLocation + "/items", instance: values[index],
              instanceLocation: instanceLocation + "/\(index)", depth: depth + 1),
            annotations: false)
          result.evaluatedItems.insert(index)
        }
      }
    case .draft7:
      if let items = schema["items"] {
        if items.isSchema {
          for index in values.indices {
            result.merge(
              try evaluate(
                schema: items, schemaLocation: schemaLocation + "/items", instance: values[index],
                instanceLocation: instanceLocation + "/\(index)", depth: depth + 1),
              annotations: false)
            result.evaluatedItems.insert(index)
          }
        } else if case .array(let tuple) = items {
          for index in 0..<min(tuple.count, values.count) {
            result.merge(
              try evaluate(
                schema: tuple[index], schemaLocation: schemaLocation + "/items/\(index)",
                instance: values[index], instanceLocation: instanceLocation + "/\(index)",
                depth: depth + 1), annotations: false)
            result.evaluatedItems.insert(index)
          }
          let additional = schema["additionalItems"] ?? .bool(true)
          // An instance shorter than the tuple leaves no additional positions to evaluate.
          for index in min(tuple.count, values.count)..<values.count {
            result.merge(
              try evaluate(
                schema: additional, schemaLocation: schemaLocation + "/additionalItems",
                instance: values[index], instanceLocation: instanceLocation + "/\(index)",
                depth: depth + 1), annotations: false)
            result.evaluatedItems.insert(index)
          }
        }
      }
    }

    if let contains = schema["contains"] {
      var matching: [Int] = []
      for index in values.indices {
        let candidate = try evaluate(
          schema: contains, schemaLocation: schemaLocation + "/contains", instance: values[index],
          instanceLocation: instanceLocation + "/\(index)", depth: depth + 1)
        if candidate.valid { matching.append(index) }
      }
      let minimum =
        compiled.dialect == .draft202012
        ? schema["minContains"]?.numberValue?.exactIntValue ?? 1
        : 1
      let maximum =
        compiled.dialect == .draft202012
        ? schema["maxContains"]?.numberValue?.exactIntValue
        : nil
      if matching.count < minimum || maximum.map({ matching.count > $0 }) == true {
        result.merge(
          issue(
            keyword: "contains", instanceLocation: instanceLocation,
            schemaLocation: schemaLocation + "/contains",
            message: "matching item count is outside contains bounds"))
      } else {
        result.evaluatedItems.formUnion(matching)
      }
    }
    return result
  }

  private mutating func evaluateInstanceObject(
    _ values: [String: MCPJSONValue],
    schema: [String: MCPJSONValue],
    schemaLocation: String,
    instanceLocation: String,
    depth: Int
  ) throws -> MCPJSONSchemaEvaluation {
    var result = MCPJSONSchemaEvaluation()
    if let minimum = schema["minProperties"]?.numberValue?.exactIntValue, values.count < minimum {
      result.merge(
        issue(
          keyword: "minProperties", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/minProperties",
          message: "object has fewer than \(minimum) properties"))
    }
    if let maximum = schema["maxProperties"]?.numberValue?.exactIntValue, values.count > maximum {
      result.merge(
        issue(
          keyword: "maxProperties", instanceLocation: instanceLocation,
          schemaLocation: schemaLocation + "/maxProperties",
          message: "object has more than \(maximum) properties"))
    }
    if case .array(let required)? = schema["required"] {
      for raw in required {
        if case .string(let key) = raw, values[key] == nil {
          result.merge(
            issue(
              keyword: "required", instanceLocation: instanceLocation,
              schemaLocation: schemaLocation + "/required",
              message: "missing required property \(key)"))
        }
      }
    }

    let properties = schema["properties"]?.objectValue ?? [:]
    let patternSchemas = schema["patternProperties"]?.objectValue ?? [:]
    var matched: Set<String> = []
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
      if !patternSchemas.isEmpty { try ensureRegexInputWithinLimit(key) }
      if let propertySchema = properties[key] {
        result.merge(
          try evaluate(
            schema: propertySchema,
            schemaLocation: schemaLocation + "/properties/" + MCPJSONSchemaCompiler.escape(key),
            instance: value,
            instanceLocation: instanceLocation + "/" + MCPJSONSchemaCompiler.escape(key),
            depth: depth + 1), annotations: false)
        matched.insert(key)
        result.evaluatedProperties.insert(key)
      }
      for (pattern, patternSchema) in patternSchemas.sorted(by: { $0.key < $1.key }) {
        let expression = try compiled.regularExpression(
          at: schemaLocation + "/patternProperties/" + MCPJSONSchemaCompiler.escape(pattern))
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        if expression.firstMatch(in: key, range: range) != nil {
          result.merge(
            try evaluate(
              schema: patternSchema,
              schemaLocation: schemaLocation + "/patternProperties/"
                + MCPJSONSchemaCompiler.escape(pattern), instance: value,
              instanceLocation: instanceLocation + "/" + MCPJSONSchemaCompiler.escape(key),
              depth: depth + 1), annotations: false)
          matched.insert(key)
          result.evaluatedProperties.insert(key)
        }
      }
    }

    if let additional = schema["additionalProperties"] {
      for (key, value) in values.filter({ !matched.contains($0.key) }).sorted(by: {
        $0.key < $1.key
      }) {
        result.merge(
          try evaluate(
            schema: additional, schemaLocation: schemaLocation + "/additionalProperties",
            instance: value,
            instanceLocation: instanceLocation + "/" + MCPJSONSchemaCompiler.escape(key),
            depth: depth + 1), annotations: false)
        result.evaluatedProperties.insert(key)
      }
    }

    if compiled.dialect == .draft202012,
      case .object(let dependentRequired)? = schema["dependentRequired"]
    {
      for (trigger, rawDependencies) in dependentRequired.sorted(by: { $0.key < $1.key })
      where values[trigger] != nil {
        guard case .array(let dependencies) = rawDependencies else { continue }
        for dependency in dependencies {
          if case .string(let key) = dependency, values[key] == nil {
            result.merge(
              issue(
                keyword: "dependentRequired", instanceLocation: instanceLocation,
                schemaLocation: schemaLocation + "/dependentRequired/"
                  + MCPJSONSchemaCompiler.escape(trigger),
                message: "property \(trigger) requires \(key)"))
          }
        }
      }
    }

    if compiled.dialect == .draft202012,
      case .object(let dependentSchemas)? = schema["dependentSchemas"]
    {
      for (trigger, dependentSchema) in dependentSchemas.sorted(by: { $0.key < $1.key })
      where values[trigger] != nil {
        result.merge(
          try evaluate(
            schema: dependentSchema,
            schemaLocation: schemaLocation + "/dependentSchemas/"
              + MCPJSONSchemaCompiler.escape(trigger), instance: .object(values),
            instanceLocation: instanceLocation, depth: depth + 1))
      }
    }

    if compiled.dialect == .draft7, case .object(let dependencies)? = schema["dependencies"] {
      for (trigger, dependency) in dependencies.sorted(by: { $0.key < $1.key })
      where values[trigger] != nil {
        if dependency.isSchema {
          result.merge(
            try evaluate(
              schema: dependency,
              schemaLocation: schemaLocation + "/dependencies/"
                + MCPJSONSchemaCompiler.escape(trigger), instance: .object(values),
              instanceLocation: instanceLocation, depth: depth + 1))
        } else if case .array(let required) = dependency {
          for raw in required {
            if case .string(let key) = raw, values[key] == nil {
              result.merge(
                issue(
                  keyword: "dependencies", instanceLocation: instanceLocation,
                  schemaLocation: schemaLocation + "/dependencies/"
                    + MCPJSONSchemaCompiler.escape(trigger),
                  message: "property \(trigger) requires \(key)"))
            }
          }
        }
      }
    }

    if let names = schema["propertyNames"] {
      for key in values.keys.sorted() {
        result.merge(
          try evaluate(
            schema: names, schemaLocation: schemaLocation + "/propertyNames",
            instance: .string(key),
            instanceLocation: instanceLocation + "/" + MCPJSONSchemaCompiler.escape(key),
            depth: depth + 1), annotations: false)
      }
    }
    return result
  }

  private func ensureRegexInputWithinLimit(_ value: String) throws {
    guard value.utf8.count <= limits.maximumRegexInputBytes else {
      throw MCPJSONSchemaError.resourceLimit(
        "regex input exceeds " + String(limits.maximumRegexInputBytes) + " bytes")
    }
  }

  private func matchesType(_ value: MCPJSONValue, declared: MCPJSONValue) -> Bool {
    let names: [String]
    switch declared {
    case .string(let name): names = [name]
    case .array(let values): names = values.compactMap(\.stringValue)
    default: return false
    }
    return names.contains { name in
      switch (name, value) {
      case ("null", .null), ("boolean", .bool), ("object", .object), ("array", .array),
        ("number", .number), ("string", .string):
        true
      case ("integer", .number(let number)): number.isMathematicalInteger
      default: false
      }
    }
  }

  private func issue(
    keyword: String,
    instanceLocation: String,
    schemaLocation: String,
    message: String
  ) -> MCPJSONSchemaEvaluation {
    MCPJSONSchemaEvaluation(
      issues: [
        MCPJSONSchemaIssue(
          keyword: keyword, instanceLocation: instanceLocation, schemaLocation: schemaLocation,
          message: message)
      ]
    )
  }

  private func bounded(_ result: MCPJSONSchemaEvaluation) -> MCPJSONSchemaEvaluation {
    guard result.issues.count > limits.maximumIssues else { return result }
    var copy = result
    copy.issues = Array(copy.issues.prefix(limits.maximumIssues))
    return copy
  }
}

extension MCPJSONValue {
  fileprivate var isSchema: Bool {
    switch self {
    case .object, .bool: true
    default: false
    }
  }

  fileprivate func schemaSemanticEquals(_ other: MCPJSONValue) -> Bool {
    switch (self, other) {
    case (.null, .null): true
    case (.bool(let lhs), .bool(let rhs)): lhs == rhs
    case (.number(let lhs), .number(let rhs)): lhs.isNumericallyEqual(to: rhs)
    case (.string(let lhs), .string(let rhs)): lhs.utf8.elementsEqual(rhs.utf8)
    case (.array(let lhs), .array(let rhs)):
      lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.schemaSemanticEquals($1) }
    case (.object(let lhs), .object(let rhs)):
      lhs.count == rhs.count
        && lhs.allSatisfy { key, value in
          rhs[key].map(value.schemaSemanticEquals) == true
        }
    default: false
    }
  }

  fileprivate var schemaSemanticFingerprint: [UInt8] {
    switch self {
    case .null:
      return [0]
    case .bool(let value):
      return [1, UInt8(value ? 1 : 0)]
    case .number(let value):
      return [2] + lengthPrefixed(Array(value.schemaSemanticKey.utf8))
    case .string(let value):
      return [3] + lengthPrefixed(Array(value.utf8))
    case .array(let values):
      return [4] + values.flatMap { lengthPrefixed($0.schemaSemanticFingerprint) }
    case .object(let values):
      return [5]
        + values.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) })
        .flatMap { key, value in
          lengthPrefixed(Array(key.utf8)) + lengthPrefixed(value.schemaSemanticFingerprint)
        }
    }
  }

  private func lengthPrefixed(_ bytes: [UInt8]) -> [UInt8] {
    let count = UInt64(bytes.count)
    var result: [UInt8] = []
    for shift in stride(from: 56, through: 0, by: -8) {
      result.append(UInt8((count >> UInt64(shift)) & 0xff))
    }
    result.append(contentsOf: bytes)
    return result
  }

  fileprivate func value(atJSONPointer pointer: String) -> MCPJSONValue? {
    guard pointer.isEmpty || pointer.hasPrefix("/") else { return nil }
    if pointer.isEmpty { return self }
    var current = self
    for rawComponent in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    {
      let component = String(rawComponent)
        .replacingOccurrences(of: "~1", with: "/")
        .replacingOccurrences(of: "~0", with: "~")
      switch current {
      case .object(let object):
        guard let next = object[component] else { return nil }
        current = next
      case .array(let array):
        guard component != "-", let index = Int(component), index >= 0, index < array.count,
          String(index) == component
        else { return nil }
        current = array[index]
      default:
        return nil
      }
    }
    return current
  }
}
