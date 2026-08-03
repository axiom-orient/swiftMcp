import Foundation

public typealias MCPProgressHandler = @Sendable (MCPProgressParams) async throws -> Void

public enum MCPClientSubscriptionEvent: Sendable, Equatable {
  case acknowledged(MCPSubscriptionFilter)
  case notification(MCPWireNotification)
  case completed(MCPSubscriptionsListenResult)
}

public struct MCPClientSubscription: Sendable {
  public let id: MCPRequestID
  public let acceptedNotifications: MCPSubscriptionFilter
  public let events: AsyncThrowingStream<MCPClientSubscriptionEvent, Error>
  private let cancelValue: @Sendable (String?) async throws -> Void

  init(
    id: MCPRequestID,
    acceptedNotifications: MCPSubscriptionFilter,
    events: AsyncThrowingStream<MCPClientSubscriptionEvent, Error>,
    cancel: @escaping @Sendable (String?) async throws -> Void
  ) {
    self.id = id
    self.acceptedNotifications = acceptedNotifications
    self.events = events
    self.cancelValue = cancel
  }

  public func cancel(reason: String? = nil) async throws {
    try await cancelValue(reason)
  }
}

private actor MCPClientSubscriptionControl {
  private let exchange: MCPClientExchange
  private let diagnostics: any MCPDiagnosticSink
  private let requestID: MCPRequestID
  private var worker: Task<Void, Never>?
  private var terminal = false

  init(
    exchange: MCPClientExchange,
    diagnostics: any MCPDiagnosticSink,
    requestID: MCPRequestID
  ) {
    self.exchange = exchange
    self.diagnostics = diagnostics
    self.requestID = requestID
  }

  func install(_ task: Task<Void, Never>) {
    guard !terminal else {
      task.cancel()
      return
    }
    worker = task
  }

  func markTerminal() {
    terminal = true
    worker = nil
  }

  func cancel(reason: String?) async throws {
    guard !terminal else { return }
    terminal = true
    let task = worker
    worker = nil
    task?.cancel()
    try await exchange.cancel(reason: reason ?? "subscription cancelled")
  }

  func consumerTerminated() async {
    do {
      try await cancel(reason: "subscription event consumer terminated")
    } catch {
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.client.subscription.cancellation.failed",
          level: .error,
          fields: [
            "requestID": requestID.description,
            "failure": String(reflecting: type(of: error)),
          ]
        ))
    }
  }
}

public struct MCPClientExchange: Sendable {
  public let frames: AsyncThrowingStream<MCPWireMessage, Error>
  private let cancelValue: @Sendable (String?) async throws -> Void

  public init(
    frames: AsyncThrowingStream<MCPWireMessage, Error>,
    cancel: @escaping @Sendable (String?) async throws -> Void
  ) {
    self.frames = frames
    self.cancelValue = cancel
  }

  public func cancel(reason: String? = nil) async throws {
    try await cancelValue(reason)
  }
}

public protocol MCPClientTransport: Sendable {
  /// Stable transport/endpoint identity used only for diagnostics and optional cache partitioning.
  var endpointIdentity: String { get }

  /// Opens one request-scoped exchange. The returned stream must terminate after one terminal
  /// response, or after cancellation/failure. Implementations must not expose a session API.
  func open(_ request: MCPWireRequest) async throws -> MCPClientExchange
}

/// Optional transport hook for request-derived tool metadata such as HTTP `x-mcp-header`
/// bindings. A tools/list_changed notification invalidates this metadata together with the core
/// client's validation catalog.
public protocol MCPClientToolCatalogInvalidatingTransport: MCPClientTransport {
  func invalidateToolCatalog() async
}

public struct MCPClientConfiguration: Sendable {
  public let implementation: MCPImplementation
  public let capabilities: MCPClientCapabilities
  public let requestTimeout: Duration?
  public let maximumFramesPerRequest: Int
  public let maximumMetadataBytes: Int
  public let subscriptionBufferLimit: Int
  public let traceContext: [String: String]
  public let metadataExtensions: [String: MCPJSONValue]
  public let schemaValidator: any MCPJSONSchemaValidating
  public let cache: (any MCPCacheStore)?
  public let cacheAuthorizationPartition: String?

  public init(
    implementation: MCPImplementation,
    capabilities: MCPClientCapabilities,
    requestTimeout: Duration? = .seconds(30),
    maximumFramesPerRequest: Int = 4_096,
    maximumMetadataBytes: Int = 64 * 1_024,
    subscriptionBufferLimit: Int = 128,
    traceContext: [String: String] = [:],
    metadataExtensions: [String: MCPJSONValue] = [:],
    schemaValidator: any MCPJSONSchemaValidating = MCPJSONSchemaValidator(),
    cache: (any MCPCacheStore)? = nil,
    cacheAuthorizationPartition: String? = nil
  ) throws {
    guard maximumFramesPerRequest > 0 else {
      throw MCPJSONError.invalidField(
        field: "maximumFramesPerRequest", reason: "must be greater than zero")
    }
    guard maximumMetadataBytes > 0 else {
      throw MCPJSONError.invalidField(
        field: "maximumMetadataBytes", reason: "must be greater than zero")
    }
    guard subscriptionBufferLimit > 0 else {
      throw MCPJSONError.invalidField(
        field: "subscriptionBufferLimit", reason: "must be greater than zero")
    }
    // MCPRequestMetadata is the canonical validator for trace and extension metadata.
    _ = try MCPRequestMetadata(
      clientCapabilities: capabilities,
      clientInfo: implementation,
      traceContext: traceContext,
      extensions: metadataExtensions
    )
    self.implementation = implementation
    self.capabilities = capabilities
    self.requestTimeout = requestTimeout
    self.maximumFramesPerRequest = maximumFramesPerRequest
    self.maximumMetadataBytes = maximumMetadataBytes
    self.subscriptionBufferLimit = subscriptionBufferLimit
    if let cacheAuthorizationPartition, cacheAuthorizationPartition.isEmpty {
      throw MCPJSONError.invalidField(
        field: "cacheAuthorizationPartition", reason: "must not be empty")
    }
    self.traceContext = traceContext
    self.metadataExtensions = metadataExtensions
    self.schemaValidator = schemaValidator
    self.cache = cache
    self.cacheAuthorizationPartition = cacheAuthorizationPartition
  }
}

actor MCPRequestIDAllocator {
  private var nextValue: Int64

  init(startingAt: Int64) { nextValue = startingAt }

  func next() throws -> Int64 {
    guard nextValue != Int64.max else {
      throw MCPClientError.protocolViolation("request id space is exhausted")
    }
    let value = nextValue
    nextValue += 1
    return value
  }
}

private struct MCPCompiledClientTool: Sendable {
  let definition: MCPTool
  let inputPlan: any MCPJSONSchemaValidationPlan
  let outputPlan: (any MCPJSONSchemaValidationPlan)?

  init(tool: MCPTool, validator: any MCPJSONSchemaValidating) throws {
    definition = tool
    inputPlan = try validator.compile(.object(tool.inputSchema))
    outputPlan = try tool.outputSchema.map { try validator.compile(.object($0)) }
  }
}

private actor MCPClientToolCatalog {
  private var tools: [String: MCPCompiledClientTool] = [:]
  private var generation: UInt64 = 0

  func snapshotGeneration() -> UInt64 { generation }

  func record(
    _ compiledTools: [MCPCompiledClientTool],
    requestedCursor: String?,
    expectedGeneration: UInt64
  ) throws {
    guard generation == expectedGeneration else { return }
    var next = requestedCursor == nil ? [:] : tools
    for compiled in compiledTools {
      let name = compiled.definition.name
      guard next[name] == nil else {
        throw MCPClientError.protocolViolation(
          "tools/list repeated tool name \(name) across the listing")
      }
      next[name] = compiled
    }
    tools = next
  }

  func tool(named name: String) -> MCPCompiledClientTool? { tools[name] }

  func removeAll() {
    generation &+= 1
    tools.removeAll(keepingCapacity: true)
  }
}

private enum MCPClientCacheEpochDomain: Sendable, Hashable {
  case tools
  case prompts
  case resources
  case resource(String)
  case other(String)
}

private struct MCPClientCacheEpochToken: Sendable {
  let global: UInt64
  let domain: MCPClientCacheEpochDomain
  let domainValue: UInt64
}

private struct MCPClientCacheInvalidationToken: Sendable {
  let id: UInt64
  let invalidation: MCPCacheInvalidation
}

private struct MCPClientCacheWriteLease: Sendable {
  let id: UInt64
}

private actor MCPClientCacheEpochs {
  private var global: UInt64 = 0
  private var domains: [MCPClientCacheEpochDomain: UInt64] = [:]
  private var nextInvalidationID: UInt64 = 0
  private var activeInvalidations: [UInt64: MCPCacheInvalidation] = [:]
  private var nextWriteID: UInt64 = 0
  private var activeWrites: Set<UInt64> = []
  private var cacheDisabled = false

  func snapshot(
    descriptor: MCPMethodDescriptor,
    params: [String: MCPJSONValue]
  ) -> MCPClientCacheEpochToken {
    let domain = Self.domain(descriptor: descriptor, params: params)
    return MCPClientCacheEpochToken(
      global: global,
      domain: domain,
      domainValue: domains[domain, default: 0]
    )
  }

  func isCurrent(_ token: MCPClientCacheEpochToken) -> Bool {
    global == token.global && domains[token.domain, default: 0] == token.domainValue
  }

  func isCacheUsable(_ token: MCPClientCacheEpochToken) -> Bool {
    isCurrent(token) && activeInvalidations.isEmpty && activeWrites.isEmpty && !cacheDisabled
  }

  func beginWrite(expectedEpoch: MCPClientCacheEpochToken) -> MCPClientCacheWriteLease? {
    guard isCurrent(expectedEpoch), activeInvalidations.isEmpty, activeWrites.isEmpty,
      !cacheDisabled
    else { return nil }
    let id = nextWriteID
    nextWriteID &+= 1
    activeWrites.insert(id)
    return MCPClientCacheWriteLease(id: id)
  }

  func finishWrite(_ lease: MCPClientCacheWriteLease) {
    activeWrites.remove(lease.id)
  }

  func failWrite(_ lease: MCPClientCacheWriteLease) {
    activeWrites.remove(lease.id)
    cacheDisabled = true
  }

  func beginInvalidation(_ invalidation: MCPCacheInvalidation)
    -> MCPClientCacheInvalidationToken
  {
    let id = nextInvalidationID
    nextInvalidationID &+= 1
    activeInvalidations[id] = invalidation
    switch invalidation {
    case .all, .endpoint:
      global &+= 1
    case .tools:
      increment(.tools)
    case .prompts:
      increment(.prompts)
    case .resources:
      increment(.resources)
    case .resource(let uri):
      increment(.resource(uri))
    }
    return MCPClientCacheInvalidationToken(id: id, invalidation: invalidation)
  }

  func finishInvalidation(
    _ token: MCPClientCacheInvalidationToken,
    succeeded: Bool
  ) {
    guard activeInvalidations.removeValue(forKey: token.id) != nil else { return }
    if !succeeded {
      // An injected cache store can leave stale physical entries behind. Disable all cache use
      // until a later full invalidation succeeds; this is conservative but cannot return stale
      // authority from a narrower failed operation.
      cacheDisabled = true
    } else if case .all = token.invalidation {
      cacheDisabled = false
    }
  }

  private func increment(_ domain: MCPClientCacheEpochDomain) {
    domains[domain, default: 0] &+= 1
  }

  private static func domain(
    descriptor: MCPMethodDescriptor,
    params: [String: MCPJSONValue]
  ) -> MCPClientCacheEpochDomain {
    switch descriptor.name {
    case "tools/list": return .tools
    case "prompts/list": return .prompts
    case "resources/list", "resources/templates/list": return .resources
    case "resources/read":
      if case .string(let uri)? = params["uri"] { return .resource(uri) }
      return .other(descriptor.name)
    default:
      return .other(descriptor.name)
    }
  }
}

private enum MCPOpenRaceResult: Sendable {
  case opened(MCPClientExchange)
  case timedOut
  case failed(any Error)
  case cancelled
}

private actor MCPOpenRaceCoordinator {
  private var outcome: MCPOpenRaceResult?
  private var waiter: CheckedContinuation<MCPOpenRaceResult, Never>?

  func resolve(_ candidate: MCPOpenRaceResult) -> Bool {
    guard outcome == nil else { return false }
    outcome = candidate
    let waiter = self.waiter
    self.waiter = nil
    waiter?.resume(returning: candidate)
    return true
  }

  func result() async -> MCPOpenRaceResult {
    if let outcome { return outcome }
    return await withCheckedContinuation { continuation in
      waiter = continuation
    }
  }
}

private enum MCPRequestRaceResult: Sendable {
  case response([String: MCPJSONValue])
  case timedOut
}

private enum MCPSubscriptionOpeningRaceResult: Sendable {
  case acknowledged(MCPSubscriptionFilter?)
  case timedOut
}

public struct MCPClient: Sendable {
  public let configuration: MCPClientConfiguration
  public let registry: MCPMethodRegistry
  public let transport: any MCPClientTransport

  let requestIDs: MCPRequestIDAllocator
  private let toolCatalog: MCPClientToolCatalog
  private let cacheEpochs: MCPClientCacheEpochs
  let diagnostics: any MCPDiagnosticSink

  public init(
    transport: any MCPClientTransport,
    configuration: MCPClientConfiguration,
    extensionMethods: [MCPMethodDescriptor] = [],
    startingRequestID: Int64 = 1,
    diagnostics: any MCPDiagnosticSink = MCPNoopDiagnosticSink()
  ) throws {
    self.transport = transport
    self.configuration = configuration
    self.registry = try MCPMethodRegistry(extensionMethods: extensionMethods)
    self.requestIDs = MCPRequestIDAllocator(startingAt: startingRequestID)
    self.toolCatalog = MCPClientToolCatalog()
    self.cacheEpochs = MCPClientCacheEpochs()
    self.diagnostics = diagnostics
  }

  public func call<Params: MCPJSONModel, Result: MCPJSONModel>(
    _ method: MCPMethod<Params, Result>,
    params: Params,
    progress: MCPProgressHandler? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> Result {
    let rawParams = method.encodeParams(params)
    let toolCatalogGeneration =
      method.descriptor.name == MCPStandardMethods.listTools.descriptor.name
      ? await toolCatalog.snapshotGeneration() : nil
    let knownTool = try await validateToolRequestIfKnown(
      descriptor: method.descriptor,
      params: rawParams
    )
    let raw = try await callRaw(
      descriptor: method.descriptor,
      params: rawParams,
      progress: progress,
      metadataExtensions: metadataExtensions
    )
    if method.descriptor.name == MCPStandardMethods.listTools.descriptor.name {
      let validatedRaw: [String: MCPJSONValue]
      do {
        validatedRaw = try await validateToolResponseIfNeeded(
          descriptor: method.descriptor,
          params: rawParams,
          rawResult: raw,
          knownTool: knownTool,
          toolCatalogGeneration: toolCatalogGeneration
        )
      } catch let error as MCPJSONError {
        throw MCPClientError.protocolViolation(
          "invalid result for \(method.descriptor.name): \(error.description)")
      }
      do {
        return try method.decodeResult(.object(validatedRaw))
      } catch let error as MCPJSONError {
        throw MCPClientError.protocolViolation(
          "invalid result for \(method.descriptor.name): \(error.description)")
      } catch let error as MCPWireError {
        throw MCPClientError.wire(error)
      }
    }
    let result: Result
    do {
      result = try method.decodeResult(.object(raw))
    } catch let error as MCPJSONError {
      throw MCPClientError.protocolViolation(
        "invalid result for \(method.descriptor.name): \(error.description)")
    } catch let error as MCPWireError {
      throw MCPClientError.wire(error)
    }
    _ = try await validateToolResponseIfNeeded(
      descriptor: method.descriptor,
      params: rawParams,
      rawResult: raw,
      knownTool: knownTool,
      toolCatalogGeneration: toolCatalogGeneration
    )
    return result
  }

  public func invalidateCache(_ invalidation: MCPCacheInvalidation = .all) async throws {
    let token = await cacheEpochs.beginInvalidation(invalidation)
    do {
      try await configuration.cache?.invalidate(invalidation)
      await cacheEpochs.finishInvalidation(token, succeeded: true)
    } catch {
      await cacheEpochs.finishInvalidation(token, succeeded: false)
      throw error
    }
  }

  private func validateToolRequestIfKnown(
    descriptor: MCPMethodDescriptor,
    params: MCPJSONValue
  ) async throws -> MCPCompiledClientTool? {
    guard descriptor.name == MCPStandardMethods.callTool.descriptor.name else { return nil }
    let call = try MCPCallToolParams(json: params)
    guard let tool = await toolCatalog.tool(named: call.name) else { return nil }
    do {
      try tool.inputPlan.validate(.object(call.arguments))
    } catch let error as MCPJSONSchemaError {
      throw error
    } catch {
      throw MCPClientError.protocolViolation(
        "tool input validation failed unexpectedly for \(tool.definition.name)")
    }
    return tool
  }

  private func validateToolResponseIfNeeded(
    descriptor: MCPMethodDescriptor,
    params: MCPJSONValue,
    rawResult: [String: MCPJSONValue],
    knownTool: MCPCompiledClientTool?,
    toolCatalogGeneration: UInt64?
  ) async throws -> [String: MCPJSONValue] {
    if descriptor.name == MCPStandardMethods.listTools.descriptor.name {
      // Tool schemas are an independent trust boundary. A client may safely
      // use the rest of a listing even when its validator cannot compile one
      // advertised tool, so retain valid tools and expose the filtered result.
      let result = try MCPListToolsResult(json: .object(rawResult))
      var names = Set<String>()
      var compiledTools: [MCPCompiledClientTool] = []
      var acceptedTools: [MCPTool] = []
      var rejectedToolRequiresHostValidator = false
      compiledTools.reserveCapacity(result.tools.count)
      acceptedTools.reserveCapacity(result.tools.count)
      for tool in result.tools {
        guard names.insert(tool.name).inserted else {
          throw MCPClientError.protocolViolation(
            "tools/list contains duplicate tool name \(tool.name)")
        }
        do {
          let compiled = try MCPCompiledClientTool(
            tool: tool, validator: configuration.schemaValidator)
          compiledTools.append(compiled)
          acceptedTools.append(tool)
        } catch {
          rejectedToolRequiresHostValidator =
            rejectedToolRequiresHostValidator || Self.schemaRequiresHostValidator(error)
          await diagnostics.record(
            MCPDiagnosticEvent(
              id: "mcp.client.tools.list.tool.excluded",
              level: .warning,
              fields: [
                "tool": tool.name,
                "endpoint": transport.endpointIdentity,
                "failure": String(reflecting: type(of: error)),
              ]
            ))
        }
      }
      // A listing whose only tools require a host-provided validator must not silently
      // look like an empty, successful catalog. Locally unsafe tools may still be
      // excluded (including an all-rejected page), while mixed listings remain usable.
      if !result.tools.isEmpty && acceptedTools.isEmpty && rejectedToolRequiresHostValidator {
        throw MCPClientError.protocolViolation(
          "tools/list contains no tool whose input/output schema this client can validate"
        )
      }
      let listParams = try MCPListToolsParams(json: params)
      guard let toolCatalogGeneration else {
        throw MCPClientError.protocolViolation("tools/list catalog generation was not captured")
      }
      try await toolCatalog.record(
        compiledTools,
        requestedCursor: listParams.cursor,
        expectedGeneration: toolCatalogGeneration
      )
      return MCPListToolsResult(
        tools: acceptedTools,
        nextCursor: result.nextCursor,
        cache: result.cache,
        metadata: result.metadata
      ).json.objectValue ?? [:]
    }

    guard descriptor.name == MCPStandardMethods.callTool.descriptor.name,
      let knownTool,
      let outputPlan = knownTool.outputPlan
    else { return rawResult }
    let result = try MCPCallToolResult(json: .object(rawResult))
    guard result.resultType == .complete else { return rawResult }
    guard let structuredContent = result.structuredContent else {
      throw MCPClientError.protocolViolation(
        "tools/call omitted structuredContent required by \(knownTool.definition.name) outputSchema"
      )
    }
    do {
      try outputPlan.validate(structuredContent)
    } catch {
      throw MCPClientError.protocolViolation(
        "tools/call returned structuredContent that violates \(knownTool.definition.name) outputSchema"
      )
    }
    return rawResult
  }

  private static func schemaRequiresHostValidator(_ error: Error) -> Bool {
    guard let schemaError = error as? MCPJSONSchemaError,
      case .invalidSchema(let issues) = schemaError,
      !issues.isEmpty
    else { return false }
    return issues.allSatisfy { issue in
      issue.message.contains("requires a custom schema validator")
        || issue.message.contains("unsupported JSON Schema dialect")
    }
  }

  public func discover(
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPDiscoverResult {
    try await call(
      MCPStandardMethods.discover,
      params: MCPDiscoverParams(),
      metadataExtensions: metadataExtensions
    )
  }

  public func listTools(
    cursor: String? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPListToolsResult {
    try await call(
      MCPStandardMethods.listTools,
      params: MCPListToolsParams(cursor: cursor),
      metadataExtensions: metadataExtensions
    )
  }

  public func callTool(
    _ params: MCPCallToolParams,
    progress: MCPProgressHandler? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPCallToolResult {
    try await call(
      MCPStandardMethods.callTool,
      params: params,
      progress: progress,
      metadataExtensions: metadataExtensions
    )
  }

  public func listPrompts(
    cursor: String? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPListPromptsResult {
    try await call(
      MCPStandardMethods.listPrompts,
      params: MCPListPromptsParams(cursor: cursor),
      metadataExtensions: metadataExtensions
    )
  }

  public func getPrompt(
    _ params: MCPGetPromptParams,
    progress: MCPProgressHandler? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPGetPromptResult {
    try await call(
      MCPStandardMethods.getPrompt,
      params: params,
      progress: progress,
      metadataExtensions: metadataExtensions
    )
  }

  public func listResources(
    cursor: String? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPListResourcesResult {
    try await call(
      MCPStandardMethods.listResources,
      params: MCPListResourcesParams(cursor: cursor),
      metadataExtensions: metadataExtensions
    )
  }

  public func listResourceTemplates(
    cursor: String? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPListResourceTemplatesResult {
    try await call(
      MCPStandardMethods.listResourceTemplates,
      params: MCPListResourceTemplatesParams(cursor: cursor),
      metadataExtensions: metadataExtensions
    )
  }

  public func readResource(
    _ params: MCPReadResourceParams,
    progress: MCPProgressHandler? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPReadResourceResult {
    try await call(
      MCPStandardMethods.readResource,
      params: params,
      progress: progress,
      metadataExtensions: metadataExtensions
    )
  }

  public func complete(
    _ params: MCPCompleteParams,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPCompleteResult {
    try await call(
      MCPStandardMethods.complete,
      params: params,
      metadataExtensions: metadataExtensions
    )
  }

  /// Opens a request-scoped long-lived subscription.
  ///
  /// This method waits for and validates the mandatory acknowledgement before returning. The
  /// acknowledgement is also the first element in `events`, followed by filtered notifications
  /// and exactly one terminal completion event. Interrupted streams are not resumed implicitly.
  public func listen(
    notifications requested: MCPSubscriptionFilter,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPClientSubscription {
    let descriptor = try registry.require(
      MCPStandardMethods.listen.descriptor.name,
      direction: .clientToServerRequest
    )
    guard descriptor == MCPStandardMethods.listen.descriptor else {
      throw MCPClientError.protocolViolation(
        "method descriptor for subscriptions/listen does not match the client registry")
    }

    let extensions = try mergedMetadataExtensions(metadataExtensions)
    let requestID = MCPRequestID(try await requestIDs.next())
    let metadata = try MCPRequestMetadata(
      clientCapabilities: configuration.capabilities,
      clientInfo: configuration.implementation,
      traceContext: configuration.traceContext,
      extensions: extensions
    )
    try metadata.validateEncodedSize(maximumBytes: configuration.maximumMetadataBytes)
    guard
      case .object(let rawParams) = MCPSubscriptionsListenParams(
        notifications: requested
      ).json
    else {
      throw MCPWireError.paramsMustBeObject
    }
    let request = try MCPWireRequest(
      id: requestID,
      method: descriptor.name,
      params: metadata.inserting(into: rawParams)
    )
    let deadline = configuration.requestTimeout.map {
      ContinuousClock.now.advanced(by: $0)
    }

    let exchange: MCPClientExchange
    do {
      exchange = try await openExchange(request, deadline: deadline)
    } catch is CancellationError {
      throw MCPClientError.cancelled
    } catch let error as MCPClientError {
      throw error
    } catch {
      throw clientTransportError(error)
    }

    let eventPair = AsyncThrowingStream<MCPClientSubscriptionEvent, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(configuration.subscriptionBufferLimit)
    )
    let openingPair = AsyncThrowingStream<MCPSubscriptionFilter, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(1)
    )
    let control = MCPClientSubscriptionControl(
      exchange: exchange,
      diagnostics: diagnostics,
      requestID: requestID
    )
    let worker = Task {
      await consumeSubscriptionExchange(
        exchange.frames,
        requestID: requestID,
        requested: requested,
        exchange: exchange,
        openingContinuation: openingPair.continuation,
        eventContinuation: eventPair.continuation,
        control: control
      )
    }
    await control.install(worker)
    eventPair.continuation.onTermination = { @Sendable termination in
      guard case .cancelled = termination else { return }
      Task { await control.consumerTerminated() }
    }

    let accepted: MCPSubscriptionFilter
    do {
      guard
        let value = try await awaitSubscriptionAcknowledgement(
          openingPair.stream,
          deadline: deadline
        )
      else {
        throw MCPClientError.protocolViolation(
          "subscription stream ended before acknowledgement")
      }
      accepted = value
    } catch is CancellationError {
      do {
        try await control.cancel(reason: "subscription opening cancelled")
      } catch {
        throw MCPClientError.transport(
          "subscription opening was cancelled and transport cancellation failed: \(error)")
      }
      throw MCPClientError.cancelled
    } catch {
      do {
        try await control.cancel(reason: "subscription acknowledgement failed")
      } catch let cancellationError {
        throw MCPClientError.transport(
          "subscription opening failed with \(error); cancellation failed with \(cancellationError)"
        )
      }
      throw error
    }

    return MCPClientSubscription(
      id: requestID,
      acceptedNotifications: accepted,
      events: eventPair.stream,
      cancel: { reason in try await control.cancel(reason: reason) }
    )
  }

  private func callRaw(
    descriptor: MCPMethodDescriptor,
    params: MCPJSONValue,
    progress: MCPProgressHandler?,
    metadataExtensions: [String: MCPJSONValue]
  ) async throws -> [String: MCPJSONValue] {
    let registered = try registry.require(descriptor.name)
    guard registered == descriptor else {
      throw MCPClientError.protocolViolation(
        "method descriptor for \(descriptor.name) does not match the client registry")
    }
    guard case .object(let rawParams) = params else {
      throw MCPWireError.paramsMustBeObject
    }
    let extensions = try mergedMetadataExtensions(metadataExtensions)
    let cacheKeys = try await cacheKeysIfEligible(
      descriptor: descriptor,
      params: rawParams,
      semanticMetadata: extensions
    )
    let cacheEpoch = await cacheEpochs.snapshot(descriptor: descriptor, params: rawParams)
    if await cacheEpochs.isCacheUsable(cacheEpoch), let cache = configuration.cache {
      for key in cacheKeys {
        if let entry = try await cache.value(for: key) {
          guard await cacheEpochs.isCacheUsable(cacheEpoch) else { break }
          await diagnostics.record(
            MCPDiagnosticEvent(
              id: "mcp.client.cache.hit",
              level: .debug,
              fields: ["method": descriptor.name, "endpoint": transport.endpointIdentity]
            ))
          return entry.value
        }
      }
    }

    let numericID = try await requestIDs.next()
    let requestID = MCPRequestID(numericID)
    let progressToken = progress == nil ? nil : MCPProgressToken(numericID)
    let metadata = try MCPRequestMetadata(
      clientCapabilities: configuration.capabilities,
      clientInfo: configuration.implementation,
      progressToken: progressToken,
      traceContext: configuration.traceContext,
      extensions: extensions
    )
    try metadata.validateEncodedSize(maximumBytes: configuration.maximumMetadataBytes)
    let request = try MCPWireRequest(
      id: requestID,
      method: descriptor.name,
      params: metadata.inserting(into: rawParams)
    )

    let started = ContinuousClock.now
    let deadline = configuration.requestTimeout.map { started.advanced(by: $0) }
    do {
      let result = try await executeRequest(
        request,
        descriptor: descriptor,
        expectedProgressToken: progressToken,
        progress: progress,
        deadline: deadline
      )
      try await storeInCacheIfEligible(
        result,
        descriptor: descriptor,
        params: rawParams,
        semanticMetadata: extensions,
        expectedEpoch: cacheEpoch
      )
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.client.request.completed",
          level: .info,
          fields: [
            "method": descriptor.name,
            "requestID": requestID.description,
            "endpoint": transport.endpointIdentity,
            "duration": String(describing: ContinuousClock.now - started),
          ]
        ))
      return result
    } catch {
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.client.request.failed",
          level: .error,
          fields: [
            "method": descriptor.name,
            "requestID": requestID.description,
            "endpoint": transport.endpointIdentity,
            "failure": String(reflecting: type(of: error)),
          ]
        ))
      throw error
    }
  }

  private func executeRequest(
    _ request: MCPWireRequest,
    descriptor: MCPMethodDescriptor,
    expectedProgressToken: MCPProgressToken?,
    progress: MCPProgressHandler?,
    deadline: ContinuousClock.Instant?
  ) async throws -> [String: MCPJSONValue] {
    let exchange: MCPClientExchange
    do {
      exchange = try await openExchange(request, deadline: deadline)
    } catch is CancellationError {
      throw MCPClientError.cancelled
    } catch let error as MCPClientError {
      throw error
    } catch {
      throw clientTransportError(error)
    }

    do {
      guard let deadline else {
        return try await consumeRequestExchange(
          exchange,
          request: request,
          descriptor: descriptor,
          expectedProgressToken: expectedProgressToken,
          progress: progress
        )
      }
      return try await withThrowingTaskGroup(of: MCPRequestRaceResult.self) { group in
        group.addTask {
          .response(
            try await consumeRequestExchange(
              exchange,
              request: request,
              descriptor: descriptor,
              expectedProgressToken: expectedProgressToken,
              progress: progress
            ))
        }
        group.addTask {
          try await ContinuousClock().sleep(until: deadline)
          return .timedOut
        }
        guard let first = try await group.next() else {
          throw MCPClientError.protocolViolation("request timeout race produced no result")
        }
        group.cancelAll()
        switch first {
        case .response(let response):
          return response
        case .timedOut:
          try await cancelExchange(exchange, reason: "request timed out")
          throw MCPClientError.timeout
        }
      }
    } catch is CancellationError {
      try await cancelExchange(exchange, reason: "client task cancelled")
      throw MCPClientError.cancelled
    } catch let error as MCPClientError {
      switch error {
      case .rpc, .timeout, .cancelled, .peerCancelled, .transport, .transportFailure:
        throw error
      default:
        try await cancelExchange(exchange, reason: "request failed")
        throw error
      }
    } catch {
      try await cancelExchange(exchange, reason: "request failed")
      throw error
    }
  }

  private func clientTransportError(_ error: Error) -> MCPClientError {
    if let failure = error as? any MCPClientTransportFailure {
      return .transportFailure(failure)
    }
    return .transport(String(describing: error))
  }

  private func openExchange(
    _ request: MCPWireRequest,
    deadline: ContinuousClock.Instant?
  ) async throws -> MCPClientExchange {
    guard let deadline else { return try await transport.open(request) }
    let coordinator = MCPOpenRaceCoordinator()
    let openTask = Task { [transport] in
      do {
        let exchange = try await transport.open(request)
        if !(await coordinator.resolve(.opened(exchange))) {
          try? await exchange.cancel(reason: "transport opened after request deadline")
        }
      } catch {
        _ = await coordinator.resolve(.failed(error))
      }
    }
    let timeoutTask = Task {
      do {
        try await ContinuousClock().sleep(until: deadline)
        _ = await coordinator.resolve(.timedOut)
      } catch {
        // The open operation won or the caller cancelled the request.
      }
    }

    return try await withTaskCancellationHandler {
      let first = await coordinator.result()
      timeoutTask.cancel()
      if Task.isCancelled {
        openTask.cancel()
        if case .opened(let exchange) = first {
          try? await exchange.cancel(reason: "client task cancelled while opening transport")
        }
        throw CancellationError()
      }
      switch first {
      case .opened(let exchange):
        return exchange
      case .timedOut:
        openTask.cancel()
        throw MCPClientError.timeout
      case .failed(let error):
        throw error
      case .cancelled:
        throw CancellationError()
      }
    } onCancel: {
      openTask.cancel()
      timeoutTask.cancel()
      Task { _ = await coordinator.resolve(.cancelled) }
    }
  }

  private func consumeRequestExchange(
    _ exchange: MCPClientExchange,
    request: MCPWireRequest,
    descriptor: MCPMethodDescriptor,
    expectedProgressToken: MCPProgressToken?,
    progress: MCPProgressHandler?
  ) async throws -> [String: MCPJSONValue] {
    var frameCount = 0
    var terminal: Result<[String: MCPJSONValue], MCPRPCError>?
    var lastProgress: MCPJSONNumber?

    var iterator = exchange.frames.makeAsyncIterator()
    while true {
      let frame: MCPWireMessage
      do {
        guard let next = try await iterator.next() else { break }
        frame = next
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as MCPClientError {
        throw error
      } catch {
        throw clientTransportError(error)
      }
      try Task.checkCancellation()
      frameCount += 1
      guard frameCount <= configuration.maximumFramesPerRequest else {
        throw MCPClientError.protocolViolation(
          "request exceeded maximum frame count \(configuration.maximumFramesPerRequest)")
      }
      guard terminal == nil else {
        throw MCPClientError.protocolViolation("frame received after terminal response")
      }

      switch frame {
      case .notification(let notification):
        guard notification.method == "notifications/progress" else {
          throw MCPClientError.protocolViolation(
            "ordinary request received unexpected server notification \(notification.method)")
        }
        guard let expectedProgressToken, let progress else {
          throw MCPClientError.protocolViolation(
            "server sent progress for a request that did not request progress")
        }
        let value = try MCPProgressParams(json: .object(notification.params))
        guard value.progressToken == expectedProgressToken else {
          throw MCPClientError.protocolViolation("progress token does not match request metadata")
        }
        if let lastProgress, value.progress.compare(to: lastProgress) != .orderedDescending {
          throw MCPClientError.protocolViolation("server progress must strictly increase")
        }
        lastProgress = value.progress
        try await progress(value)

      case .result(let result):
        guard result.id == request.id else {
          throw MCPClientError.protocolViolation("terminal result id does not match request id")
        }
        try validateResultType(result.resultType, descriptor: descriptor)
        terminal = .success(result.value)

      case .error(let response):
        if let responseID = response.id, responseID != request.id {
          throw MCPClientError.protocolViolation("terminal error id does not match request id")
        }
        terminal = .failure(response.error)

      case .request:
        throw MCPClientError.protocolViolation(
          "MCP 2026-07-28 strict clients do not accept server-originated requests")
      }
    }

    try Task.checkCancellation()
    guard let terminal else {
      throw MCPClientError.protocolViolation("exchange ended without a terminal response")
    }
    switch terminal {
    case .success(let value): return value
    case .failure(let error): throw MCPClientError.rpc(error)
    }
  }

  private func awaitSubscriptionAcknowledgement(
    _ acknowledgements: AsyncThrowingStream<MCPSubscriptionFilter, Error>,
    deadline: ContinuousClock.Instant?
  ) async throws -> MCPSubscriptionFilter? {
    guard let deadline else {
      var iterator = acknowledgements.makeAsyncIterator()
      return try await iterator.next()
    }
    return try await withThrowingTaskGroup(of: MCPSubscriptionOpeningRaceResult.self) { group in
      group.addTask {
        var iterator = acknowledgements.makeAsyncIterator()
        return .acknowledged(try await iterator.next())
      }
      group.addTask {
        try await ContinuousClock().sleep(until: deadline)
        return .timedOut
      }
      guard let first = try await group.next() else {
        throw MCPClientError.protocolViolation(
          "subscription acknowledgement timeout race produced no result")
      }
      group.cancelAll()
      switch first {
      case .acknowledged(let value): return value
      case .timedOut: throw MCPClientError.timeout
      }
    }
  }

  private func consumeSubscriptionExchange(
    _ frames: AsyncThrowingStream<MCPWireMessage, Error>,
    requestID: MCPRequestID,
    requested: MCPSubscriptionFilter,
    exchange: MCPClientExchange,
    openingContinuation: AsyncThrowingStream<MCPSubscriptionFilter, Error>.Continuation,
    eventContinuation: AsyncThrowingStream<MCPClientSubscriptionEvent, Error>.Continuation,
    control: MCPClientSubscriptionControl
  ) async {
    var state = MCPSubscriptionState.opening(requested: requested)
    var accepted: MCPSubscriptionFilter?
    var terminal: MCPSubscriptionsListenResult?

    do {
      for try await frame in frames {
        try Task.checkCancellation()
        guard terminal == nil else {
          throw MCPClientError.protocolViolation(
            "subscription received a frame after terminal response")
        }

        if accepted == nil {
          switch frame {
          case .notification(let notification):
            guard notification.method == "notifications/subscriptions/acknowledged" else {
              throw MCPClientError.protocolViolation(
                "subscription first frame must be notifications/subscriptions/acknowledged")
            }
            let acknowledgement = try MCPSubscriptionsAcknowledgedParams(
              json: .object(notification.params)
            )
            guard acknowledgement.metadata.subscriptionID == requestID else {
              throw MCPClientError.protocolViolation(
                "subscription acknowledgement id does not match request id")
            }
            state = try MCPSubscriptionReducer.reduce(
              state: state,
              event: .acknowledge(acknowledgement.notifications)
            ).0
            state = try MCPSubscriptionReducer.reduce(
              state: state,
              event: .beginListening
            ).0
            accepted = acknowledgement.notifications
            await diagnostics.record(
              MCPDiagnosticEvent(
                id: "mcp.client.subscription.acknowledged",
                level: .info,
                fields: [
                  "requestID": requestID.description,
                  "endpoint": transport.endpointIdentity,
                ]
              ))
            try yieldSubscriptionEvent(
              .acknowledged(acknowledgement.notifications),
              continuation: eventContinuation
            )
            switch openingContinuation.yield(acknowledgement.notifications) {
            case .enqueued:
              openingContinuation.finish()
            case .dropped:
              throw MCPClientError.protocolViolation(
                "subscription acknowledgement handoff buffer overflow")
            case .terminated:
              throw CancellationError()
            @unknown default:
              throw MCPClientError.protocolViolation(
                "unknown subscription acknowledgement stream state")
            }

          case .error(let response):
            if let responseID = response.id, responseID != requestID {
              throw MCPClientError.protocolViolation(
                "subscription error id does not match request id")
            }
            throw MCPClientError.rpc(response.error)

          case .result:
            throw MCPClientError.protocolViolation(
              "subscription completed before acknowledgement")

          case .request:
            throw MCPClientError.protocolViolation(
              "MCP 2026-07-28 strict clients do not accept server-originated requests")
          }
          continue
        }

        guard let acceptedNotifications = accepted else {
          throw MCPClientError.protocolViolation(
            "subscription notification arrived before acknowledgement state was retained")
        }
        switch frame {
        case .notification(let notification):
          if notification.method == "notifications/cancelled" {
            _ = try registry.require(
              notification.method,
              direction: .serverToClientNotification
            )
            let cancellation = try MCPCancelledParams(json: .object(notification.params))
            guard cancellation.requestID == requestID else {
              throw MCPClientError.protocolViolation(
                "subscription cancellation id does not match request id")
            }
            state = try MCPSubscriptionReducer.reduce(
              state: state,
              event: .serverCancel(cancellation.reason)
            ).0
            await control.markTerminal()
            await diagnostics.record(
              MCPDiagnosticEvent(
                id: "mcp.client.subscription.server_cancelled",
                level: .info,
                fields: [
                  "requestID": requestID.description,
                  "endpoint": transport.endpointIdentity,
                  "reason": cancellation.reason ?? "unspecified",
                ]
              ))
            eventContinuation.finish(
              throwing: MCPClientError.peerCancelled(reason: cancellation.reason))
            return
          }
          try await validateSubscriptionNotification(
            notification,
            requestID: requestID,
            accepted: acceptedNotifications
          )
          state = try MCPSubscriptionReducer.reduce(
            state: state,
            event: .receiveNotification
          ).0
          try yieldSubscriptionEvent(
            .notification(notification),
            continuation: eventContinuation
          )

        case .result(let result):
          guard result.id == requestID else {
            throw MCPClientError.protocolViolation(
              "subscription terminal result id does not match request id")
          }
          guard result.resultType == .complete else {
            throw MCPClientError.protocolViolation(
              "subscriptions/listen must terminate with resultType complete")
          }
          let decoded = try MCPSubscriptionsListenResult(json: .object(result.value))
          guard decoded.subscriptionID == requestID else {
            throw MCPClientError.protocolViolation(
              "subscription terminal metadata id does not match request id")
          }
          state = try MCPSubscriptionReducer.reduce(
            state: state,
            event: .gracefulClose
          ).0
          terminal = decoded

        case .error(let response):
          if let responseID = response.id, responseID != requestID {
            throw MCPClientError.protocolViolation(
              "subscription terminal error id does not match request id")
          }
          throw MCPClientError.rpc(response.error)

        case .request:
          throw MCPClientError.protocolViolation(
            "MCP 2026-07-28 strict clients do not accept server-originated requests")
        }
      }

      try Task.checkCancellation()
      guard accepted != nil else {
        throw MCPClientError.transport(
          "subscription stream ended before acknowledgement")
      }
      guard let terminal else {
        if case .listening = state {
          _ = try MCPSubscriptionReducer.reduce(
            state: state,
            event: .disconnect("transport stream ended")
          )
        }
        throw MCPClientError.transport(
          "subscription stream ended without a terminal response")
      }
      try yieldSubscriptionEvent(.completed(terminal), continuation: eventContinuation)
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.client.subscription.completed",
          level: .info,
          fields: [
            "requestID": requestID.description,
            "endpoint": transport.endpointIdentity,
          ]
        ))
      await control.markTerminal()
      eventContinuation.finish()
    } catch is CancellationError {
      if accepted == nil {
        openingContinuation.finish(throwing: MCPClientError.cancelled)
      }
      await control.markTerminal()
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.client.subscription.cancelled",
          level: .info,
          fields: [
            "requestID": requestID.description,
            "endpoint": transport.endpointIdentity,
          ]
        ))
      eventContinuation.finish(throwing: MCPClientError.cancelled)
    } catch {
      if accepted == nil {
        openingContinuation.finish(throwing: error)
      }
      do {
        try await exchange.cancel(reason: "subscription failed")
      } catch let cancellationError {
        await control.markTerminal()
        eventContinuation.finish(
          throwing: MCPClientError.transport(
            "subscription failed with \(error); cancellation failed with \(cancellationError)"))
        return
      }
      await control.markTerminal()
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.client.subscription.failed",
          level: .error,
          fields: [
            "requestID": requestID.description,
            "endpoint": transport.endpointIdentity,
            "failure": String(reflecting: type(of: error)),
          ]
        ))
      eventContinuation.finish(throwing: error)
    }
  }

  private func validateSubscriptionNotification(
    _ notification: MCPWireNotification,
    requestID: MCPRequestID,
    accepted: MCPSubscriptionFilter
  ) async throws {
    guard notification.method != "notifications/subscriptions/acknowledged" else {
      throw MCPClientError.protocolViolation(
        "subscription acknowledgement may only be the first frame")
    }
    _ = try registry.require(
      notification.method,
      direction: .serverToClientNotification
    )
    let metadata = try MCPNotificationMetadata(
      json: notification.params["_meta"]
        ?? { throw MCPJSONError.missingField("_meta") }()
    )
    guard metadata.subscriptionID == requestID else {
      throw MCPClientError.protocolViolation(
        "subscription notification id does not match request id")
    }

    switch notification.method {
    case "notifications/tools/list_changed":
      guard accepted.toolsListChanged else {
        throw MCPClientError.protocolViolation(
          "server sent an unrequested tools/list_changed notification")
      }
      let token = await cacheEpochs.beginInvalidation(.tools)
      await toolCatalog.removeAll()
      await (transport as? any MCPClientToolCatalogInvalidatingTransport)?.invalidateToolCatalog()
      do {
        try await configuration.cache?.invalidate(.tools)
        await cacheEpochs.finishInvalidation(token, succeeded: true)
      } catch {
        await cacheEpochs.finishInvalidation(token, succeeded: false)
        throw error
      }
    case "notifications/prompts/list_changed":
      guard accepted.promptsListChanged else {
        throw MCPClientError.protocolViolation(
          "server sent an unrequested prompts/list_changed notification")
      }
      try await invalidateCache(.prompts)
    case "notifications/resources/list_changed":
      guard accepted.resourcesListChanged else {
        throw MCPClientError.protocolViolation(
          "server sent an unrequested resources/list_changed notification")
      }
      try await invalidateCache(.resources)
    case "notifications/resources/updated":
      let params = try MCPResourceUpdatedParams(json: .object(notification.params))
      guard accepted.resourceSubscriptions.contains(params.uri) else {
        throw MCPClientError.protocolViolation(
          "server sent an update for an unrequested resource")
      }
      try await invalidateCache(.resource(uri: params.uri))
    default:
      throw MCPClientError.protocolViolation(
        "notification \(notification.method) is not valid on subscriptions/listen")
    }
  }

  private func yieldSubscriptionEvent(
    _ event: MCPClientSubscriptionEvent,
    continuation: AsyncThrowingStream<MCPClientSubscriptionEvent, Error>.Continuation
  ) throws {
    switch continuation.yield(event) {
    case .enqueued:
      return
    case .dropped:
      throw MCPClientError.protocolViolation("subscription event buffer overflow")
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw MCPClientError.protocolViolation("unknown subscription event stream state")
    }
  }

  private func cancelExchange(_ exchange: MCPClientExchange, reason: String) async throws {
    do {
      try await exchange.cancel(reason: reason)
    } catch {
      throw MCPClientError.transport("request cancellation failed: \(error)")
    }
  }

  private func validateResultType(
    _ resultType: MCPResultType,
    descriptor: MCPMethodDescriptor
  ) throws {
    switch resultType {
    case .complete:
      return
    case .inputRequired:
      guard descriptor.allowsMRTR else {
        throw MCPClientError.protocolViolation(
          "\(descriptor.name) returned input_required but does not allow MRTR")
      }
    case .extensionValue(let value):
      guard descriptor.extensionResultTypes.contains(value) else {
        throw MCPClientError.protocolViolation(
          "\(descriptor.name) returned undeclared extension resultType \(value)")
      }
    }
  }

  private func cacheResourceURI(
    descriptor: MCPMethodDescriptor,
    params: [String: MCPJSONValue]
  ) -> String? {
    guard descriptor.cacheability == .resourceRead,
      case .string(let uri)? = params["uri"]
    else { return nil }
    return uri
  }

  private func cacheKeysIfEligible(
    descriptor: MCPMethodDescriptor,
    params: [String: MCPJSONValue],
    semanticMetadata: [String: MCPJSONValue]
  ) async throws -> [MCPCacheKey] {
    guard configuration.cache != nil, descriptor.cacheability != .none,
      params["inputResponses"] == nil, params["requestState"] == nil
    else { return [] }

    let parameters = try MCPJSONValue.object(params).encoded()
    let capabilities = try configuration.capabilities.json.encoded()
    let metadata = try MCPJSONValue.object(semanticMetadata).encoded()
    var keys: [MCPCacheKey] = []
    if let partition = configuration.cacheAuthorizationPartition {
      keys.append(
        MCPCacheKey(
          endpointIdentity: transport.endpointIdentity,
          method: descriptor.name,
          parameters: parameters,
          clientCapabilities: capabilities,
          semanticMetadata: metadata,
          authorizationPartition: partition,
          resourceURI: cacheResourceURI(descriptor: descriptor, params: params)
        ))
    }
    keys.append(
      MCPCacheKey(
        endpointIdentity: transport.endpointIdentity,
        method: descriptor.name,
        parameters: parameters,
        clientCapabilities: capabilities,
        semanticMetadata: metadata,
        authorizationPartition: nil,
        resourceURI: cacheResourceURI(descriptor: descriptor, params: params)
      ))
    return keys
  }

  private func storeInCacheIfEligible(
    _ result: [String: MCPJSONValue],
    descriptor: MCPMethodDescriptor,
    params: [String: MCPJSONValue],
    semanticMetadata: [String: MCPJSONValue],
    expectedEpoch: MCPClientCacheEpochToken
  ) async throws {
    guard let cache = configuration.cache, descriptor.cacheability != .none,
      params["inputResponses"] == nil, params["requestState"] == nil,
      result["resultType"] == .string("complete"),
      let policy = try mcpCachePolicy(from: result),
      policy.ttlMilliseconds > 0
    else { return }

    let partition: String?
    switch policy.scope {
    case .public:
      partition = nil
    case .private:
      guard let value = configuration.cacheAuthorizationPartition else {
        await diagnostics.record(
          MCPDiagnosticEvent(
            id: "mcp.client.cache.private.skipped",
            level: .warning,
            fields: ["method": descriptor.name, "endpoint": transport.endpointIdentity]
          ))
        return
      }
      partition = value
    }

    let parameters = try MCPJSONValue.object(params).encoded()
    let capabilities = try configuration.capabilities.json.encoded()
    let metadata = try MCPJSONValue.object(semanticMetadata).encoded()
    let key = MCPCacheKey(
      endpointIdentity: transport.endpointIdentity,
      method: descriptor.name,
      parameters: parameters,
      clientCapabilities: capabilities,
      semanticMetadata: metadata,
      authorizationPartition: partition,
      resourceURI: cacheResourceURI(descriptor: descriptor, params: params)
    )
    let expiresAt = Date().addingTimeInterval(Double(policy.ttlMilliseconds) / 1_000)
    guard let writeLease = await cacheEpochs.beginWrite(expectedEpoch: expectedEpoch) else {
      return
    }
    do {
      try await cache.insert(
        MCPCacheEntry(value: result, scope: policy.scope, expiresAt: expiresAt),
        for: key
      )
    } catch {
      await cacheEpochs.failWrite(writeLease)
      throw error
    }
    if !(await cacheEpochs.isCurrent(expectedEpoch)) {
      let invalidation = cacheInvalidation(descriptor: descriptor, params: params)
      let cleanupToken = await cacheEpochs.beginInvalidation(invalidation)
      do {
        try await cache.invalidate(invalidation)
        await cacheEpochs.finishInvalidation(cleanupToken, succeeded: true)
      } catch {
        await cacheEpochs.finishInvalidation(cleanupToken, succeeded: false)
        await cacheEpochs.finishWrite(writeLease)
        throw error
      }
    }
    await cacheEpochs.finishWrite(writeLease)
  }

  private func cacheInvalidation(
    descriptor: MCPMethodDescriptor,
    params: [String: MCPJSONValue]
  ) -> MCPCacheInvalidation {
    switch descriptor.name {
    case "tools/list": return .tools
    case "prompts/list": return .prompts
    case "resources/list", "resources/templates/list": return .resources
    case "resources/read":
      if case .string(let uri)? = params["uri"] { return .resource(uri: uri) }
      return .endpoint(transport.endpointIdentity)
    default:
      return .endpoint(transport.endpointIdentity)
    }
  }

  private func mergedMetadataExtensions(
    _ perRequest: [String: MCPJSONValue]
  ) throws -> [String: MCPJSONValue] {
    let collisions = Set(configuration.metadataExtensions.keys).intersection(perRequest.keys)
    guard collisions.isEmpty else {
      throw MCPJSONError.invalidField(
        field: "_meta",
        reason: "per-request metadata collides with configured keys: \(collisions.sorted())"
      )
    }
    return configuration.metadataExtensions.merging(perRequest) { _, request in request }
  }

}

/// Real in-process request binding used for embedding and deterministic integration tests.
/// It preserves request-scoped semantics and does not simulate network transport behavior.
public struct MCPInMemoryClientTransport: MCPClientTransport {
  public let endpointIdentity: String
  private let server: MCPServer
  private let authorization: MCPAuthorizationContext

  public init(
    server: MCPServer,
    endpointIdentity: String = "in-process",
    authorization: MCPAuthorizationContext = MCPAuthorizationContext()
  ) {
    self.server = server
    self.endpointIdentity = endpointIdentity
    self.authorization = authorization
  }

  public func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    let exchange = server.execute(request, authorization: authorization)
    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(4_096)
    )
    let pump = Task {
      do {
        for try await frame in exchange.frames {
          try Self.yield(frame, into: pair.continuation)
        }
        pair.continuation.finish()
      } catch let cancellation as MCPServerSubscriptionCancellation {
        do {
          guard request.method == MCPStandardMethods.listen.descriptor.name,
            cancellation.requestID == request.id
          else {
            throw cancellation
          }
          let params = MCPCancelledParams(
            requestID: cancellation.requestID,
            reason: cancellation.reason
          )
          let notification = try MCPWireNotification(
            method: "notifications/cancelled",
            params: params.json.objectValue ?? [:]
          )
          try Self.yield(.notification(notification), into: pair.continuation)
          pair.continuation.finish()
        } catch {
          pair.continuation.finish(throwing: error)
        }
      } catch {
        pair.continuation.finish(throwing: error)
      }
    }
    pair.continuation.onTermination = { @Sendable termination in
      guard case .cancelled = termination else { return }
      pump.cancel()
      Task { await exchange.cancel(reason: "in-memory response stream cancelled") }
    }
    return MCPClientExchange(
      frames: pair.stream,
      cancel: { reason in
        pump.cancel()
        await exchange.cancel(reason: reason)
      }
    )
  }

  private static func yield(
    _ frame: MCPWireMessage,
    into continuation: AsyncThrowingStream<MCPWireMessage, Error>.Continuation
  ) throws {
    switch continuation.yield(frame) {
    case .enqueued:
      return
    case .dropped:
      throw MCPClientError.transport("in-memory response buffer overflow")
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw MCPClientError.transport("unknown in-memory response buffer state")
    }
  }
}
