import XCTest

@testable import MCP

final class MCPProductProfileTests: XCTestCase {
  func testSupportedMethodSurfaceMatchesCanonicalRegistry() {
    let requestMethods = Set(MCPMethodRegistry.standard.requestMethods.map(\.name))

    XCTAssertEqual(
      requestMethods,
      [
        "server/discover", "tools/list", "tools/call", "prompts/list", "prompts/get",
        "resources/list", "resources/templates/list", "resources/read", "completion/complete",
        "subscriptions/listen",
      ]
    )
  }

  func testStrictProfileExcludesRemovedProtocolMethods() {
    let registeredMethods = Set(MCPMethodRegistry.standard.descriptors.map(\.name))
    let excludedMethods: Set<String> = [
      "initialize", "notifications/initialized", "resources/subscribe", "resources/unsubscribe",
      "logging/setLevel",
    ]

    XCTAssertTrue(registeredMethods.isDisjoint(with: excludedMethods))
  }
}
