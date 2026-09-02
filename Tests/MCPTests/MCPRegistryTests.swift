import XCTest

@testable import MCP

final class MCPRegistryTests: XCTestCase {
  func testStandardRegistryIsUniqueAndComplete() throws {
    let registry = MCPMethodRegistry.standard
    let names = registry.descriptors.map(\.name)
    XCTAssertEqual(Set(names).count, names.count)
    XCTAssertEqual(
      Set(registry.requestMethods.map(\.name)),
      [
        "server/discover", "tools/list", "tools/call", "prompts/list", "prompts/get",
        "resources/list", "resources/templates/list", "resources/read", "completion/complete",
        "subscriptions/listen",
      ])
    XCTAssertEqual(
      Set(registry.serverNotificationMethods.map(\.name)),
      [
        "notifications/progress", "notifications/message",
        "notifications/subscriptions/acknowledged",
        "notifications/tools/list_changed", "notifications/prompts/list_changed",
        "notifications/resources/list_changed", "notifications/resources/updated",
        "notifications/cancelled",
      ])
    XCTAssertEqual(
      try registry.require("tools/call").httpName(from: ["name": .string("echo")]), "echo")
  }

  func testCancellationNotificationIsAcceptedInBothProtocolDirections() throws {
    let registry = MCPMethodRegistry.standard
    let clientDirection = try registry.require(
      "notifications/cancelled",
      direction: .clientToServerNotification
    )
    let serverDirection = try registry.require(
      "notifications/cancelled",
      direction: .serverToClientNotification
    )
    XCTAssertEqual(clientDirection.direction, .bidirectionalNotification)
    XCTAssertEqual(serverDirection.direction, .bidirectionalNotification)
  }

  func testRegistryRejectsCollisionsAndInvalidExtensions() throws {
    let standardCollision = try MCPMethodDescriptor(
      name: "tools/list", direction: .clientToServerRequest, isExtension: true)
    XCTAssertThrowsError(try MCPMethodRegistry(extensionMethods: [standardCollision])) { error in
      XCTAssertEqual(error as? MCPRegistryError, .standardMethodCollision("tools/list"))
    }

    XCTAssertThrowsError(
      try MCPMethodDescriptor(
        name: "vendor/action", direction: .clientToServerRequest, isExtension: true)
    ) { error in
      XCTAssertEqual(error as? MCPRegistryError, .invalidMethodName("vendor/action"))
    }

    XCTAssertThrowsError(
      try MCPMethodDescriptor(
        name: "vendor.example/action",
        direction: .clientToServerRequest,
        extensionResultTypes: ["complete"],
        isExtension: true
      )
    ) { error in
      XCTAssertEqual(error as? MCPRegistryError, .invalidExtensionResultType)
    }
  }

  func testVendorExtensionCannotIntroduceCoreShapedMethod() {
    XCTAssertThrowsError(
      try MCPMethodDescriptor(
        name: "roots/list",
        direction: .clientToServerRequest,
        isExtension: true,
        extensionIdentifier: "com.example/compat"
      )
    ) { error in
      XCTAssertEqual(error as? MCPRegistryError, .invalidMethodName("roots/list"))
    }
  }

  func testExtensionMethodIsAcceptedWithExplicitNamespace() throws {
    let descriptor = try MCPMethodDescriptor(
      name: "com.example/widget/read",
      direction: .clientToServerRequest,
      cacheability: .resourceRead,
      extensionResultTypes: ["com.example/partial"],
      isExtension: true
    )
    let registry = try MCPMethodRegistry(extensionMethods: [descriptor])
    XCTAssertEqual(try registry.require(descriptor.name), descriptor)
  }

  func testHTTPNameUsesAnArbitraryTopLevelParameterKey() throws {
    let descriptor = try MCPMethodDescriptor(
      name: "com.example/jobs/get",
      direction: .clientToServerRequest,
      httpNameSource: .parameter("jobId"),
      isExtension: true
    )
    let registry = try MCPMethodRegistry(extensionMethods: [descriptor])
    let method = try registry.require(descriptor.name)

    XCTAssertEqual(
      try method.httpName(from: ["jobId": .string("job-42")]),
      "job-42"
    )
    XCTAssertThrowsError(try method.httpName(from: [:])) { error in
      XCTAssertEqual(
        error as? MCPJSONError,
        .invalidField(field: "jobId", reason: "required for Mcp-Name")
      )
    }
  }

  func testHTTPNameRejectsAnEmptyParameterKeyDuringDescriptorConstruction() {
    XCTAssertThrowsError(
      try MCPMethodDescriptor(
        name: "com.example/jobs/get",
        direction: .clientToServerRequest,
        httpNameSource: .parameter("")
      )
    ) { error in
      XCTAssertEqual(
        error as? MCPJSONError,
        .invalidField(field: "httpNameSource", reason: "parameter key must not be empty")
      )
    }
  }

  func testRetiredCoreMethodsCannotReturnThroughExtensionRegistry() {
    for method in [
      "notifications/elicitation/complete",
      "notifications/roots/list_changed",
      "notifications/tasks/status",
    ] {
      XCTAssertThrowsError(
        try MCPMethodDescriptor(
          name: method,
          direction: .serverToClientNotification,
          isExtension: true
        )
      ) { error in
        XCTAssertEqual(error as? MCPRegistryError, .invalidMethodName(method))
      }
    }
  }

  func testDirectionIsEnforced() {
    XCTAssertThrowsError(
      try MCPMethodRegistry.standard.require(
        "notifications/progress", direction: .clientToServerRequest)
    ) { error in
      guard case .wrongDirection = error as? MCPRegistryError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }
}
