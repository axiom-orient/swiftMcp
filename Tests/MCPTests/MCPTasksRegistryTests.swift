import XCTest

@testable import MCP

final class MCPTasksRegistryTests: XCTestCase {
  func testOfficialExtensionCanRegisterTwoSegmentMethodsAndAugmentStandardResult() throws {
    let id = "io.modelcontextprotocol/tasks"
    let augmentation = try MCPMethodDescriptor(
      name: "tools/call",
      direction: .clientToServerRequest,
      requiredServerCapability: .tools,
      httpNameSource: .toolName,
      allowsMRTR: true,
      extensionResultTypes: ["task"],
      isExtension: true,
      extensionIdentifier: id
    )
    let get = try MCPMethodDescriptor(
      name: "tasks/get",
      direction: .clientToServerRequest,
      httpNameSource: .taskID,
      isExtension: true,
      extensionIdentifier: id
    )
    let registry = try MCPMethodRegistry(extensionMethods: [augmentation, get])

    XCTAssertEqual(try registry.require("tools/call").extensionResultTypes, ["task"])
    XCTAssertEqual(
      try registry.require("tasks/get").httpName(from: ["taskId": .string("t-1")]),
      "t-1"
    )
  }

  func testStandardCollisionWithoutExtensionIdentityStillFailsAsBefore() throws {
    let collision = try MCPMethodDescriptor(
      name: "tools/list",
      direction: .clientToServerRequest,
      isExtension: true
    )
    XCTAssertThrowsError(try MCPMethodRegistry(extensionMethods: [collision])) { error in
      XCTAssertEqual(error as? MCPRegistryError, .standardMethodCollision("tools/list"))
    }
  }
}
