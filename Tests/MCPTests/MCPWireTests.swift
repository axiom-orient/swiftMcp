import Foundation
import XCTest

@testable import MCP

final class MCPWireTests: XCTestCase {
  func testRequestNotificationResultAndErrorRoundTrip() throws {
    let request = try MCPWireMessage.request(
      MCPWireRequest(id: MCPRequestID(7), method: "tools/list", params: ["cursor": .string("x")])
    )
    let notification = try MCPWireMessage.notification(
      MCPWireNotification(method: "notifications/progress", params: ["progress": .integer(1)])
    )
    let result = MCPWireMessage.result(
      MCPWireResult(id: MCPRequestID(7), value: ["tools": .array([])])
    )
    let error = MCPWireMessage.error(
      MCPWireErrorResponse(id: MCPRequestID(7), error: .invalidParams)
    )
    for message in [request, notification, result, error] {
      XCTAssertEqual(try MCPWireMessage.decode(message.encoded()), message)
    }
  }

  func testStrictEnvelopeRejectsLegacyAndAmbiguousForms() {
    let cases: [(String, MCPWireError)] = [
      (#"[]"#, .batchNotSupported),
      (#"null"#, .topLevelMustBeObject),
      (#"{"jsonrpc":"1.0","id":1,"method":"x"}"#, .invalidJSONRPCVersion),
      (#"{"jsonrpc":"2.0","id":1,"method":"x","result":{}}"#, .ambiguousEnvelope),
      (#"{"jsonrpc":"2.0","id":null,"method":"x"}"#, .nullRequestID),
      (#"{"jsonrpc":"2.0","id":1.5,"method":"x"}"#, .floatingRequestID),
      (
        #"{"jsonrpc":"2.0","id":1,"result":{"resultType":1}}"#,
        .invalidResultType("non-string resultType")
      ),
      (#"{"jsonrpc":"2.0","id":1,"result":[]}"#, .resultMustBeObject),
      (#"{"jsonrpc":"2.0","id":1,"method":"x","params":[]}"#, .paramsMustBeObject),
      (#"{"jsonrpc":"2.0","id":1,"method":""}"#, .invalidMethod),
    ]
    for (input, expected) in cases {
      XCTAssertThrowsError(try MCPWireMessage.decode(Data(input.utf8)), "input: \(input)") {
        error in
        XCTAssertEqual(error as? MCPWireError, expected)
      }
    }
  }

  func testMissingResultTypeIsInterpretedAsCompleteForPeerResults() throws {
    let message = try MCPWireMessage.decode(
      Data(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.utf8)
    )
    guard case .result(let result) = message else {
      return XCTFail("expected result")
    }
    XCTAssertEqual(result.resultType, .complete)
    XCTAssertEqual(result.value["resultType"], .string("complete"))
  }

  func testResponseRequiresIDAndIntegerErrorCode() {
    XCTAssertThrowsError(
      try MCPWireMessage.decode(Data(#"{"jsonrpc":"2.0","result":{"resultType":"complete"}}"#.utf8))
    ) { error in
      XCTAssertEqual(error as? MCPWireError, .missingID)
    }
    XCTAssertThrowsError(
      try MCPWireMessage.decode(
        Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":1.5,"message":"x"}}"#.utf8))
    ) { error in
      XCTAssertEqual(error as? MCPWireError, .invalidErrorCode)
    }
  }

  func testErrorResponseMayOmitIDWhenRequestIDCannotBeRecovered() throws {
    let input = Data(
      #"{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}"#.utf8)
    let message = try MCPWireMessage.decode(input)
    guard case .error(let response) = message else { return XCTFail("expected error") }
    XCTAssertNil(response.id)
    XCTAssertEqual(response.error, .parseError)

    let encoded = try message.encoded()
    guard case .object(let object) = try MCPJSONValue.parse(encoded) else {
      return XCTFail("expected object")
    }
    XCTAssertNil(object["id"])
    XCTAssertEqual(try MCPWireMessage.decode(encoded), message)

    XCTAssertThrowsError(
      try MCPWireMessage.decode(
        Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#.utf8)
      )
    ) { error in
      XCTAssertEqual(error as? MCPWireError, .nullRequestID)
    }
  }

  func testResultTypeIsExplicitAndExtensionValuesArePreserved() throws {
    let message = try MCPWireMessage.decode(
      Data(#"{"jsonrpc":"2.0","id":"a","result":{"resultType":"vendor/example","x":1}}"#.utf8)
    )
    guard case .result(let result) = message else { return XCTFail("expected result") }
    XCTAssertEqual(result.resultType, .extensionValue("vendor/example"))
    XCTAssertEqual(result.value["x"], .integer(1))
    XCTAssertEqual(result.value["resultType"], .string("vendor/example"))
  }

  func testWireResultConstructorOwnsResultType() {
    let result = MCPWireResult(
      id: MCPRequestID(1),
      resultType: .complete,
      value: ["resultType": .string("input_required"), "value": .bool(true)]
    )
    XCTAssertEqual(result.value["resultType"], .string("complete"))
  }
}
