import Foundation
import XCTest

@testable import MCP

final class MCPModelTests: XCTestCase {
  private func assertRoundTrip<T>(_ value: T, file: StaticString = #filePath, line: UInt = #line)
    throws where T: MCPJSONModel & Equatable
  {
    XCTAssertEqual(try T(json: value.json), value, file: file, line: line)
    XCTAssertEqual(
      try T(json: MCPJSONValue.parse(value.json.encoded())), value, file: file, line: line)
  }

  func testDiscoveryAndCacheRoundTrip() throws {
    let capabilities = try MCPServerCapabilities(
      tools: true,
      toolListChanged: true,
      prompts: true,
      resources: true,
      resourceSubscriptions: true,
      completions: true
    )
    let result = try MCPDiscoverResult(
      capabilities: capabilities,
      instructions: "strict",
      cache: MCPCachePolicy(ttlMilliseconds: 42, scope: .public),
      metadata: MCPResultMetadata(serverInfo: try MCPImplementation(name: "server", version: "1"))
    )
    try assertRoundTrip(result)
    XCTAssertEqual(result.supportedVersions, ["2026-07-28"])

    var invalid = result.json.objectValue ?? [:]
    invalid["supportedVersions"] = .array([.string("2025-11-25"), .string("2026-07-28")])
    XCTAssertEqual(
      try MCPDiscoverResult(json: .object(invalid)).supportedVersions,
      ["2025-11-25", "2026-07-28"]
    )

    invalid["supportedVersions"] = .array([.string("2025-11-25")])
    XCTAssertThrowsError(try MCPDiscoverResult(json: .object(invalid)))

    invalid = result.json.objectValue ?? [:]
    invalid.removeValue(forKey: "cacheScope")
    XCTAssertThrowsError(try MCPDiscoverResult(json: .object(invalid)))

    var negativeTTL = result.json.objectValue ?? [:]
    negativeTTL["ttlMs"] = .integer(-1)
    XCTAssertThrowsError(try MCPDiscoverResult(json: .object(negativeTTL)))
  }

  func testSchemaIntegerFieldsPreserveLargeValuesWithoutAcceptingFractions() throws {
    let large = try MCPJSONNumber(rawValue: "184467440737095516160000")
    let fractional = try MCPJSONNumber(rawValue: "1.5")
    let negative = try MCPJSONNumber(rawValue: "-1")

    let cache = try MCPCachePolicy(ttlMilliseconds: large, scope: .public)
    let discovery = try MCPDiscoverResult(
      capabilities: MCPServerCapabilities(),
      cache: cache
    )
    XCTAssertEqual(discovery.json.objectValue?["ttlMs"], .number(large))
    XCTAssertEqual(try MCPDiscoverResult(json: discovery.json).cache, cache)

    let resource = try MCPResource(uri: "file:///tmp/large", name: "large", size: large)
    XCTAssertEqual(try MCPResource(json: resource.json).size, large)
    let link = try MCPResourceLinkContent(uri: "file:///tmp/large", name: "large", size: large)
    XCTAssertEqual(try MCPResourceLinkContent(json: link.json).size, large)
    let completion = try MCPCompletion(values: ["large"], total: large)
    XCTAssertEqual(try MCPCompletion(json: completion.json).total, large)

    // The official schema specifies `integer` for resource size and completion total, without a
    // minimum. Preserve valid peer values rather than adding a narrower Swift-only range.
    XCTAssertEqual(
      try MCPResource(uri: "file:///tmp/negative", name: "negative", size: negative).size, negative)
    XCTAssertEqual(try MCPCompletion(values: [], total: negative).total, negative)

    XCTAssertThrowsError(try MCPCachePolicy(ttlMilliseconds: fractional, scope: .public))
    XCTAssertThrowsError(try MCPCachePolicy(ttlMilliseconds: negative, scope: .public))
    XCTAssertThrowsError(
      try MCPResource(uri: "file:///tmp/fraction", name: "fraction", size: fractional))
    XCTAssertThrowsError(try MCPCompletion(values: [], total: fractional))
  }

  func testContentBlocksRoundTripWithoutSemanticConversion() throws {
    let annotations = try MCPAnnotations(
      audience: [.user],
      priority: MCPJSONNumber(rawValue: "0.5"),
      lastModified: "2026-08-01T00:00:00Z"
    )
    let text = MCPContentBlock.text(
      MCPTextContent(text: "data:text/plain;base64,SGVsbG8=", annotations: annotations))
    let image = MCPContentBlock.image(
      try MCPBinaryContent(kind: .image, data: "AQID", mimeType: "image/png"))
    let link = MCPContentBlock.resourceLink(
      try MCPResourceLinkContent(uri: "file:///tmp/a", name: "a", size: 3))
    let embedded = MCPContentBlock.resource(
      MCPEmbeddedResourceContent(
        resource: try MCPResourceContents(uri: "file:///tmp/a", text: "hello")))
    for value in [text, image, link, embedded] { try assertRoundTrip(value) }
    guard case .text(let decoded) = try MCPContentBlock(json: text.json) else {
      return XCTFail("expected text")
    }
    XCTAssertEqual(decoded.text, "data:text/plain;base64,SGVsbG8=")
  }

  func testModelMetadataUsesCanonicalMetaKeyValidationAndRoundTrips() throws {
    let metadata: [String: MCPJSONValue] = ["com.example/tag": .string("value")]
    let text = try MCPTextContent(text: "hello", metadata: metadata)
    try assertRoundTrip(text)

    let tool = try MCPTool(
      name: "meta",
      inputSchema: ["type": .string("object")],
      metadata: metadata
    )
    try assertRoundTrip(tool)

    let subscription = try MCPSubscriptionsListenResult(
      subscriptionID: .string("subscription-1"),
      metadataExtensions: metadata
    )
    try assertRoundTrip(subscription)
    XCTAssertEqual(subscription.metadataExtensions, metadata)

    for invalid in ["com..example/tag", "com.example/tag/extra"] {
      XCTAssertThrowsError(try MCPTextContent(text: "hello", metadata: [invalid: .null]))
      XCTAssertThrowsError(
        try MCPTool(
          name: "invalid",
          inputSchema: ["type": .string("object")],
          metadata: [invalid: .null]
        )
      )
      XCTAssertThrowsError(
        try MCPSubscriptionsListenResult(
          subscriptionID: MCPRequestID(1),
          metadataExtensions: [invalid: .null]
        )
      )
    }
  }

  func testContentValidationRejectsAmbiguousOrMalformedValues() {
    XCTAssertThrowsError(
      try MCPResourceContents(uri: "file:///a", text: "a", blob: "YQ==")
    )
    XCTAssertThrowsError(
      try MCPResourceContents(uri: "file:///a", text: nil, blob: nil)
    )
    XCTAssertThrowsError(
      try MCPBinaryContent(kind: .audio, data: "not-base64", mimeType: "audio/wav")
    )
    XCTAssertThrowsError(
      try MCPAnnotations(priority: try MCPJSONNumber(rawValue: "1.1"))
    )
  }

  func testFormAndURLElicitationValidation() throws {
    let schema: [String: MCPJSONValue] = [
      "type": .string("object"),
      "properties": .object([
        "name": .object(["type": .string("string"), "minLength": .integer(1)]),
        "count": .object([
          "type": .string("integer"), "minimum": .integer(1), "maximum": .integer(3),
        ]),
        "tags": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
      ]),
      "required": .array([.string("name")]),
      "additionalProperties": .bool(false),
    ]
    let form = try MCPElicitationParams(mode: .form, message: "Need input", requestedSchema: schema)
    let accepted = try MCPElicitationResult(
      action: .accept,
      content: ["name": .string("Ada"), "count": .integer(2), "tags": .array([.string("x")])]
    )
    XCTAssertNoThrow(try form.validate(result: accepted))
    XCTAssertThrowsError(
      try form.validate(
        result: MCPElicitationResult(action: .accept, content: ["count": .integer(9)]))
    )
    try assertRoundTrip(MCPElicitationRequest(params: form))

    let unicodeLengthForm = try MCPElicitationParams(
      mode: .form,
      message: "Need two code points",
      requestedSchema: [
        "type": .string("object"),
        "properties": .object([
          "text": .object([
            "type": .string("string"), "minLength": .integer(2), "maxLength": .integer(2),
          ])
        ]),
        "required": .array([.string("text")]),
      ]
    )
    XCTAssertNoThrow(
      try unicodeLengthForm.validate(
        result: MCPElicitationResult(
          action: .accept, content: ["text": .string("e\u{301}")]
        ))
    )
    XCTAssertThrowsError(
      try unicodeLengthForm.validate(
        result: MCPElicitationResult(
          action: .accept, content: ["text": .string("é")]
        ))
    )

    let url = try MCPElicitationParams(
      mode: .url,
      message: "Authorize",
      url: "https://example.com/consent"
    )
    XCTAssertNoThrow(try url.validate(result: MCPElicitationResult(action: .accept)))
    XCTAssertThrowsError(
      try url.validate(result: MCPElicitationResult(action: .accept, content: ["x": .string("y")]))
    )
    XCTAssertThrowsError(
      try MCPElicitationResult(action: .decline, content: [:])
    )
  }

  func testToolModelsCompleteAndInputRequired() throws {
    let tool = try MCPTool(
      name: "echo",
      description: "Echo",
      inputSchema: [
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
      ],
      outputSchema: ["type": .string("object")]
    )
    try assertRoundTrip(tool)

    let composedSchemaTool = try MCPTool(
      name: "composed",
      inputSchema: [
        "type": .string("object"),
        "$defs": .object([
          "arguments": .object([
            "type": .string("object"),
            "properties": .object(["value": .object(["type": .string("string")])]),
          ])
        ]),
        "$ref": .string("#/$defs/arguments"),
      ]
    )
    XCTAssertNoThrow(
      try MCPJSONSchemaValidator().validateSchema(.object(composedSchemaTool.inputSchema)))
    try assertRoundTrip(composedSchemaTool)

    try assertRoundTrip(
      MCPListToolsResult(
        tools: [tool],
        nextCursor: "next",
        cache: try MCPCachePolicy(ttlMilliseconds: 10, scope: .public)
      ))

    let complete = try MCPCallToolResult(
      content: [.text(MCPTextContent(text: "ok"))],
      structuredContent: .object(["ok": .bool(true)])
    )
    try assertRoundTrip(complete)

    let request = MCPListToolsResult(tools: [])
    XCTAssertEqual(request.json.objectValue?["resultType"], .string("complete"))
    XCTAssertEqual(request.json.objectValue?["tools"], .array([]))

    let input = try MCPElicitationRequest(
      params: MCPElicitationParams(
        mode: .url,
        message: "Authorize",
        url: "https://example.com"
      ))
    let pending = try MCPCallToolResult(
      resultType: .inputRequired,
      inputRequests: ["auth": input],
      requestState: "state-1"
    )
    try assertRoundTrip(pending)
    XCTAssertNil(pending.json.objectValue?["content"])
    XCTAssertThrowsError(
      try MCPCallToolResult(resultType: .inputRequired)
    )
    XCTAssertThrowsError(
      try MCPCallToolResult(content: [], resultType: .complete, inputRequests: ["x": input])
    )
  }

  func testPromptResourceAndCompletionModelsRoundTrip() throws {
    let argument = try MCPPromptArgument(name: "topic", required: true)
    let prompt = try MCPPrompt(name: "summarize", arguments: [argument])
    try assertRoundTrip(prompt)
    let promptResult = try MCPGetPromptResult(
      description: "summary",
      messages: [MCPPromptMessage(role: .user, content: .text(MCPTextContent(text: "hello")))]
    )
    try assertRoundTrip(promptResult)
    try assertRoundTrip(MCPListPromptsResult(prompts: [prompt]))

    let resource = try MCPResource(uri: "file:///tmp/a", name: "a", size: 5)
    let template = try MCPResourceTemplate(uriTemplate: "file:///{path}", name: "file")
    try assertRoundTrip(resource)
    try assertRoundTrip(template)
    try assertRoundTrip(MCPListResourcesResult(resources: [resource]))
    try assertRoundTrip(MCPListResourceTemplatesResult(resourceTemplates: [template]))
    try assertRoundTrip(
      MCPReadResourceResult(contents: [try MCPResourceContents(uri: resource.uri, text: "data")])
    )

    let completeParams = MCPCompleteParams(
      reference: .prompt(name: prompt.name),
      argument: try MCPCompletionArgument(name: "topic", value: "sw"),
      contextArguments: ["language": "en"]
    )
    try assertRoundTrip(completeParams)
    let resourceCompleteParams = MCPCompleteParams(
      reference: .resource(uri: template.uriTemplate),
      argument: try MCPCompletionArgument(name: "path", value: "/tmp"),
      contextArguments: ["language": "en"]
    )
    try assertRoundTrip(resourceCompleteParams)
    try assertRoundTrip(
      MCPCompleteResult(completion: try MCPCompletion(values: ["swift"], total: 1, hasMore: false)))
    XCTAssertThrowsError(try MCPCompletion(values: Array(repeating: "value", count: 101)))
    XCTAssertThrowsError(
      try MCPCompleteResult(json: .object(["resultType": .string("complete")]))
    )
    XCTAssertThrowsError(
      try MCPIcon(source: "https://example.com/icon.png", theme: "high-contrast"))
  }

  func testOperationResultWithoutResultTypeIsRejectedInTheStrictStatelessProfile() {
    let input: MCPJSONValue = .object([
      "content": .array([MCPContentBlock.text(MCPTextContent(text: "hello")).json])
    ])
    XCTAssertThrowsError(try MCPCallToolResult(json: input))
  }

  func testIconSourceRejectsSchemesOutsideHTTPSAndData() throws {
    try assertRoundTrip(try MCPIcon(source: "https://example.com/icon.png", mimeType: "image/png"))
    try assertRoundTrip(try MCPIcon(source: "data:image/png;base64,AAAA"))
    // Scheme comparison is case-insensitive per RFC 3986.
    XCTAssertNoThrow(try MCPIcon(source: "HTTPS://example.com/icon.png"))

    // MCP requires icon consumers to reject unsafe schemes. Rejecting them at the model boundary
    // keeps an executable or local-file URI from reaching a host that renders icons.
    for unsafe in [
      "javascript:alert(1)",
      "file:///etc/passwd",
      "ftp://example.com/icon.png",
      "ws://example.com/icon.png",
      "http://example.com/icon.png",
      "myapp://open",
      "//example.com/icon.png",
      "example.com/icon.png",
      ":https://example.com",
      "1https://example.com/icon.png",

      // An allowed scheme is not on its own a safe source. A `data:` URI whose media type is not
      // an image renders as its declared type in any host that loads the source into a web view,
      // and a scheme-only `https:` reference names no host for the renderer to fetch from.
      "data:text/html,<script>alert(1)</script>",
      "data:text/html;base64,PHNjcmlwdD4=",
      "data:,plain",
      "data:;base64,AAAA",
      "data:image/png",
      "data:",
      "https:",
      "https:foo",
      "https:/example.com/icon.png",
      "https://",
      "https://user@example.com/icon.png",
      "https://example.com/ic on.png",
      "https://example.com/icon.png\n",
    ] {
      XCTAssertThrowsError(try MCPIcon(source: unsafe), unsafe)
      XCTAssertThrowsError(
        try MCPIcon(json: .object(["src": .string(unsafe)])),
        unsafe
      )
    }

    // Uppercase and parameterised media types stay acceptable; a non-image one does not, whether
    // it arrives in the payload or in the declared `mimeType`.
    XCTAssertNoThrow(try MCPIcon(source: "data:IMAGE/SVG+XML;charset=utf-8,%3Csvg%2F%3E"))
    XCTAssertNoThrow(try MCPIcon(source: "https://example.com:8443/icon.png?v=1#a"))
    XCTAssertThrowsError(
      try MCPIcon(source: "https://example.com/icon.png", mimeType: "text/html"))
    XCTAssertThrowsError(
      try MCPIcon(
        json: .object([
          "src": .string("https://example.com/icon.png"),
          "mimeType": .string("text/html"),
        ])))
  }

  func testSubscriptionFilterAndReducerAreExplicitAndStrict() throws {
    let requested = try MCPSubscriptionFilter(
      toolsListChanged: true,
      resourceSubscriptions: ["file:///a", "file:///b"]
    )
    let capabilities = try MCPServerCapabilities(
      tools: true,
      toolListChanged: true,
      resources: true,
      resourceSubscriptions: true
    )
    let accepted = try requested.accepted(by: capabilities)
    XCTAssertEqual(accepted, requested)

    var transition = try MCPSubscriptionReducer.reduce(
      state: .opening(requested: requested), event: .acknowledge(accepted))
    XCTAssertEqual(transition.1, [.sendAcknowledgement])
    transition = try MCPSubscriptionReducer.reduce(state: transition.0, event: .beginListening)
    transition = try MCPSubscriptionReducer.reduce(state: transition.0, event: .receiveNotification)
    transition = try MCPSubscriptionReducer.reduce(state: transition.0, event: .gracefulClose)
    XCTAssertEqual(transition.0, .completed(notificationCount: 1))
    XCTAssertEqual(transition.1, [.sendTerminalResult])

    let tooBroad = try MCPSubscriptionFilter(promptsListChanged: true)
    XCTAssertThrowsError(
      try MCPSubscriptionReducer.reduce(
        state: .opening(requested: requested), event: .acknowledge(tooBroad))
    )
  }
  func testExactNumericModelValidationDoesNotRoundThroughDouble() throws {
    XCTAssertThrowsError(
      try MCPAnnotations(priority: MCPJSONNumber(rawValue: "1.0000000000000000000000000000000001"))
    )
    XCTAssertThrowsError(
      try MCPAnnotations(priority: MCPJSONNumber(rawValue: "-1e-100000000000000000000"))
    )
    XCTAssertNoThrow(
      try MCPAnnotations(priority: MCPJSONNumber(rawValue: "10e-1"))
    )

    let hugeProgress = try MCPJSONNumber(rawValue: "1e100000000000000000000")
    let hugeTotal = try MCPJSONNumber(rawValue: "2e100000000000000000000")
    XCTAssertNoThrow(
      try MCPProgressParams(
        progressToken: MCPProgressToken(1),
        progress: hugeProgress,
        total: hugeTotal
      )
    )
    XCTAssertNoThrow(
      try MCPProgressParams(
        progressToken: MCPProgressToken(1),
        progress: hugeTotal,
        total: hugeProgress
      )
    )

    let schema: [String: MCPJSONValue] = [
      "type": .string("object"),
      "properties": .object([
        "count": .object([
          "type": .string("integer"),
          "minimum": .number(try MCPJSONNumber(rawValue: "9007199254740993123456789")),
          "maximum": .number(try MCPJSONNumber(rawValue: "9007199254740993123456791")),
        ])
      ]),
      "required": .array([.string("count")]),
      "additionalProperties": .bool(false),
    ]
    let elicitation = try MCPElicitationParams(
      mode: .form,
      message: "Exact integer",
      requestedSchema: schema
    )
    XCTAssertNoThrow(
      try elicitation.validate(
        result: MCPElicitationResult(
          action: .accept,
          content: ["count": .number(try MCPJSONNumber(rawValue: "9007199254740993123456790.0"))]
        )
      )
    )
    XCTAssertThrowsError(
      try elicitation.validate(
        result: MCPElicitationResult(
          action: .accept,
          content: ["count": .number(try MCPJSONNumber(rawValue: "9007199254740993123456791.1"))]
        )
      )
    )
  }

}
