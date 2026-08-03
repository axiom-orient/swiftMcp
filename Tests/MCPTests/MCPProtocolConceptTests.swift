import Foundation
import XCTest

@testable import MCP

private actor ConceptTranscript {
  private var remainingFrames: [[MCPWireMessage]]
  private var recordedRequests: [MCPWireRequest] = []

  init(frames: [[MCPWireMessage]]) {
    remainingFrames = frames
  }

  func frames(for request: MCPWireRequest) throws -> [MCPWireMessage] {
    guard !remainingFrames.isEmpty else {
      throw MCPClientError.transport("unexpected request \(request.method)")
    }
    recordedRequests.append(request)
    return remainingFrames.removeFirst()
  }

  func requests() -> [MCPWireRequest] { recordedRequests }
}

private struct ConceptTranscriptTransport: MCPClientTransport {
  let endpointIdentity: String
  let transcript: ConceptTranscript

  func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    let frames = try await transcript.frames(for: request)
    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream()
    for frame in frames { pair.continuation.yield(frame) }
    pair.continuation.finish()
    return MCPClientExchange(frames: pair.stream, cancel: { _ in })
  }
}

private actor ConceptElicitationProvider: MCPElicitationProvider {
  private let response: MCPElicitationResult
  private var capturedContexts: [MCPMRTRContext] = []

  init(response: MCPElicitationResult) {
    self.response = response
  }

  func elicit(
    _ request: MCPElicitationRequest,
    context: MCPMRTRContext
  ) async throws -> MCPElicitationResult {
    _ = request
    capturedContexts.append(context)
    return response
  }

  func contexts() -> [MCPMRTRContext] { capturedContexts }
}

final class MCPProtocolConceptTests: XCTestCase {
  private func implementation(_ name: String) throws -> MCPImplementation {
    try MCPImplementation(name: name, version: "1.0")
  }

  private func client(
    transcript: ConceptTranscript,
    capabilities: MCPClientCapabilities? = nil,
    startingRequestID: Int64 = 1
  ) throws -> MCPClient {
    let resolvedCapabilities: MCPClientCapabilities
    if let capabilities {
      resolvedCapabilities = capabilities
    } else {
      resolvedCapabilities = try MCPClientCapabilities()
    }
    return try MCPClient(
      transport: ConceptTranscriptTransport(endpointIdentity: "concept", transcript: transcript),
      configuration: MCPClientConfiguration(
        implementation: implementation("concept-client"),
        capabilities: resolvedCapabilities,
        requestTimeout: nil
      ),
      startingRequestID: startingRequestID
    )
  }

  func testEveryIndependentRequestCarriesCurrentMetadataAndCallerExtensions() async throws {
    let discover = try MCPDiscoverResult(capabilities: MCPServerCapabilities())
    let list = MCPListToolsResult(tools: [], nextCursor: "page-2")
    let transcript = ConceptTranscript(frames: [
      [.result(MCPWireResult(id: MCPRequestID(7), value: discover.json.objectValue ?? [:]))],
      [.result(MCPWireResult(id: MCPRequestID(8), value: list.json.objectValue ?? [:]))],
    ])
    let client = try client(transcript: transcript, startingRequestID: 7)

    _ = try await client.discover(metadataExtensions: ["com.example/tenant": .string("a")])
    let response = try await client.listTools(
      cursor: "page-1",
      metadataExtensions: ["com.example/tenant": .string("b")]
    )

    XCTAssertEqual(response.nextCursor, "page-2")
    let requests = await transcript.requests()
    XCTAssertEqual(requests.map(\.method), ["server/discover", "tools/list"])
    XCTAssertNil(requests[0].params["cursor"])
    XCTAssertEqual(requests[1].params["cursor"], .string("page-1"))

    let firstMetadata = try MCPRequestMetadata.extract(from: requests[0].params)
    let secondMetadata = try MCPRequestMetadata.extract(from: requests[1].params)
    XCTAssertEqual(firstMetadata.protocolVersion, .current)
    XCTAssertEqual(secondMetadata.protocolVersion, .current)
    XCTAssertEqual(firstMetadata.clientInfo?.name, "concept-client")
    XCTAssertEqual(secondMetadata.clientInfo?.name, "concept-client")
    XCTAssertEqual(firstMetadata.extensions["com.example/tenant"], .string("a"))
    XCTAssertEqual(secondMetadata.extensions["com.example/tenant"], .string("b"))
  }

  func testPaginationUsesExplicitCursorsAcrossAllDiscoverableCollections() async throws {
    let transcript = ConceptTranscript(frames: [
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(20),
            value: MCPListToolsResult(tools: [], nextCursor: "tools-next").json.objectValue ?? [:]
          ))
      ],
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(21),
            value: MCPListPromptsResult(prompts: [], nextCursor: "prompts-next").json.objectValue
              ?? [:]
          ))
      ],
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(22),
            value: MCPListResourcesResult(resources: [], nextCursor: "resources-next").json
              .objectValue
              ?? [:]
          ))
      ],
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(23),
            value: MCPListResourceTemplatesResult(
              resourceTemplates: [], nextCursor: "templates-next"
            ).json.objectValue ?? [:]
          ))
      ],
    ])
    let client = try client(transcript: transcript, startingRequestID: 20)

    let tools = try await client.listTools(cursor: "tools")
    let prompts = try await client.listPrompts(cursor: "prompts")
    let resources = try await client.listResources(cursor: "resources")
    let templates = try await client.listResourceTemplates(cursor: "templates")
    XCTAssertEqual(tools.nextCursor, "tools-next")
    XCTAssertEqual(prompts.nextCursor, "prompts-next")
    XCTAssertEqual(resources.nextCursor, "resources-next")
    XCTAssertEqual(templates.nextCursor, "templates-next")

    let requests = await transcript.requests()
    XCTAssertEqual(
      requests.map { $0.params["cursor"] },
      [.string("tools"), .string("prompts"), .string("resources"), .string("templates")]
    )
    for request in requests {
      XCTAssertNoThrow(try MCPRequestMetadata.extract(from: request.params))
    }
  }

  func testMRTRRetriesWithExplicitRequestStateAndValidatedElicitationResponse() async throws {
    let form = try MCPElicitationParams(
      mode: .form,
      message: "Confirm deployment",
      requestedSchema: [
        "type": .string("object"),
        "properties": .object(["confirmed": .object(["type": .string("boolean")])]),
        "required": .array([.string("confirmed")]),
      ]
    )
    let input = MCPElicitationRequest(params: form)
    let pending = try MCPCallToolResult(
      resultType: .inputRequired,
      inputRequests: ["confirm": input],
      requestState: "deployment-1"
    )
    let completed = try MCPCallToolResult(
      content: [.text(MCPTextContent(text: "deployed"))],
      structuredContent: .object(["deployed": .bool(true)])
    )
    let transcript = ConceptTranscript(frames: [
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(40), resultType: .inputRequired, value: pending.json.objectValue ?? [:]
          ))
      ],
      [.result(MCPWireResult(id: MCPRequestID(41), value: completed.json.objectValue ?? [:]))],
    ])
    let provider = ConceptElicitationProvider(
      response: try MCPElicitationResult(action: .accept, content: ["confirmed": .bool(true)])
    )
    let client = try client(
      transcript: transcript,
      capabilities: MCPClientCapabilities(
        elicitation: try MCPElicitationCapabilities(form: true, url: false)
      ),
      startingRequestID: 40
    )
    let policy = try MCPMRTRPolicy(
      maximumRoundTrips: 2,
      maximumInputRequestsPerRound: 2,
      maximumTotalInputRequests: 2,
      maximumRequestStateBytes: 64,
      retryDelay: .zero
    )

    let result = try await client.callToolResolvingInput(
      try MCPCallToolParams(name: "deploy", arguments: ["region": .string("ap-northeast-2")]),
      provider: provider,
      policy: policy
    )

    XCTAssertEqual(result.structuredContent, .object(["deployed": .bool(true)]))
    let contexts = await provider.contexts()
    XCTAssertEqual(
      contexts,
      [MCPMRTRContext(method: "tools/call", requestKey: "confirm", round: 0)]
    )

    let requests = await transcript.requests()
    XCTAssertEqual(requests.map(\.id), [MCPRequestID(40), MCPRequestID(41)])
    let retry = try MCPCallToolParams(json: .object(requests[1].params))
    XCTAssertEqual(retry.name, "deploy")
    XCTAssertEqual(retry.arguments, ["region": .string("ap-northeast-2")])
    XCTAssertEqual(retry.requestState, "deployment-1")
    XCTAssertEqual(retry.inputResponses["confirm"]?.content, ["confirmed": .bool(true)])
  }

  func testMRTRRetriesPromptAndResourceOperationsWithoutConnectionState() async throws {
    let request = MCPElicitationRequest(
      params: try MCPElicitationParams(
        mode: .url,
        message: "Authorize",
        url: "https://example.com/authorize"
      )
    )
    let promptInputRequired = try MCPGetPromptResult(
      resultType: .inputRequired,
      inputRequests: ["authorize": request],
      requestState: "prompt-state"
    )
    let promptComplete = try MCPGetPromptResult(messages: [])
    let resourceInputRequired = try MCPReadResourceResult(
      cache: nil,
      resultType: .inputRequired,
      inputRequests: ["authorize": request],
      requestState: "resource-state"
    )
    let resourceComplete = try MCPReadResourceResult(contents: [])
    let transcript = ConceptTranscript(frames: [
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(60), resultType: .inputRequired,
            value: promptInputRequired.json.objectValue ?? [:]
          ))
      ],
      [.result(MCPWireResult(id: MCPRequestID(61), value: promptComplete.json.objectValue ?? [:]))],
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(62), resultType: .inputRequired,
            value: resourceInputRequired.json.objectValue ?? [:]
          ))
      ],
      [
        .result(
          MCPWireResult(id: MCPRequestID(63), value: resourceComplete.json.objectValue ?? [:]))
      ],
    ])
    let provider = ConceptElicitationProvider(
      response: try MCPElicitationResult(action: .accept)
    )
    let client = try client(
      transcript: transcript,
      capabilities: MCPClientCapabilities(
        elicitation: try MCPElicitationCapabilities(form: false, url: true)
      ),
      startingRequestID: 60
    )
    let policy = try MCPMRTRPolicy(
      maximumRoundTrips: 2,
      maximumInputRequestsPerRound: 2,
      maximumTotalInputRequests: 2,
      maximumRequestStateBytes: 64,
      retryDelay: .zero
    )

    _ = try await client.getPromptResolvingInput(
      try MCPGetPromptParams(name: "review", arguments: ["language": "swift"]),
      provider: provider,
      policy: policy
    )
    _ = try await client.readResourceResolvingInput(
      try MCPReadResourceParams(uri: "file:///workspace/readme"),
      provider: provider,
      policy: policy
    )

    let requests = await transcript.requests()
    let promptRetry = try MCPGetPromptParams(json: .object(requests[1].params))
    let resourceRetry = try MCPReadResourceParams(json: .object(requests[3].params))
    XCTAssertEqual(promptRetry.arguments, ["language": "swift"])
    XCTAssertEqual(promptRetry.requestState, "prompt-state")
    XCTAssertEqual(promptRetry.inputResponses["authorize"]?.action, .accept)
    XCTAssertEqual(resourceRetry.uri, "file:///workspace/readme")
    XCTAssertEqual(resourceRetry.requestState, "resource-state")
    XCTAssertEqual(resourceRetry.inputResponses["authorize"]?.action, .accept)
  }

  func testMRTRRejectsLimitBreachesAndRepeatedRoundsBeforeUnboundedRetry() async throws {
    let request = MCPElicitationRequest(
      params: try MCPElicitationParams(
        mode: .url,
        message: "Authorize",
        url: "https://example.com/authorize"
      )
    )
    let provider = ConceptElicitationProvider(
      response: try MCPElicitationResult(action: .accept)
    )
    let perRoundViolation = try MCPCallToolResult(
      resultType: .inputRequired,
      inputRequests: ["one": request, "two": request],
      requestState: "too-many"
    )
    let perRoundTranscript = ConceptTranscript(frames: [
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(70), resultType: .inputRequired,
            value: perRoundViolation.json.objectValue ?? [:]
          ))
      ]
    ])
    let perRoundClient = try client(
      transcript: perRoundTranscript,
      capabilities: MCPClientCapabilities(
        elicitation: try MCPElicitationCapabilities(form: false, url: true)
      ),
      startingRequestID: 70
    )
    let oneRequestPolicy = try MCPMRTRPolicy(
      maximumRoundTrips: 2,
      maximumInputRequestsPerRound: 1,
      maximumTotalInputRequests: 2,
      maximumRequestStateBytes: 64,
      retryDelay: .zero
    )
    do {
      _ = try await perRoundClient.callToolResolvingInput(
        try MCPCallToolParams(name: "work"), provider: provider, policy: oneRequestPolicy
      )
      XCTFail("per-round limit must stop the retry")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("per-round"))
    }

    let repeatedRound = try MCPCallToolResult(
      resultType: .inputRequired,
      inputRequests: ["authorize": request],
      requestState: "same-round"
    )
    let repeatedTranscript = ConceptTranscript(frames: [
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(80), resultType: .inputRequired,
            value: repeatedRound.json.objectValue ?? [:]
          ))
      ],
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(81), resultType: .inputRequired,
            value: repeatedRound.json.objectValue ?? [:]
          ))
      ],
      [
        .result(
          MCPWireResult(
            id: MCPRequestID(82), resultType: .inputRequired,
            value: repeatedRound.json.objectValue ?? [:]
          ))
      ],
    ])
    let repeatedClient = try client(
      transcript: repeatedTranscript,
      capabilities: MCPClientCapabilities(
        elicitation: try MCPElicitationCapabilities(form: false, url: true)
      ),
      startingRequestID: 80
    )
    let repeatPolicy = try MCPMRTRPolicy(
      maximumRoundTrips: 2,
      maximumInputRequestsPerRound: 1,
      maximumTotalInputRequests: 2,
      maximumRequestStateBytes: 64,
      retryDelay: .zero
    )
    do {
      _ = try await repeatedClient.callToolResolvingInput(
        try MCPCallToolParams(name: "work"), provider: provider, policy: repeatPolicy
      )
      XCTFail("repeated MRTR rounds must be bounded by maximumRoundTrips")
    } catch let error as MCPClientError {
      guard case .maximumRoundTripsExceeded(let limit) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(limit, 2)
    }
    let requests = await repeatedTranscript.requests()
    XCTAssertEqual(requests.map(\.id), [MCPRequestID(80), MCPRequestID(81), MCPRequestID(82)])
    let contexts = await provider.contexts()
    XCTAssertEqual(contexts.suffix(2).map(\.round), [0, 1])
  }
}
