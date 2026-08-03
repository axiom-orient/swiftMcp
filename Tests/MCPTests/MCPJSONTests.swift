import Foundation
import XCTest

@testable import MCP

final class MCPJSONTests: XCTestCase {
  func testExactNumberLexemesAndDeterministicObjectEncoding() throws {
    let value = try MCPJSONValue.parse(#"{"z":1e+9,"a":-0.00,"m":9007199254740993123456789}"#)
    guard case .object(let object) = value else { return XCTFail("expected object") }
    XCTAssertEqual(object["z"]?.numberValue?.rawValue, "1e+9")
    XCTAssertEqual(object["a"]?.numberValue?.rawValue, "-0.00")
    XCTAssertEqual(object["m"]?.numberValue?.rawValue, "9007199254740993123456789")
    XCTAssertEqual(
      String(decoding: try value.encoded(), as: UTF8.self),
      #"{"a":-0.00,"m":9007199254740993123456789,"z":1e+9}"#
    )
  }

  func testRejectsDuplicateKeysAndTrailingData() {
    XCTAssertThrowsError(try MCPJSONValue.parse(#"{"a":1,"a":2}"#)) { error in
      XCTAssertEqual(error as? MCPJSONError, .duplicateKey("a"))
    }
    XCTAssertThrowsError(try MCPJSONValue.parse("{} false")) { error in
      guard case .trailingData = error as? MCPJSONError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testRejectsInvalidNumbers() {
    for input in ["01", "+1", "1.", "1e", "--1", "NaN", "Infinity"] {
      XCTAssertThrowsError(try MCPJSONValue.parse(input), "input: \(input)")
    }
  }

  func testUnicodeEscapesAndInvalidSurrogates() throws {
    XCTAssertEqual(try MCPJSONValue.parse(#""\uD83D\uDE00""#), .string("😀"))
    XCTAssertThrowsError(try MCPJSONValue.parse(#""\uD83D""#)) { error in
      guard case .unpairedSurrogate = error as? MCPJSONError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertThrowsError(try MCPJSONValue.parse(Data([0x22, 0xC3, 0x28, 0x22]))) { error in
      guard case .invalidUTF8 = error as? MCPJSONError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testParserResourceLimits() {
    XCTAssertThrowsError(
      try MCPJSONValue.parse(
        #"{"a":"1234"}"#,
        limits: MCPJSONLimits(maximumDocumentBytes: 1024, maximumDepth: 8, maximumStringBytes: 3)
      )
    ) { error in
      XCTAssertEqual(error as? MCPJSONError, .stringTooLarge(limit: 3))
    }

    XCTAssertThrowsError(
      try MCPJSONValue.parse(
        "[[[[]]]]",
        limits: MCPJSONLimits(maximumDocumentBytes: 1024, maximumDepth: 2)
      )
    ) { error in
      XCTAssertEqual(error as? MCPJSONError, .depthExceeded(limit: 2))
    }

    XCTAssertThrowsError(
      try MCPJSONValue.parse(
        "[1,2]",
        limits: MCPJSONLimits(maximumDocumentBytes: 1024, maximumContainerElements: 1)
      )
    ) { error in
      XCTAssertEqual(error as? MCPJSONError, .containerTooLarge(limit: 1))
    }
  }

  func testStringEncodingEscapesControlCharacters() throws {
    let value = MCPJSONValue.string("line\n\t\"\\\u{0001}")
    XCTAssertEqual(String(decoding: try value.encoded(), as: UTF8.self), #""line\n\t\"\\\u0001""#)
    XCTAssertEqual(try MCPJSONValue.parse(try value.encoded()), value)
  }

  func testPublicNumberAndProgressTokenInitializersRejectInvalidInputWithoutTrap() {
    XCTAssertThrowsError(try MCPJSONNumber(rawValue: "01"))
    XCTAssertNoThrow(try MCPProgressToken(""))
    XCTAssertNoThrow(try MCPProgressToken("token"))
    XCTAssertEqual(
      try MCPProgressToken(json: .number(MCPJSONNumber(rawValue: "1.5"))),
      MCPProgressToken(try MCPJSONNumber(rawValue: "1.5"))
    )
  }
  func testExactNumberComparisonAndMathematicalIntegerClassification() throws {
    let one = try MCPJSONNumber(rawValue: "1")
    let onePointZero = try MCPJSONNumber(rawValue: "1.0")
    let scaledOne = try MCPJSONNumber(rawValue: "10e-1")
    XCTAssertTrue(onePointZero.isMathematicalInteger)
    XCTAssertTrue(scaledOne.isMathematicalInteger)
    XCTAssertFalse(onePointZero.isInteger)
    XCTAssertTrue(one.isNumericallyEqual(to: onePointZero))
    XCTAssertTrue(one.isNumericallyEqual(to: scaledOne))

    let fraction = try MCPJSONNumber(rawValue: "1.0000000000000000000000000000000000001")
    XCTAssertFalse(fraction.isMathematicalInteger)
    XCTAssertEqual(fraction.compare(to: one), .orderedDescending)
    XCTAssertEqual(try MCPJSONNumber(rawValue: "-1e1000").compare(to: one), .orderedAscending)

    let huge = try MCPJSONNumber(rawValue: "1e100000000000000000000")
    let sameHuge = try MCPJSONNumber(rawValue: "10e99999999999999999999")
    let smallerHuge = try MCPJSONNumber(rawValue: "9e99999999999999999999")
    XCTAssertTrue(huge.isNumericallyEqual(to: sameHuge))
    XCTAssertEqual(smallerHuge.compare(to: huge), .orderedAscending)
  }

  func testExactIntegerExtractionAndMultipleOf() throws {
    XCTAssertEqual(try MCPJSONNumber(rawValue: "10e2").exactIntValue, 1_000)
    XCTAssertEqual(try MCPJSONNumber(rawValue: "-1.0").exactIntValue, -1)
    XCTAssertNil(try MCPJSONNumber(rawValue: "1.5").exactIntValue)
    XCTAssertNil(try MCPJSONNumber(rawValue: "1e1000").exactIntValue)

    XCTAssertEqual(
      try MCPJSONNumber(rawValue: "0.3").isMultiple(
        of: MCPJSONNumber(rawValue: "0.1")),
      true
    )
    XCTAssertEqual(
      try MCPJSONNumber(rawValue: "0.31").isMultiple(
        of: MCPJSONNumber(rawValue: "0.1")),
      false
    )
    XCTAssertEqual(
      try MCPJSONNumber(rawValue: "9007199254740993123456790").isMultiple(
        of: MCPJSONNumber(rawValue: "10")),
      true
    )
    XCTAssertEqual(
      try MCPJSONNumber(rawValue: "1e10000").isMultiple(
        of: MCPJSONNumber(rawValue: "3"), maximumPowerExpansion: 32),
      nil
    )
  }

}
