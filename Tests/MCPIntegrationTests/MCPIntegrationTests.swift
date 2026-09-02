import MCPHTTPClient
import MCPHTTPServer
import MCPStdioClient
import MCPStdioServer
import XCTest

@testable import MCP

private actor IntegrationCapture<Value: Sendable> {
  private var values: [Value] = []

  func append(_ value: Value) {
    values.append(value)
  }

  func snapshot() -> [Value] {
    values
  }
}

extension MCPInputResponse {
  fileprivate var elicitationResult: MCPElicitationResult? {
    guard case .elicitation(let result) = self else { return nil }
    return result
  }
}

private actor IntegrationInputProvider: MCPInputProvider {
  private var contexts: [MCPMRTRContext] = []
  private let response: MCPElicitationResult

  init(response: MCPElicitationResult) {
    self.response = response
  }

  func resolve(
    _ request: MCPInputRequest,
    context: MCPMRTRContext
  ) async throws -> MCPInputResponse {
    guard case .elicitation = request else {
      throw MCPClientError.protocolViolation("integration provider expected elicitation")
    }
    contexts.append(context)
    return .elicitation(response)
  }

  func observedContexts() -> [MCPMRTRContext] {
    contexts
  }
}

private actor FailingInputProvider: MCPInputProvider {
  private var callCount = 0

  func resolve(
    _ request: MCPInputRequest,
    context: MCPMRTRContext
  ) async throws -> MCPInputResponse {
    _ = request
    _ = context
    callCount += 1
    throw MCPClientError.protocolViolation("provider must not be called")
  }

  func calls() -> Int {
    callCount
  }
}

final class MCPIntegrationTests: XCTestCase {
  private func implementation(_ name: String) throws -> MCPImplementation {
    try MCPImplementation(name: name, version: "1.0.0")
  }

  private func client(
    server: MCPServer,
    elicitation: MCPElicitationCapabilities? = nil,
    startingRequestID: Int64 = 1
  ) throws -> MCPClient {
    try MCPClient(
      transport: MCPInMemoryClientTransport(server: server),
      configuration: MCPClientConfiguration(
        implementation: implementation("integration-client"),
        capabilities: MCPClientCapabilities(elicitation: elicitation),
        requestTimeout: .seconds(2)
      ),
      startingRequestID: startingRequestID
    )
  }

  func testAllStandardFeatureFamiliesShareOneStatelessRuntime() async throws {
    let tool = try MCPTool(
      name: "echo",
      description: "Echo text",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "text": .object(["type": .string("string")])
        ]),
      ],
      outputSchema: ["type": .string("object")]
    )
    let prompt = try MCPPrompt(
      name: "summarize",
      arguments: [try MCPPromptArgument(name: "topic", required: true)]
    )
    let resource = try MCPResource(
      uri: "memory://document/1",
      name: "document-1",
      mimeType: "text/plain",
      size: 5
    )
    let resourceTemplate = try MCPResourceTemplate(
      uriTemplate: "memory://document/{id}",
      name: "document"
    )

    var builder = try MCPServerBuilder(
      implementation: implementation("integration-server"),
      instructions: "Strict MCP 2026-07-28 integration server"
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { params, _ in
      let text = params.arguments["text"]?.stringValue ?? ""
      return try MCPCallToolResult(
        content: [.text(MCPTextContent(text: text))],
        structuredContent: .object(["echo": .string(text)])
      )
    }
    try builder.register(MCPStandardMethods.listPrompts) { _, _ in
      MCPListPromptsResult(prompts: [prompt])
    }
    try builder.register(MCPStandardMethods.getPrompt) { params, _ in
      let topic = params.arguments["topic"] ?? ""
      return try MCPGetPromptResult(
        description: "Summary request",
        messages: [
          MCPPromptMessage(
            role: .user,
            content: .text(MCPTextContent(text: "Summarize \(topic)"))
          )
        ]
      )
    }
    try builder.register(MCPStandardMethods.listResources) { _, _ in
      MCPListResourcesResult(resources: [resource])
    }
    try builder.register(MCPStandardMethods.listResourceTemplates) { _, _ in
      MCPListResourceTemplatesResult(resourceTemplates: [resourceTemplate])
    }
    try builder.register(MCPStandardMethods.readResource) { params, _ in
      try MCPReadResourceResult(
        contents: [
          MCPResourceContents(
            uri: params.uri,
            mimeType: "text/plain",
            text: "hello"
          )
        ]
      )
    }
    try builder.register(MCPStandardMethods.complete) { params, _ in
      let value = params.argument.value.hasPrefix("sw") ? ["swift"] : []
      return MCPCompleteResult(
        completion: try MCPCompletion(values: value, total: Int64(value.count), hasMore: false)
      )
    }
    builder.enableToolListChanged()
    builder.enablePromptListChanged()
    builder.enableResourceListChanged()
    builder.enableResourceSubscriptions()

    let server = try builder.build()
    let client = try client(server: server)

    let discovery = try await client.discover()
    XCTAssertEqual(discovery.supportedVersions, ["2026-07-28"])
    XCTAssertTrue(discovery.capabilities.tools)
    XCTAssertTrue(discovery.capabilities.prompts)
    XCTAssertTrue(discovery.capabilities.resources)
    XCTAssertTrue(discovery.capabilities.completions)
    XCTAssertTrue(discovery.capabilities.toolListChanged)
    XCTAssertTrue(discovery.capabilities.promptListChanged)
    XCTAssertTrue(discovery.capabilities.resourceListChanged)
    XCTAssertTrue(discovery.capabilities.resourceSubscriptions)

    let listedTools = try await client.listTools()
    XCTAssertEqual(listedTools.tools.map(\.name), ["echo"])
    let called = try await client.callTool(
      try MCPCallToolParams(name: "echo", arguments: ["text": .string("hello")])
    )
    XCTAssertEqual(called.structuredContent, .object(["echo": .string("hello")]))

    let listedPrompts = try await client.listPrompts()
    XCTAssertEqual(listedPrompts.prompts.map(\.name), ["summarize"])
    let prompted = try await client.getPrompt(
      try MCPGetPromptParams(name: "summarize", arguments: ["topic": "Swift"])
    )
    XCTAssertEqual(prompted.messages.count, 1)
    XCTAssertEqual(prompted.descriptionText, "Summary request")

    let listedResources = try await client.listResources()
    XCTAssertEqual(listedResources.resources.map(\.uri), [resource.uri])
    let listedTemplates = try await client.listResourceTemplates()
    XCTAssertEqual(
      listedTemplates.resourceTemplates.map(\.uriTemplate), [resourceTemplate.uriTemplate])
    let read = try await client.readResource(try MCPReadResourceParams(uri: resource.uri))
    XCTAssertEqual(read.contents.first?.text, "hello")

    let completion = try await client.complete(
      MCPCompleteParams(
        reference: .prompt(name: prompt.name),
        argument: try MCPCompletionArgument(name: "topic", value: "sw"),
        contextArguments: ["language": "en"]
      )
    )
    XCTAssertEqual(completion.completion.values, ["swift"])
    let resourceCompletion = try await client.complete(
      MCPCompleteParams(
        reference: .resource(uri: resourceTemplate.uriTemplate),
        argument: try MCPCompletionArgument(name: "id", value: "sw")
      )
    )
    XCTAssertEqual(resourceCompletion.completion.values, ["swift"])
  }

  func testMRTRCollectsFormInputWithoutMutatingOriginalArguments() async throws {
    let observed = IntegrationCapture<(MCPRequestID, MCPCallToolParams)>()
    let schema: [String: MCPJSONValue] = [
      "type": .string("object"),
      "properties": .object([
        "name": .object(["type": .string("string"), "minLength": .integer(1)])
      ]),
      "required": .array([.string("name")]),
      "additionalProperties": .bool(false),
    ]
    let inputRequest = try MCPElicitationRequest(
      params: MCPElicitationParams(
        mode: .form,
        message: "Name is required",
        requestedSchema: schema
      )
    )

    var builder = try MCPServerBuilder(implementation: implementation("mrtr-server"))
    let tool = try MCPTool(
      name: "welcome",
      inputSchema: ["type": .string("object")],
      outputSchema: ["type": .string("object")]
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { params, context in
      await observed.append((context.id, params))
      guard let response = params.inputResponses["name"] else {
        return try MCPCallToolResult(
          resultType: .inputRequired,
          inputRequests: ["name": .elicitation(inputRequest)],
          requestState: "welcome-v1"
        )
      }
      guard response.elicitationResult?.content?["name"] == .string("Ada"),
        params.arguments == ["language": .string("ko")],
        params.requestState == "welcome-v1"
      else {
        throw MCPClientError.protocolViolation("MRTR retry did not preserve request authority")
      }
      return try MCPCallToolResult(
        content: [.text(MCPTextContent(text: "Welcome Ada"))],
        structuredContent: .object(["name": .string("Ada")])
      )
    }
    let server = try builder.build()
    let client = try client(
      server: server,
      elicitation: try MCPElicitationCapabilities(form: true, url: false),
      startingRequestID: 10
    )
    let provider = IntegrationInputProvider(
      response: try MCPElicitationResult(
        action: .accept,
        content: ["name": .string("Ada")]
      )
    )

    let result = try await client.callToolResolvingInput(
      try MCPCallToolParams(name: "welcome", arguments: ["language": .string("ko")]),
      provider: provider,
      policy: try MCPMRTRPolicy(retryDelay: .zero)
    )

    XCTAssertEqual(result.structuredContent, .object(["name": .string("Ada")]))
    let requests = await observed.snapshot()
    XCTAssertEqual(requests.map(\.0), [MCPRequestID(10), MCPRequestID(11)])
    XCTAssertTrue(requests.allSatisfy { $0.1.arguments == ["language": .string("ko")] })
    XCTAssertEqual(requests[0].1.inputResponses, [:])
    XCTAssertEqual(requests[1].1.requestState, "welcome-v1")
    let providerContexts = await provider.observedContexts()
    XCTAssertEqual(
      providerContexts,
      [
        MCPMRTRContext(method: "tools/call", requestKey: "name", round: 0)
      ])
  }

  func testMRTRRequestStateOnlyRetryAndRepeatedRoundIsBounded() async throws {
    let requestStateCalls = IntegrationCapture<MCPCallToolParams>()
    var retryBuilder = try MCPServerBuilder(implementation: implementation("state-retry-server"))
    let tool = try MCPTool(name: "poll", inputSchema: ["type": .string("object")])
    retryBuilder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try retryBuilder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try retryBuilder.register(MCPStandardMethods.callTool) { params, _ in
      await requestStateCalls.append(params)
      if params.requestState == nil {
        return try MCPCallToolResult(resultType: .inputRequired, requestState: "poll-1")
      }
      return try MCPCallToolResult(content: [.text(MCPTextContent(text: "ready"))])
    }
    let retryClient = try client(
      server: retryBuilder.build(),
      elicitation: try MCPElicitationCapabilities(form: true, url: false)
    )
    let unusedProvider = FailingInputProvider()
    let completed = try await retryClient.callToolResolvingInput(
      try MCPCallToolParams(name: "poll", arguments: ["job": .string("42")]),
      provider: unusedProvider,
      policy: try MCPMRTRPolicy(retryDelay: .zero)
    )
    XCTAssertEqual(completed.resultType, .complete)
    let providerCallCount = await unusedProvider.calls()
    XCTAssertEqual(providerCallCount, 0)
    let retryCalls = await requestStateCalls.snapshot()
    XCTAssertEqual(retryCalls.count, 2)
    XCTAssertEqual(retryCalls[1].requestState, "poll-1")
    XCTAssertTrue(retryCalls.allSatisfy { $0.arguments == ["job": .string("42")] })

    let repeatedInput = try MCPElicitationRequest(
      params: MCPElicitationParams(
        mode: .form,
        message: "Repeat",
        requestedSchema: [
          "type": .string("object"),
          "properties": .object(["value": .object(["type": .string("string")])]),
        ]
      )
    )
    let repeatedCalls = IntegrationCapture<MCPCallToolParams>()
    var repeatedBuilder = try MCPServerBuilder(implementation: implementation("repeat-server"))
    repeatedBuilder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try repeatedBuilder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try repeatedBuilder.register(MCPStandardMethods.callTool) { params, _ in
      await repeatedCalls.append(params)
      return try MCPCallToolResult(
        resultType: .inputRequired,
        inputRequests: ["value": .elicitation(repeatedInput)],
        requestState: "same"
      )
    }
    let repeatedClient = try client(
      server: repeatedBuilder.build(),
      elicitation: try MCPElicitationCapabilities(form: true, url: false)
    )
    let repeatedProvider = IntegrationInputProvider(
      response: try MCPElicitationResult(
        action: .accept,
        content: ["value": .string("x")]
      )
    )

    do {
      _ = try await repeatedClient.callToolResolvingInput(
        try MCPCallToolParams(name: "poll"),
        provider: repeatedProvider,
        policy: try MCPMRTRPolicy(maximumRoundTrips: 4, retryDelay: .zero)
      )
      XCTFail("expected repeated MRTR rounds to reach the configured bound")
    } catch let error as MCPClientError {
      guard case .maximumRoundTripsExceeded(let limit) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(limit, 4)
    }
    let calls = await repeatedCalls.snapshot()
    XCTAssertEqual(calls.count, 5)
    XCTAssertNil(calls[0].requestState)
    XCTAssertTrue(calls.dropFirst().allSatisfy { $0.requestState == "same" })
    XCTAssertTrue(
      calls.dropFirst().allSatisfy {
        $0.inputResponses["value"]?.elicitationResult?.action == .accept
      })
    let contexts = await repeatedProvider.observedContexts()
    XCTAssertEqual(
      contexts,
      (0..<4).map { MCPMRTRContext(method: "tools/call", requestKey: "value", round: $0) }
    )
  }
}
