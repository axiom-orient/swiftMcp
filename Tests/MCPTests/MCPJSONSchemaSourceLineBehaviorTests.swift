import XCTest

@testable import MCP

final class MCPJSONSchemaSourceLineBehaviorTests: XCTestCase {
  private let validator = MCPJSONSchemaValidator()

  private func number(_ literal: String) throws -> MCPJSONValue {
    .number(try MCPJSONNumber(rawValue: literal))
  }

  private func invalidSchemaIssues(
    _ schema: MCPJSONValue,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> [MCPJSONSchemaIssue] {
    do {
      try validator.validateSchema(schema)
      XCTFail("expected invalid schema", file: file, line: line)
      return []
    } catch let MCPJSONSchemaError.invalidSchema(issues) {
      return issues
    } catch {
      XCTFail("unexpected error: \(error)", file: file, line: line)
      return []
    }
  }

  private func validationIssues(
    _ instance: MCPJSONValue,
    against schema: MCPJSONValue,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> [MCPJSONSchemaIssue] {
    do {
      try validator.validate(instance, against: schema)
      XCTFail("expected schema validation failure", file: file, line: line)
      return []
    } catch let MCPJSONSchemaError.validationFailed(issues) {
      return issues
    } catch {
      XCTFail("unexpected error: \(error)", file: file, line: line)
      return []
    }
  }

  func testDefault202012CompositionSelectsThenElseAndNotBranches() throws {
    let schema: MCPJSONValue = .object([
      "type": .string("object"),
      "oneOf": .array([
        .object([
          "properties": .object(["kind": .object(["const": .string("numeric")])]),
          "required": .array([.string("kind")]),
        ]),
        .object([
          "properties": .object(["kind": .object(["const": .string("text")])]),
          "required": .array([.string("kind")]),
        ]),
      ]),
      "if": .object([
        "properties": .object(["kind": .object(["const": .string("numeric")])]),
        "required": .array([.string("kind")]),
      ]),
      "then": .object([
        "properties": .object(["count": .object(["minimum": .integer(1)])]),
        "required": .array([.string("count")]),
      ]),
      "else": .object([
        "properties": .object(["text": .object(["minLength": .integer(3)])]),
        "required": .array([.string("text")]),
      ]),
      "not": .object([
        "properties": .object(["forbidden": .object(["const": .bool(true)])]),
        "required": .array([.string("forbidden")]),
      ]),
    ])

    try validator.validate(
      .object(["kind": .string("numeric"), "count": .integer(1)]), against: schema)
    let numericIssues = validationIssues(
      .object(["kind": .string("numeric"), "count": .integer(0), "forbidden": .bool(true)]),
      against: schema
    )
    XCTAssertTrue(numericIssues.contains { $0.keyword == "minimum" })
    XCTAssertTrue(numericIssues.contains { $0.keyword == "not" })

    let textIssues = validationIssues(
      .object(["kind": .string("text"), "text": .string("x")]),
      against: schema
    )
    XCTAssertTrue(textIssues.contains { $0.keyword == "minLength" })
  }

  func testObjectKeywordsTrackPatternPropertiesDependenciesAndPropertyNames() throws {
    let schema: MCPJSONValue = .object([
      "type": .string("object"),
      "minProperties": .integer(2),
      "maxProperties": .integer(3),
      "properties": .object([
        "primary": .object(["type": .string("string")]),
        "secondary": .object(["type": .string("string")]),
      ]),
      "patternProperties": .object(["^x-": .object(["type": .string("integer")])]),
      "additionalProperties": .bool(false),
      "propertyNames": .object(["pattern": .string("^[a-z-]+$")]),
      "dependentRequired": .object(["primary": .array([.string("secondary")])]),
      "dependentSchemas": .object([
        "secondary": .object([
          "properties": .object(["secondary": .object(["minLength": .integer(2)])])
        ])
      ]),
    ])

    let issues = validationIssues(
      .object([
        "primary": .string("p"),
        "secondary": .string("x"),
        "x-count": .string("wrong"),
        "Unexpected": .bool(true),
      ]),
      against: schema
    )
    for keyword in ["maxProperties", "minLength", "type", "falseSchema", "pattern"] {
      XCTAssertTrue(issues.contains { $0.keyword == keyword }, keyword)
    }

    let missingDependency = validationIssues(.object(["primary": .string("p")]), against: schema)
    XCTAssertTrue(missingDependency.contains { $0.keyword == "dependentRequired" })
  }

  func testSchemaLimitsFailClosedForRegexUniqueItemsAndEvaluationWork() throws {
    let constrained = MCPJSONSchemaValidator(
      limits: MCPJSONSchemaLimits(maximumRegexBytes: 3, maximumUniqueItems: 2)
    )
    XCTAssertThrowsError(
      try constrained.validateSchema(
        .object(["type": .string("string"), "pattern": .string("abcd")]))
    ) { error in
      guard case MCPJSONSchemaError.invalidSchema(let issues) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(issues.contains { $0.keyword == "pattern" })
    }

    XCTAssertThrowsError(
      try constrained.validate(
        .array([.integer(1), .integer(2), .integer(3)]),
        against: .object(["type": .string("array"), "uniqueItems": .bool(true)])
      )
    ) { error in
      XCTAssertEqual(error as? MCPJSONSchemaError, .resourceLimit("uniqueItems exceeds 2 values"))
    }

    let boundedEvaluations = MCPJSONSchemaValidator(
      limits: MCPJSONSchemaLimits(maximumEvaluations: 1)
    )
    XCTAssertThrowsError(
      try boundedEvaluations.validate(
        .string("value"),
        against: .object(["allOf": .array([.object(["type": .string("string")])])])
      )
    ) { error in
      XCTAssertEqual(
        error as? MCPJSONSchemaError,
        .resourceLimit("validation evaluations exceed 1")
      )
    }
  }

  func testRegexSafetyRejectsCatastrophicBacktrackingShapesBeforeEvaluation() throws {
    let patterns: [(String, MCPJSONValue)] = [
      (
        "pattern",
        .object(["type": .string("string"), "pattern": .string("^(a+)+$")])
      ),
      (
        "patternProperties",
        .object([
          "type": .string("object"),
          "patternProperties": .object(["^(a+)+$": .bool(true)]),
        ])
      ),
    ]

    for (keyword, schema) in patterns {
      let issues = invalidSchemaIssues(schema)
      XCTAssertTrue(
        issues.contains {
          $0.keyword == keyword && $0.message.contains("excessive backtracking")
        },
        "expected bounded regex rejection for \(keyword)"
      )
    }
  }

  func testRegexInputLimitFailsClosedForPropertyNamesAndPatterns() throws {
    let validator = MCPJSONSchemaValidator(
      limits: MCPJSONSchemaLimits(maximumRegexInputBytes: 4)
    )
    let stringSchema: MCPJSONValue = .object([
      "type": .string("string"),
      "pattern": .string("^a+$"),
    ])
    XCTAssertThrowsError(
      try validator.validate(.string("aaaaa"), against: stringSchema)
    ) { error in
      XCTAssertEqual(
        error as? MCPJSONSchemaError,
        .resourceLimit("regex input exceeds 4 bytes")
      )
    }

    let objectSchema: MCPJSONValue = .object([
      "type": .string("object"),
      "patternProperties": .object(["^x-": .bool(true)]),
    ])
    XCTAssertThrowsError(
      try validator.validate(.object(["x-aaaaa": .null]), against: objectSchema)
    ) { error in
      XCTAssertEqual(
        error as? MCPJSONSchemaError,
        .resourceLimit("regex input exceeds 4 bytes")
      )
    }
  }

  func testRegexSafetyAllowsDisjointAlternationAndDelimitedNestedQuantifiers() throws {
    let patterns = [
      ("^([A-Za-z0-9]|-)*$", "abc-123"),
      ("^(\\w+,)*\\w+$", "one,two,three"),
      ("^(/[a-z]+)+$", "/abc/def"),
      ("^\\w+(\\s\\w+)*$", "one two three"),
    ]

    for (pattern, value) in patterns {
      let schema: MCPJSONValue = .object([
        "type": .string("string"),
        "pattern": .string(pattern),
      ])
      do {
        try validator.validateSchema(schema)
      } catch {
        XCTFail("pattern was rejected unexpectedly: \(pattern): \(error)")
      }
      try validator.validate(.string(value), against: schema)
    }
  }

  func testRegexSafetyRejectsOverlappingAdjacentQuantifiers() throws {
    let patterns = [
      "^a*a*a*a*a*a*b$",
      "^(a|aa)+$",
    ]

    for pattern in patterns {
      let issues = invalidSchemaIssues(
        .object(["type": .string("string"), "pattern": .string(pattern)])
      )
      XCTAssertTrue(
        issues.contains { $0.message.contains("excessive backtracking") },
        "expected bounded regex rejection for \(pattern)"
      )
    }
  }

  func testRegexSafetyRejectsSeparatorsTheRepeatedAtomCanAlsoConsume() throws {
    // A group is only delimited when no repeated atom beside the separator can consume it.
    // Counting mandatory atoms alone would accept these and backtrack exponentially.
    let patterns = [
      "^([a-z]+a)+$",
      "^(\\w+_)+$",
      "^((ab)+b)+$",
    ]

    for pattern in patterns {
      let issues = invalidSchemaIssues(
        .object(["type": .string("string"), "pattern": .string(pattern)])
      )
      XCTAssertTrue(
        issues.contains { $0.message.contains("excessive backtracking") },
        "expected bounded regex rejection for \(pattern)"
      )
    }
  }

  func testRegexSafetyKeepsSeparatorsDisjointFromTheRepeatedAtom() throws {
    let patterns = [
      ("^(ab+)+$", "abbab"),
      ("^(a?b)+$", "abb"),
      ("^(\\d{4}-)+$", "2026-0728-"),
    ]

    for (pattern, value) in patterns {
      let schema: MCPJSONValue = .object([
        "type": .string("string"),
        "pattern": .string(pattern),
      ])
      do {
        try validator.validateSchema(schema)
      } catch {
        XCTFail("pattern was rejected unexpectedly: \(pattern): \(error)")
      }
      try validator.validate(.string(value), against: schema)
    }
  }

  func testInvalidLimitsAndUnsupportedDialectReportExplicitErrors() {
    let invalidLimits: [(String, MCPJSONSchemaLimits)] = [
      ("maximumSchemaDepth", MCPJSONSchemaLimits(maximumSchemaDepth: 0)),
      ("maximumInstanceDepth", MCPJSONSchemaLimits(maximumInstanceDepth: 0)),
      ("maximumEvaluations", MCPJSONSchemaLimits(maximumEvaluations: 0)),
      ("maximumIssues", MCPJSONSchemaLimits(maximumIssues: 0)),
      ("maximumRegexBytes", MCPJSONSchemaLimits(maximumRegexBytes: 0)),
      ("maximumRegexInputBytes", MCPJSONSchemaLimits(maximumRegexInputBytes: 0)),
      ("maximumUniqueItems", MCPJSONSchemaLimits(maximumUniqueItems: 0)),
      ("maximumPowerExpansion", MCPJSONSchemaLimits(maximumPowerExpansion: 0)),
    ]
    for (name, limits) in invalidLimits {
      XCTAssertThrowsError(try MCPJSONSchemaValidator(limits: limits).validateSchema(.bool(true))) {
        error in
        XCTAssertEqual(error as? MCPJSONSchemaError, .invalidLimit(name))
      }
    }

    XCTAssertThrowsError(
      try validator.validateSchema(.object(["$schema": .string("https://example.com/custom")]))
    ) { error in
      guard case MCPJSONSchemaError.invalidSchema(let issues) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(issues.contains { $0.keyword == "$schema" })
    }
  }

  func testInvalid202012SchemasReportExactKeywordsAndLocations() {
    let cases: [(String, MCPJSONValue, String, String)] = [
      ("non-schema root", .string("schema"), "schema", "#"),
      ("non-string dialect", .object(["$schema": .integer(2020)]), "$schema", "#/$schema"),
      ("non-string id", .object(["$id": .integer(1)]), "$id", "#/$id"),
      (
        "fragment-bearing id",
        .object(["$id": .string("schemas/root.json#part")]),
        "$id",
        "#/$id"
      ),
      ("invalid anchor", .object(["$anchor": .string("9bad")]), "$anchor", "#/$anchor"),
      (
        "duplicate anchor",
        .object([
          "$defs": .object([
            "a": .object(["$anchor": .string("same")]),
            "b": .object(["$anchor": .string("same")]),
          ])
        ]),
        "$anchor",
        "#/$defs/b/$anchor"
      ),
      ("invalid vocabulary", .object(["$vocabulary": .array([])]), "$vocabulary", "#/$vocabulary"),
      (
        "format assertion vocabulary",
        .object([
          "$vocabulary": .object([
            "https://json-schema.org/draft/2020-12/vocab/format-assertion": .bool(true)
          ])
        ]),
        "$vocabulary",
        "#/$vocabulary"
      ),
      ("non-string ref", .object(["$ref": .integer(1)]), "$ref", "#/$ref"),
      ("empty anyOf", .object(["anyOf": .array([])]), "anyOf", "#/anyOf"),
      ("invalid properties", .object(["properties": .array([])]), "properties", "#/properties"),
      ("invalid items", .object(["items": .array([])]), "items", "#/items"),
      ("unknown type", .object(["type": .string("decimal")]), "type", "#/type"),
      (
        "duplicate required",
        .object(["required": .array([.string("id"), .string("id")])]),
        "required",
        "#/required"
      ),
      ("zero multipleOf", .object(["multipleOf": .integer(0)]), "multipleOf", "#/multipleOf"),
      ("negative minLength", .object(["minLength": .integer(-1)]), "minLength", "#/minLength"),
    ]

    for (name, schema, keyword, location) in cases {
      let issues = invalidSchemaIssues(schema)
      XCTAssertEqual(issues.count, 1, name)
      XCTAssertEqual(issues.first?.keyword, keyword, name)
      XCTAssertEqual(issues.first?.schemaLocation, location, name)
      XCTAssertEqual(issues.first?.instanceLocation, "#", name)
    }
  }

  func testLocalAnchorAbsoluteSelfAndEscapedArrayPointersResolveWithoutExternalFallback() throws {
    let schema: MCPJSONValue = .object([
      "$id": .string("https://example.com/root"),
      "$defs": .object([
        "anchored": .object([
          "$anchor": .string("name"),
          "type": .string("string"),
        ]),
        "array-target": .object([
          "prefixItems": .array([
            .object(["type": .string("boolean")])
          ])
        ]),
        "a/b~c": .object(["type": .string("integer")]),
      ]),
      "type": .string("object"),
      "properties": .object([
        "anchor": .object(["$ref": .string("#name")]),
        "absolute": .object(["$ref": .string("https://example.com/root#name")]),
        "array": .object(["$ref": .string("#/$defs/array-target/prefixItems/0")]),
        "escaped": .object(["$ref": .string("#/$defs/a~1b~0c")]),
      ]),
    ])

    try validator.validate(
      .object([
        "anchor": .string("a"),
        "absolute": .string("b"),
        "array": .bool(true),
        "escaped": .integer(1),
      ]),
      against: schema
    )
    let issues = validationIssues(
      .object([
        "anchor": .integer(1),
        "absolute": .bool(false),
        "array": .string("wrong"),
        "escaped": .string("wrong"),
      ]),
      against: schema
    )
    XCTAssertEqual(issues.count, 4)
    XCTAssertTrue(
      issues.contains {
        $0.keyword == "type" && $0.instanceLocation == "#/anchor"
          && $0.schemaLocation == "#/$defs/anchored/type"
      })
    XCTAssertTrue(
      issues.contains {
        $0.keyword == "type" && $0.instanceLocation == "#/absolute"
          && $0.schemaLocation == "#/$defs/anchored/type"
      })
    XCTAssertTrue(
      issues.contains {
        $0.keyword == "type" && $0.instanceLocation == "#/array"
          && $0.schemaLocation == "#/$defs/array-target/prefixItems/0/type"
      })
    XCTAssertTrue(
      issues.contains {
        $0.keyword == "type" && $0.instanceLocation == "#/escaped"
          && $0.schemaLocation == "#/$defs/a~1b~0c/type"
      })

    let sibling202012: MCPJSONValue = .object([
      "$defs": .object(["text": .object(["type": .string("string")])]),
      "$ref": .string("#/$defs/text"),
      "minLength": .integer(3),
    ])
    let siblingIssues = validationIssues(.string("ab"), against: sibling202012)
    XCTAssertEqual(siblingIssues.count, 1)
    XCTAssertEqual(siblingIssues[0].keyword, "minLength")
    XCTAssertEqual(siblingIssues[0].schemaLocation, "#/minLength")

    let siblingDraft7: MCPJSONValue = .object([
      "$schema": .string("http://json-schema.org/draft-07/schema#"),
      "definitions": .object(["text": .object(["type": .string("string")])]),
      "$ref": .string("#/definitions/text"),
      "minLength": .integer(3),
    ])
    try validator.validate(.string("ab"), against: siblingDraft7)

    for (reference, messageFragment) in [
      ("#missing", "unresolved local reference"),
      ("https://other.example/schema", "custom schema validator"),
    ] {
      let referenceIssues = invalidSchemaIssues(.object(["$ref": .string(reference)]))
      XCTAssertEqual(referenceIssues.count, 1)
      XCTAssertEqual(referenceIssues.first?.keyword, "$ref")
      XCTAssertEqual(referenceIssues.first?.schemaLocation, "#/$ref")
      XCTAssertTrue(referenceIssues.first?.message.contains(messageFragment) == true)
    }
  }

  func testRelativeRootIdentifierUsesSyntheticBaseForLocalAndRelativeSelfReferences() throws {
    let schema: MCPJSONValue = .object([
      "$id": .string("schemas/root.json"),
      "$defs": .object([
        "text": .object([
          "type": .string("string"),
          "minLength": .integer(2),
        ])
      ]),
      "type": .string("object"),
      "properties": .object([
        "local": .object(["$ref": .string("#/$defs/text")]),
        "relative": .object(["$ref": .string("root.json#/$defs/text")]),
      ]),
    ])

    try validator.validate(
      .object(["local": .string("ok"), "relative": .string("ok")]),
      against: schema
    )
    let issues = validationIssues(
      .object(["local": .string("x"), "relative": .string("y")]),
      against: schema
    )
    XCTAssertEqual(issues.count, 2)
    XCTAssertEqual(Set(issues.map(\.keyword)), ["minLength"])
    XCTAssertEqual(Set(issues.map(\.schemaLocation)), ["#/$defs/text/minLength"])
    XCTAssertEqual(Set(issues.map(\.instanceLocation)), ["#/local", "#/relative"])
  }

  func testRecursiveReferencesMustAdvanceAndRespectExactInstanceDepthLimit() throws {
    let recursive: MCPJSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "next": .object([
          "anyOf": .array([
            .object(["type": .string("null")]),
            .object(["$ref": .string("#")]),
          ])
        ])
      ]),
    ])
    let nested: MCPJSONValue = .object([
      "next": .object([
        "next": .object([
          "next": .null
        ])
      ])
    ])

    try validator.validate(nested, against: recursive)

    XCTAssertThrowsError(
      try validator.validate(.integer(1), against: .object(["$ref": .string("#")]))
    ) { error in
      guard case MCPJSONSchemaError.invalidSchema(let issues) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(issues.count, 1)
      XCTAssertEqual(issues[0].keyword, "$ref")
      XCTAssertEqual(issues[0].schemaLocation, "#")
      XCTAssertEqual(issues[0].instanceLocation, "#")
    }

    let bounded = MCPJSONSchemaValidator(
      limits: MCPJSONSchemaLimits(maximumInstanceDepth: 2)
    )
    XCTAssertThrowsError(try bounded.validate(nested, against: recursive)) { error in
      XCTAssertEqual(
        error as? MCPJSONSchemaError,
        .resourceLimit("instance depth exceeds 2")
      )
    }
  }

  func testAnyOfUnionsAnnotationsBeforeUnevaluatedChecksAndOneOfRejectsAmbiguity() throws {
    let objectSchema: MCPJSONValue = .object([
      "anyOf": .array([
        .object([
          "properties": .object(["a": .bool(true)]),
          "required": .array([.string("a")]),
        ]),
        .object([
          "properties": .object(["b": .bool(true)]),
          "required": .array([.string("b")]),
        ]),
      ]),
      "unevaluatedProperties": .bool(false),
    ])
    try validator.validate(.object(["a": .integer(1), "b": .integer(2)]), against: objectSchema)
    let propertyIssues = validationIssues(
      .object(["a": .integer(1), "b": .integer(2), "c": .integer(3)]),
      against: objectSchema
    )
    XCTAssertEqual(propertyIssues.count, 1)
    XCTAssertEqual(propertyIssues[0].keyword, "falseSchema")
    XCTAssertEqual(propertyIssues[0].instanceLocation, "#/c")
    XCTAssertEqual(propertyIssues[0].schemaLocation, "#/unevaluatedProperties")

    let conditionalSchema: MCPJSONValue = .object([
      "if": .object([
        "properties": .object(["kind": .object(["const": .string("text")])]),
        "required": .array([.string("kind")]),
      ]),
      "then": .object([
        "properties": .object(["value": .object(["type": .string("string")])])
      ]),
      "unevaluatedProperties": .bool(false),
    ])
    try validator.validate(
      .object(["kind": .string("text"), "value": .string("hello")]),
      against: conditionalSchema
    )

    let arraySchema: MCPJSONValue = .object([
      "anyOf": .array([
        .object(["prefixItems": .array([.bool(true)])]),
        .object(["contains": .object(["const": .integer(2)])]),
      ]),
      "unevaluatedItems": .bool(false),
    ])
    try validator.validate(.array([.integer(1), .integer(2)]), against: arraySchema)
    let itemIssues = validationIssues(
      .array([.integer(1), .integer(2), .integer(3)]),
      against: arraySchema
    )
    XCTAssertEqual(itemIssues.count, 1)
    XCTAssertEqual(itemIssues[0].keyword, "falseSchema")
    XCTAssertEqual(itemIssues[0].instanceLocation, "#/2")
    XCTAssertEqual(itemIssues[0].schemaLocation, "#/unevaluatedItems")

    let ambiguity = validationIssues(
      .integer(1),
      against: .object([
        "oneOf": .array([
          .object(["type": .string("number")]),
          .object(["minimum": .integer(0)]),
        ])
      ])
    )
    XCTAssertEqual(ambiguity.count, 1)
    XCTAssertEqual(ambiguity[0].keyword, "oneOf")
    XCTAssertEqual(ambiguity[0].schemaLocation, "#/oneOf")
  }

  func testPrimitiveBoundariesDraft7SchemaItemsAndIssueCap() throws {
    let numericSchema: MCPJSONValue = .object([
      "multipleOf": try number("0.5"),
      "minimum": .integer(0),
      "maximum": .integer(10),
      "exclusiveMinimum": .integer(0),
      "exclusiveMaximum": .integer(10),
    ])
    for value in [try number("0.5"), .integer(5), try number("9.5")] {
      try validator.validate(value, against: numericSchema)
    }
    for (value, keyword) in [
      (MCPJSONValue.integer(0), "exclusiveMinimum"),
      (MCPJSONValue.integer(10), "exclusiveMaximum"),
      (try number("0.75"), "multipleOf"),
    ] {
      let issues = validationIssues(value, against: numericSchema)
      XCTAssertEqual(issues.count, 1)
      XCTAssertEqual(issues[0].keyword, keyword)
      XCTAssertEqual(issues[0].schemaLocation, "#/\(keyword)")
    }

    let stringSchema: MCPJSONValue = .object([
      "minLength": .integer(2),
      "maxLength": .integer(3),
      "pattern": .string("^[A-Z]+$"),
    ])
    try validator.validate(.string("AB"), against: stringSchema)
    try validator.validate(.string("ABC"), against: stringSchema)
    for (value, keyword) in [("A", "minLength"), ("ABCD", "maxLength"), ("Ab", "pattern")] {
      let issues = validationIssues(.string(value), against: stringSchema)
      XCTAssertEqual(issues.count, 1)
      XCTAssertEqual(issues[0].keyword, keyword)
      XCTAssertEqual(issues[0].schemaLocation, "#/\(keyword)")
    }

    let arraySchema: MCPJSONValue = .object([
      "minItems": .integer(2),
      "maxItems": .integer(3),
      "uniqueItems": .bool(true),
      "contains": .object(["minimum": .integer(10)]),
      "minContains": .integer(1),
      "maxContains": .integer(1),
    ])
    try validator.validate(.array([.integer(1), .integer(10)]), against: arraySchema)
    for (value, keyword) in [
      (MCPJSONValue.array([.integer(10)]), "minItems"),
      (MCPJSONValue.array([.integer(1), .integer(10), .integer(2), .integer(3)]), "maxItems"),
    ] {
      let issues = validationIssues(value, against: arraySchema)
      XCTAssertEqual(issues.count, 1)
      XCTAssertEqual(issues[0].keyword, keyword)
      XCTAssertEqual(issues[0].schemaLocation, "#/\(keyword)")
    }
    let duplicateIssues = validationIssues(
      .array([.integer(10), .integer(10)]), against: arraySchema)
    XCTAssertEqual(Set(duplicateIssues.map(\.keyword)), ["uniqueItems", "contains"])
    XCTAssertEqual(
      Set(duplicateIssues.map(\.schemaLocation)), ["#/uniqueItems", "#/contains"])

    let draft7Items: MCPJSONValue = .object([
      "$schema": .string("http://json-schema.org/draft-07/schema#"),
      "type": .string("array"),
      "items": .object(["type": .string("integer")]),
    ])
    try validator.validate(.array([.integer(1), .integer(2)]), against: draft7Items)
    let draft7Issues = validationIssues(
      .array([.integer(1), .string("two")]), against: draft7Items)
    XCTAssertEqual(draft7Issues.count, 1)
    XCTAssertEqual(draft7Issues[0].keyword, "type")
    XCTAssertEqual(draft7Issues[0].instanceLocation, "#/1")
    XCTAssertEqual(draft7Issues[0].schemaLocation, "#/items/type")

    let capped = MCPJSONSchemaValidator(limits: MCPJSONSchemaLimits(maximumIssues: 2))
    XCTAssertThrowsError(
      try capped.validate(
        .object([:]),
        against: .object([
          "required": .array([.string("a"), .string("b"), .string("c")])
        ])
      )
    ) { error in
      guard case MCPJSONSchemaError.validationFailed(let issues) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(issues.count, 2)
      XCTAssertEqual(issues.map(\.keyword), ["required", "required"])
      XCTAssertEqual(issues.map(\.schemaLocation), ["#/required", "#/required"])
      XCTAssertTrue(issues[0].message.contains("a"))
      XCTAssertTrue(issues[1].message.contains("b"))
    }
  }
}
