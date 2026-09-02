import Foundation
import MCPHTTPClient
import MCPStdioClient
import XCTest

#if os(macOS)
  import MCPXcode
#endif

final class MCPProductImportTests: XCTestCase {
  func testProductImportsExposeTypesUsedByTheirPublicAPIs() throws {
    let headers = MCPHTTPClient.MCPHTTPHeaders(["x-example": "value"])
    _ = try MCPHTTPClientConfiguration(
      endpoint: URL(string: "https://example.com/mcp")!,
      additionalHeaders: headers
    )
    _ = MCPStdioLimits.default
    #if os(macOS)
      _ = MCPXcodeProtocolRevision.preferred
    #endif
  }
}
