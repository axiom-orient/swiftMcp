import Foundation
import MCPHTTPServer
import MCPStdioServer
import MCPTasks
import XCTest

final class MCPServerProductImportTests: XCTestCase {
  func testProductImportsExposeTypesUsedByTheirPublicAPIs() {
    let headers = MCPHTTPHeaders(["x-example": "value"])
    _ = MCPHTTPResponse(status: 200, headers: headers, body: .empty)
    _ = MCPStdioServerConfiguration(limits: .default)
    _ = MCPTasksExtension.identifier
  }
}
