import Foundation
import XCTest

@testable import MCP

final class MCPProtocolBaseTests: XCTestCase {
  func testOnlyCurrentProtocolVersionCanBeConstructed() {
    XCTAssertEqual(MCPProtocolVersion(rawValue: "2026-07-28"), .current)
    XCTAssertNil(MCPProtocolVersion(rawValue: "2025-11-25"))
    XCTAssertNil(MCPProtocolVersion(rawValue: ""))
  }

  func testRequestMetadataOwnsReservedFieldsAndRoundTrips() throws {
    let capabilities = try MCPClientCapabilities(
      elicitation: MCPElicitationCapabilities(form: true, url: true),
      extensions: ["example/client": .object(["enabled": .bool(true)])]
    )
    let implementation = try MCPImplementation(name: "client", version: "1.2.3")
    let metadata = try MCPRequestMetadata(
      clientCapabilities: capabilities,
      clientInfo: implementation,
      progressToken: MCPProgressToken(9),
      logLevel: .notice,
      traceContext: [
        MCPMetaKey.traceparent: "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01",
        MCPMetaKey.tracestate: "vendor=value",
        MCPMetaKey.baggage: "tenant=alpha;region=ap-northeast-2",
      ],
      extensions: ["example/tenant": .string("a")]
    )
    let inserted = try metadata.inserting(into: ["cursor": .string("next")])
    XCTAssertEqual(inserted["cursor"], .string("next"))
    XCTAssertEqual(try MCPRequestMetadata.extract(from: inserted), metadata)
    XCTAssertEqual(
      inserted["_meta"]?.objectValue?[MCPMetaKey.protocolVersion],
      .string("2026-07-28")
    )
  }

  func testCallerCannotOverrideSDKOwnedMetadata() throws {
    let metadata = try MCPRequestMetadata(clientCapabilities: MCPClientCapabilities())
    XCTAssertThrowsError(try metadata.inserting(into: ["_meta": .object([:])]))
    XCTAssertThrowsError(
      try MCPRequestMetadata(
        clientCapabilities: MCPClientCapabilities(),
        extensions: [MCPMetaKey.protocolVersion: .string("other")]
      )
    )
    XCTAssertNoThrow(
      try MCPRequestMetadata(
        clientCapabilities: MCPClientCapabilities(),
        extensions: ["io.modelcontextprotocol/unknown": .bool(true)]
      )
    )
  }

  func testTraceContextRejectsLineBreaksAndUnknownKeys() throws {
    XCTAssertThrowsError(
      try MCPRequestMetadata(
        clientCapabilities: MCPClientCapabilities(),
        traceContext: [MCPMetaKey.traceparent: "valid\r\ninjected"]
      )
    )
    XCTAssertThrowsError(
      try MCPRequestMetadata(
        clientCapabilities: MCPClientCapabilities(),
        traceContext: ["vendor": "value"]
      )
    )
    XCTAssertThrowsError(
      try MCPRequestMetadata(
        clientCapabilities: MCPClientCapabilities(),
        traceContext: [MCPMetaKey.traceparent: "00-abc-def-01"]
      )
    )
    XCTAssertThrowsError(
      try MCPRequestMetadata(
        clientCapabilities: MCPClientCapabilities(),
        traceContext: [MCPMetaKey.tracestate: "vendor=value,vendor=duplicate"]
      )
    )
  }

  func testMetadataKeyGrammarAllowsFutureReservedKeys() throws {
    for key in [
      "tenant", "com.example/tenant", "com.example/", "com.example.mcp/key",
      "io.modelcontextprotocol/future",
    ] {
      XCTAssertNoThrow(
        try MCPRequestMetadata(
          clientCapabilities: MCPClientCapabilities(),
          extensions: [key: .string("value")]
        ),
        key
      )
    }

    for key in [
      "1com.example/key",
      "com-.example/key",
      "com..example/key",
      "com.example/key-",
      "com.example/key/extra",
      "/key",
    ] {
      XCTAssertThrowsError(
        try MCPRequestMetadata(
          clientCapabilities: MCPClientCapabilities(),
          extensions: [key: .string("value")]
        ),
        key
      )
    }
  }

  func testDecodedTraceContextIsValidated() throws {
    XCTAssertThrowsError(
      try MCPRequestMetadata(
        json: .object([
          MCPMetaKey.protocolVersion: .string("2026-07-28"),
          MCPMetaKey.clientCapabilities: .object([:]),
          MCPMetaKey.traceparent: .string("00-abc-def-01"),
        ])
      )
    )
  }

  func testCapabilitiesPreserveDeprecatedAndFutureEntries() throws {
    let clientJSON: MCPJSONValue = .object([
      "elicitation": .object([
        "form": .object(["ui": .string("native")]),
        "url": .object(["callback": .bool(true)]),
      ]),
      "roots": .object(["scope": .string("workspace")]),
      "sampling": .object([
        "context": .object(["mode": .string("server")]),
        "tools": .object(["parallel": .bool(true)]),
      ]),
      "com.example/future": .object(["enabled": .bool(true)]),
    ])
    XCTAssertEqual(try MCPClientCapabilities(json: clientJSON).json, clientJSON)

    let serverJSON: MCPJSONValue = .object([
      "tools": .object(["listChanged": .bool(true), "vendor": .string("tool-setting")]),
      "prompts": .object(["listChanged": .bool(false), "vendor": .string("prompt-setting")]),
      "resources": .object(["subscribe": .bool(true), "vendor": .string("resource-setting")]),
      "completions": .object(["vendor": .string("completion-setting")]),
      "logging": .object(["format": .string("json")]),
      "com.example/future": .object(["enabled": .bool(true)]),
    ])
    XCTAssertEqual(try MCPServerCapabilities(json: serverJSON).json, serverJSON)

    XCTAssertThrowsError(
      try MCPClientCapabilities(additionalCapabilities: ["elicitation": .object([:])]))
    XCTAssertThrowsError(
      try MCPClientCapabilities(additionalCapabilities: ["roots": .object([:])]))
    XCTAssertThrowsError(
      try MCPClientCapabilities(additionalCapabilities: ["sampling": .object([:])]))
    XCTAssertThrowsError(
      try MCPServerCapabilities(additionalCapabilities: ["logging": .object([:])]))
    XCTAssertThrowsError(
      try MCPServerCapabilities(additionalCapabilities: ["completions": .object([:])]))

    let experimental: [String: MCPJSONValue] = ["com.example/feature": .object(["v": .integer(1)])]
    XCTAssertEqual(
      try MCPClientCapabilities(experimental: experimental).experimental,
      experimental
    )
    XCTAssertEqual(
      try MCPServerCapabilities(experimental: experimental).experimental,
      experimental
    )
    XCTAssertThrowsError(
      try MCPClientCapabilities(json: .object(["experimental": .object(["bad": .bool(true)])]))
    )
  }

  func testRequestScopedLoggingMessagePreservesNotificationMetadata() throws {
    let metadata = try MCPNotificationMetadata(
      extensions: ["com.example/log": .string("request-1")]
    )
    let message = try MCPLoggingMessageParams(
      level: .warning,
      logger: "compiler",
      data: .object(["message": .string("warning")]),
      metadata: metadata
    )

    XCTAssertEqual(try MCPLoggingMessageParams(json: message.json), message)
  }

  func testCapabilityExtensionIdentifiersUseMetadataGrammarAndRequirePrefix() throws {
    XCTAssertNoThrow(
      try MCPClientCapabilities(extensions: ["io.modelcontextprotocol/tasks": .object([:])])
    )
    XCTAssertNoThrow(
      try MCPServerCapabilities(extensions: ["com.example/feature": .object([:])])
    )
    for invalid in ["feature", "/feature", "1com.example/feature", "com..example/feature"] {
      XCTAssertThrowsError(
        try MCPClientCapabilities(extensions: [invalid: .object([:])]), invalid)
    }
  }

  func testResultAndNotificationMetadataEnforceMetaKeyGrammar() throws {
    XCTAssertNoThrow(
      try MCPResultMetadata(extensions: ["com.example/result": .string("ok")])
    )
    XCTAssertNoThrow(
      try MCPNotificationMetadata(extensions: ["com.example/event": .bool(true)])
    )
    for invalid in ["com..example/result", "com.example/result/extra"] {
      XCTAssertThrowsError(try MCPResultMetadata(extensions: [invalid: .null]), invalid)
      XCTAssertThrowsError(try MCPNotificationMetadata(extensions: [invalid: .null]), invalid)
    }
    XCTAssertThrowsError(
      try MCPResultMetadata(extensions: [MCPMetaKey.serverInfo: .object([:])]))
    XCTAssertThrowsError(
      try MCPNotificationMetadata(extensions: [MCPMetaKey.subscriptionID: .integer(1)]))
  }

  func testCapabilityDependenciesAreNotSilentlyDiscarded() {
    XCTAssertThrowsError(
      try MCPServerCapabilities(tools: false, toolListChanged: true)
    )
    XCTAssertThrowsError(
      try MCPServerCapabilities(resources: false, resourceSubscriptions: true)
    )
  }

  func testImplementationRequiresNonEmptyIdentity() {
    XCTAssertThrowsError(try MCPImplementation(name: "", version: "1"))
    XCTAssertThrowsError(try MCPImplementation(name: "server", version: ""))
    XCTAssertNoThrow(try MCPImplementation(name: "server", version: "1"))
  }

  func testEmptyElicitationCapabilityMeansImplicitFormSupport() throws {
    XCTAssertThrowsError(try MCPElicitationCapabilities(form: false, url: false))
    let decoded = try MCPElicitationCapabilities(json: .object([:]))
    XCTAssertTrue(decoded.form)
    XCTAssertFalse(decoded.url)
    XCTAssertEqual(decoded.json, .object(["form": .object([:])]))
  }
}
