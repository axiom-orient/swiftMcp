import XCTest

@testable import MCP

final class MCPJSONSchemaTests: XCTestCase {
  private let validator = MCPJSONSchemaValidator()

  private func number(_ literal: String) throws -> MCPJSONValue {
    .number(try MCPJSONNumber(rawValue: literal))
  }

  func testObjectStringAndExactNumberConstraints() throws {
    let schema: MCPJSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "name": .object([
          "type": .string("string"),
          "minLength": .integer(2),
          "pattern": .string("^[A-Z]"),
        ]),
        "amount": .object([
          "type": .string("number"),
          "minimum": try number("9007199254740993"),
          "multipleOf": try number("0.000000000000000001"),
        ]),
      ]),
      "required": .array([.string("name"), .string("amount")]),
      "additionalProperties": .bool(false),
    ])

    try validator.validate(
      .object([
        "name": .string("Ada"),
        "amount": try number("9007199254740993.000000000000000001"),
      ]),
      against: schema
    )

    XCTAssertThrowsError(
      try validator.validate(
        .object([
          "name": .string("ada"),
          "amount": try number("9007199254740992.999999999999999999"),
          "extra": .bool(true),
        ]),
        against: schema
      )
    ) { error in
      guard case MCPJSONSchemaError.validationFailed(let issues) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(issues.contains { $0.keyword == "pattern" })
      XCTAssertTrue(issues.contains { $0.keyword == "minimum" })
      XCTAssertTrue(issues.contains { $0.keyword == "falseSchema" })
    }
  }

  func testLocalReferenceCompositionAndUnevaluatedProperties() throws {
    let schema: MCPJSONValue = .object([
      "$defs": .object([
        "identifier": .object([
          "type": .string("string"),
          "pattern": .string("^[a-z]+$"),
        ])
      ]),
      "allOf": .array([
        .object([
          "type": .string("object"),
          "properties": .object([
            "id": .object(["$ref": .string("#/$defs/identifier")])
          ]),
          "required": .array([.string("id")]),
        ]),
        .object([
          "type": .string("object"),
          "properties": .object([
            "kind": .object(["enum": .array([.string("record")])])
          ]),
          "required": .array([.string("kind")]),
        ]),
      ]),
      "unevaluatedProperties": .bool(false),
    ])

    try validator.validate(
      .object(["id": .string("abc"), "kind": .string("record")]),
      against: schema
    )
    XCTAssertThrowsError(
      try validator.validate(
        .object(["id": .string("abc"), "kind": .string("record"), "extra": .integer(1)]),
        against: schema
      )
    )
  }

  func testDefaultDialectCompilesLegacyDefinitionsReferencedByJSONPointer() throws {
    let schema: MCPJSONValue = .object([
      "type": .string("object"),
      "definitions": .object([
        "capitalIdentifier": .object([
          "type": .string("string"),
          "pattern": .string("^[A-Z]+$"),
        ])
      ]),
      "properties": .object([
        "value": .object(["$ref": .string("#/definitions/capitalIdentifier")])
      ]),
    ])

    XCTAssertNoThrow(
      try validator.validate(.object(["value": .string("MCP")]), against: schema))
  }

  func testDraft7CompilesLegacyDefsReferencedAfterCompatibilityTraversal() throws {
    let schema: MCPJSONValue = .object([
      "$schema": .string("https://json-schema.org/draft-07/schema#"),
      "$defs": .object([
        "identifier": .object([
          "type": .string("string"),
          "pattern": .string("^[A-Z]+$"),
        ])
      ]),
      "dependencies": .object([
        "trigger": .object([
          "properties": .object([
            "value": .object(["$ref": .string("#/$defs/identifier")])
          ])
        ])
      ]),
    ])

    XCTAssertNoThrow(
      try validator.validate(
        .object(["trigger": .bool(true), "value": .string("MCP")]),
        against: schema
      ))
  }

  func testDefaultDialectCompilesNestedLegacyDefinitionsReferencedLaterInTraversal() throws {
    let schema: MCPJSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "a": .object([
          "definitions": .object([
            "identifier": .object([
              "type": .string("string"),
              "pattern": .string("^[A-Z]+$"),
            ])
          ])
        ]),
        "z": .object(["$ref": .string("#/properties/a/definitions/identifier")]),
      ]),
    ])

    XCTAssertNoThrow(
      try validator.validate(.object(["z": .string("MCP")]), against: schema))
  }

  func testCompatibilityReferencesReachAFixedPoint() throws {
    let schema: MCPJSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "value": .object(["$ref": .string("#/definitions/entry")])
      ]),
      "definitions": .object([
        "entry": .object(["$ref": .string("#/definitions/identifier")]),
        "identifier": .object([
          "type": .string("string"),
          "pattern": .string("^[A-Z]+$"),
        ]),
      ]),
    ])

    XCTAssertNoThrow(
      try validator.validate(.object(["value": .string("MCP")]), against: schema))
  }

  func testReferencedCompatibilityDefinitionDoesNotCompileUnrelatedSibling() throws {
    let schema: MCPJSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "value": .object(["$ref": .string("#/definitions/identifier")])
      ]),
      "definitions": .object([
        "identifier": .object([
          "type": .string("string"),
          "pattern": .string("^[A-Z]+$"),
        ]),
        "externalOnly": .object(["$ref": .string("https://example.invalid/schema")]),
      ]),
    ])

    XCTAssertNoThrow(
      try validator.validate(.object(["value": .string("MCP")]), against: schema))
  }

  func testArrayKeywordsAndSemanticUniqueness() throws {
    let schema: MCPJSONValue = .object([
      "type": .string("array"),
      "prefixItems": .array([
        .object(["type": .string("string")])
      ]),
      "items": .object(["type": .string("integer")]),
      "contains": .object([
        "type": .string("integer"),
        "minimum": .integer(10),
      ]),
      "minContains": .integer(1),
      "uniqueItems": .bool(true),
    ])

    try validator.validate(
      .array([.string("head"), .integer(10), .integer(11)]),
      against: schema
    )
    XCTAssertThrowsError(
      try validator.validate(
        .array([.string("head"), .integer(1), try number("1.0")]),
        against: schema
      )
    ) { error in
      guard case MCPJSONSchemaError.validationFailed(let issues) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(issues.contains { $0.keyword == "uniqueItems" })
      XCTAssertTrue(issues.contains { $0.keyword == "contains" })
    }
  }

  /// An instance shorter than the positional schemas leaves no positions for `items` or
  /// `additionalItems`. Both dialects must evaluate the remaining keywords instead of forming an
  /// invalid range, because the instance is peer-supplied tool input.
  func testPositionalSchemasAcceptInstancesShorterThanTheDeclaredPositions() throws {
    let schema: MCPJSONValue = .object([
      "type": .string("array"),
      "prefixItems": .array([
        .object(["type": .string("string")]),
        .object(["type": .string("string")]),
      ]),
      "items": .object(["type": .string("integer")]),
    ])

    try validator.validate(.array([]), against: schema)
    try validator.validate(.array([.string("head")]), against: schema)
    try validator.validate(.array([.string("head"), .string("second")]), against: schema)
    try validator.validate(
      .array([.string("head"), .string("second"), .integer(3)]),
      against: schema
    )
    XCTAssertThrowsError(try validator.validate(.array([.integer(1)]), against: schema))

    let minimumItems: MCPJSONValue = .object([
      "type": .string("array"),
      "prefixItems": .array([.object(["type": .string("string")])]),
      "items": .object(["type": .string("integer")]),
      "minItems": .integer(1),
    ])
    XCTAssertThrowsError(try validator.validate(.array([]), against: minimumItems)) { error in
      guard case MCPJSONSchemaError.validationFailed(let issues) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(issues.contains { $0.keyword == "minItems" })
    }

    let draft7: MCPJSONValue = .object([
      "$schema": .string("http://json-schema.org/draft-07/schema#"),
      "type": .string("array"),
      "items": .array([
        .object(["type": .string("string")]),
        .object(["type": .string("integer")]),
      ]),
      "additionalItems": .bool(false),
    ])

    try validator.validate(.array([]), against: draft7)
    try validator.validate(.array([.string("a")]), against: draft7)
    try validator.validate(.array([.string("a"), .integer(2)]), against: draft7)
    XCTAssertThrowsError(
      try validator.validate(.array([.string("a"), .integer(2), .integer(3)]), against: draft7)
    )
    XCTAssertThrowsError(try validator.validate(.array([.integer(1)]), against: draft7))
  }

  func testDraft7TupleAndDependencies() throws {
    let schema: MCPJSONValue = .object([
      "$schema": .string("http://json-schema.org/draft-07/schema#"),
      "type": .string("object"),
      "properties": .object([
        "tuple": .object([
          "type": .string("array"),
          "items": .array([
            .object(["type": .string("string")]),
            .object(["type": .string("integer")]),
          ]),
          "additionalItems": .bool(false),
        ]),
        "creditCard": .object(["type": .string("string")]),
        "billingAddress": .object(["type": .string("string")]),
      ]),
      "dependencies": .object([
        "creditCard": .array([.string("billingAddress")])
      ]),
    ])

    try validator.validate(
      .object([
        "tuple": .array([.string("a"), .integer(2)]),
        "creditCard": .string("x"),
        "billingAddress": .string("y"),
      ]),
      against: schema
    )
    XCTAssertThrowsError(
      try validator.validate(
        .object([
          "tuple": .array([.string("a"), .integer(2), .integer(3)]),
          "creditCard": .string("x"),
        ]),
        against: schema
      )
    )
  }

  func testRejectsUnsupportedRemoteAndExternalDynamicReferencesExplicitly() throws {
    XCTAssertThrowsError(
      try validator.validateSchema(
        .object(["$ref": .string("https://example.com/schema.json")])
      )
    ) { error in
      guard case MCPJSONSchemaError.invalidSchema(let issues) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(issues.contains { $0.message.contains("custom schema validator") })
    }

    XCTAssertThrowsError(
      try validator.validateSchema(
        .object(["$dynamicRef": .string("https://example.com/schema.json#node")])
      )
    ) { error in
      guard case MCPJSONSchemaError.invalidSchema(let issues) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(issues.contains { $0.keyword == "$dynamicRef" })
    }
  }

  func testSelfContainedDynamicAnchorRecursesWithoutNetworkResolution() throws {
    let schema: MCPJSONValue = .object([
      "$dynamicAnchor": .string("node"),
      "type": .string("object"),
      "properties": .object([
        "children": .object([
          "type": .string("array"),
          "items": .object(["$dynamicRef": .string("#node")]),
        ])
      ]),
    ])

    try validator.validate(
      .object([
        "children": .array([
          .object([
            "children": .array([
              .object(["children": .array([])])
            ])
          ])
        ])
      ]),
      against: schema
    )
  }

  func testDynamicReferenceResolvesAnEmbeddedSchemaResource() throws {
    let schema: MCPJSONValue = .object([
      "$id": .string("https://example.com/root"),
      "$ref": .string("tree"),
      "$defs": .object([
        "tree": .object([
          "$id": .string("tree"),
          "$dynamicAnchor": .string("node"),
          "type": .string("object"),
          "properties": .object([
            "children": .object([
              "type": .string("array"),
              "items": .object(["$dynamicRef": .string("#node")]),
            ])
          ]),
          "additionalProperties": .bool(false),
        ])
      ]),
    ])

    try validator.validate(
      .object(["children": .array([.object(["children": .array([])])])]),
      against: schema
    )
    XCTAssertThrowsError(
      try validator.validate(.object(["unexpected": .bool(true)]), against: schema))
  }

  func testDynamicReferenceUsesTheOutermostMatchingResource() throws {
    let schema: MCPJSONValue = .object([
      "$id": .string("https://example.com/strict-tree"),
      "$dynamicAnchor": .string("node"),
      "$ref": .string("tree"),
      "unevaluatedProperties": .bool(false),
      "$defs": .object([
        "tree": .object([
          "$id": .string("tree"),
          "$dynamicAnchor": .string("node"),
          "type": .string("object"),
          "properties": .object([
            "data": .bool(true),
            "children": .object([
              "type": .string("array"),
              "items": .object(["$dynamicRef": .string("#node")]),
            ]),
          ]),
        ])
      ]),
    ])

    try validator.validate(
      .object(["children": .array([.object(["data": .integer(1)])])]),
      against: schema
    )
    XCTAssertThrowsError(
      try validator.validate(
        .object(["children": .array([.object(["daat": .integer(1)])])]),
        against: schema
      ))
  }

  func testToolOutputSchemaMayDescribeArrayInstance() throws {
    let tool = try MCPTool(
      name: "rows",
      inputSchema: ["type": .string("object")],
      outputSchema: [
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
      ]
    )
    XCTAssertEqual(tool.outputSchema?["type"], .string("array"))
    try validator.validateSchema(.object(tool.outputSchema!))
  }

  func testDraft7Ignores202012OnlyKeywords() throws {
    let schema: MCPJSONValue = .object([
      "$schema": .string("http://json-schema.org/draft-07/schema#"),
      "type": .string("object"),
      "properties": .object([
        "a": .object(["type": .string("integer")]),
        "values": .object([
          "type": .string("array"),
          "contains": .object(["const": .integer(1)]),
          "minContains": .integer(2),
        ]),
      ]),
      "dependentRequired": .object([
        "a": .array([.string("missing")])
      ]),
      "unevaluatedProperties": .bool(false),
    ])

    try validator.validate(
      .object([
        "a": .integer(1),
        "values": .array([.integer(1)]),
        "extra": .bool(true),
      ]),
      against: schema
    )
  }

  func testResolvesEmbeddedSchemaResourceWithoutNetworkAccess() throws {
    let schema: MCPJSONValue = .object([
      "$id": .string("https://example.com/root"),
      "$defs": .object([
        "embedded": .object([
          "$id": .string("https://example.com/embedded"),
          "type": .string("string"),
        ])
      ]),
      "$ref": .string("https://example.com/embedded"),
    ])

    try validator.validate(.string("valid"), against: schema)
    XCTAssertThrowsError(try validator.validate(.integer(1), against: schema))
  }

  func testSchemaDepthLimitIsPropagated() throws {
    let bounded = MCPJSONSchemaValidator(
      limits: MCPJSONSchemaLimits(maximumSchemaDepth: 1)
    )
    let schema: MCPJSONValue = .object([
      "allOf": .array([
        .object([
          "allOf": .array([
            .object(["type": .string("string")])
          ])
        ])
      ])
    ])

    XCTAssertThrowsError(try bounded.validateSchema(schema)) { error in
      XCTAssertEqual(error as? MCPJSONSchemaError, .resourceLimit("schema depth exceeds 1"))
    }
  }

  func testEnumUsesSemanticNumericUniqueness() throws {
    let schema: MCPJSONValue = .object([
      "enum": .array([.integer(1), try number("1.0")])
    ])

    XCTAssertThrowsError(try validator.validateSchema(schema)) { error in
      guard case MCPJSONSchemaError.invalidSchema(let issues) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(issues.contains { $0.keyword == "enum" })
    }
  }

  func testLargeUniqueArrayValidationRemainsBounded() throws {
    let values = (0..<5_000).map { MCPJSONValue.integer($0) }
    let schema: MCPJSONValue = .object([
      "type": .string("array"),
      "uniqueItems": .bool(true),
    ])

    try validator.validate(.array(values), against: schema)
  }

}
