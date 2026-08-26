// swift-tools-version: 6.2
import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6)
]

let package = Package(
  name: "SwiftMCP",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
  ],
  products: [
    .library(name: "MCP", targets: ["MCP"]),
    .library(name: "MCPTasks", targets: ["MCPTasks"]),
    .library(name: "MCPHTTPClient", targets: ["MCPHTTPClient"]),
    .library(name: "MCPHTTPServer", targets: ["MCPHTTPServer"]),
    .library(name: "MCPStdioClient", targets: ["MCPStdioClient"]),
    .library(name: "MCPStdioServer", targets: ["MCPStdioServer"]),
    .library(name: "MCPOAuth", targets: ["MCPOAuth"]),
    .executable(name: "mcp-json-schema-corpus", targets: ["MCPJSONSchemaCorpusRunner"]),
    .executable(name: "mcp-conformance-client", targets: ["MCPConformanceClient"]),
    .executable(name: "mcp-conformance-server", targets: ["MCPConformanceServer"]),
  ],
  targets: [
    .target(
      name: "MCPPlatformCrypto",
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("Security", .when(platforms: [.macOS, .iOS]))]
    ),
    .target(name: "MCP", swiftSettings: strictSwiftSettings),
    .target(name: "MCPTasks", dependencies: ["MCP"], swiftSettings: strictSwiftSettings),
    .target(name: "MCPHTTPShared", dependencies: ["MCP"], swiftSettings: strictSwiftSettings),
    .target(
      name: "MCPHTTPClient", dependencies: ["MCP", "MCPHTTPShared"],
      swiftSettings: strictSwiftSettings),
    .target(
      name: "MCPHTTPServer", dependencies: ["MCP", "MCPHTTPShared"],
      swiftSettings: strictSwiftSettings),
    .target(name: "MCPStdioShared", dependencies: ["MCP"], swiftSettings: strictSwiftSettings),
    .target(
      name: "MCPStdioClient", dependencies: ["MCP", "MCPStdioShared"],
      swiftSettings: strictSwiftSettings),
    .target(
      name: "MCPStdioServer", dependencies: ["MCP", "MCPStdioShared"],
      swiftSettings: strictSwiftSettings),
    .target(
      name: "MCPOAuth",
      dependencies: ["MCP", "MCPHTTPClient", "MCPHTTPShared", "MCPPlatformCrypto"],
      swiftSettings: strictSwiftSettings),
    .executableTarget(
      name: "MCPJSONSchemaCorpusRunner", dependencies: ["MCP"], swiftSettings: strictSwiftSettings),
    .executableTarget(
      name: "MCPConformanceClient", dependencies: ["MCP", "MCPHTTPClient", "MCPStdioClient"],
      swiftSettings: strictSwiftSettings),
    .executableTarget(
      name: "MCPConformanceServer",
      dependencies: ["MCP", "MCPTasks", "MCPHTTPServer", "MCPStdioServer"],
      swiftSettings: strictSwiftSettings),
    .testTarget(name: "MCPTests", dependencies: ["MCP"], swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "MCPTasksTests",
      dependencies: ["MCP", "MCPTasks", "MCPHTTPClient", "MCPHTTPServer"],
      swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "MCPHTTPTests", dependencies: ["MCP", "MCPHTTPClient", "MCPHTTPServer"],
      swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "MCPStdioTests", dependencies: ["MCP", "MCPStdioClient", "MCPStdioServer"],
      swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "MCPOAuthTests", dependencies: ["MCPOAuth"], swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "MCPIntegrationTests",
      dependencies: [
        "MCP", "MCPHTTPClient", "MCPHTTPServer", "MCPStdioClient", "MCPStdioServer", "MCPOAuth",
      ], swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "MCPProductImportTests",
      dependencies: ["MCPHTTPClient", "MCPStdioClient", "MCPTasks"],
      swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "MCPServerProductImportTests",
      dependencies: ["MCPHTTPServer", "MCPStdioServer", "MCPTasks"],
      swiftSettings: strictSwiftSettings),
  ],
  swiftLanguageModes: [.v6]
)
