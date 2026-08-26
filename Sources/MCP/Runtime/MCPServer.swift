import Foundation

public struct MCPServerConfiguration: Sendable {
  public var schemaValidator: any MCPJSONSchemaValidating
  public var maximumMetadataBytes: Int
  public var subscriptionBufferLimit: Int
  public var includeServerInfo: Bool
  public var discoveryCache: MCPCachePolicy
  public var maximumToolSchemaCacheEntries: Int

  public init(
    schemaValidator: any MCPJSONSchemaValidating = MCPJSONSchemaValidator(),
    maximumMetadataBytes: Int = 64 * 1_024,
    subscriptionBufferLimit: Int = 128,
    includeServerInfo: Bool = true,
    discoveryCache: MCPCachePolicy = .defaultDiscovery,
    maximumToolSchemaCacheEntries: Int = 256
  ) {
    self.schemaValidator = schemaValidator
    self.maximumMetadataBytes = maximumMetadataBytes
    self.subscriptionBufferLimit = subscriptionBufferLimit
    self.includeServerInfo = includeServerInfo
    self.discoveryCache = discoveryCache
    self.maximumToolSchemaCacheEntries = maximumToolSchemaCacheEntries
  }
}

public typealias MCPToolResolver =
  @Sendable (_ name: String, _ context: MCPRequestContext) async throws -> MCPTool?

public enum MCPServerBuildError: Error, Sendable, Equatable, CustomStringConvertible {
  case duplicateHandler(String)
  case incompleteFeature(String)
  case invalidHandlerDirection(String)
  case invalidConfiguration(String)
  /// Official extension descriptors and capabilities must be installed by their owning product's
  /// validated package registration, never through the raw public server builder.
  case untrustedOfficialExtension(String)

  public var description: String {
    switch self {
    case .duplicateHandler(let method): "Duplicate handler for \(method)"
    case .incompleteFeature(let feature): "Incomplete feature registration: \(feature)"
    case .invalidHandlerDirection(let method):
      "Handler method is not a client-to-server request: \(method)"
    case .invalidConfiguration(let reason):
      "Invalid server configuration: \(reason)"
    case .untrustedOfficialExtension(let identifier):
      "Official MCP extension \(identifier) requires validated package registration"
    }
  }
}

private struct MCPAnyRequestHandler: Sendable {
  let descriptor: MCPMethodDescriptor
  let invoke:
    @Sendable ([String: MCPJSONValue], MCPRequestContext) async throws -> [String: MCPJSONValue]
}

private struct MCPInvalidRequestParameters: Error, Sendable {
  let reason: String
}

private struct MCPServerHandlerFailure: Error, Sendable {}

private struct MCPInvalidServerResult: Error, Sendable {}

private struct MCPCompiledServerTool: Sendable {
  let definition: MCPTool
  let inputPlan: any MCPJSONSchemaValidationPlan
  let outputPlan: (any MCPJSONSchemaValidationPlan)?

  init(tool: MCPTool, validator: any MCPJSONSchemaValidating) throws {
    definition = tool
    inputPlan = try validator.compile(.object(tool.inputSchema))
    outputPlan = try tool.outputSchema.map { try validator.compile(.object($0)) }
  }
}

/// Reuses compiled tool schemas across requests, keeping recency in each entry rather than in a
/// separate ordering array.
///
/// `MCPTool` equality walks its whole schema, so a hit must not scan an ordering list: that would
/// cost one deep comparison per retained tool on every `tools/call`. Recency lives beside the plan
/// and only eviction inspects it, matching `MCPMemoryCache`.
private actor MCPServerToolPlanCache {
  private struct Entry {
    var plan: MCPCompiledServerTool
    var accessOrder: UInt64
  }

  private let validator: any MCPJSONSchemaValidating
  private let maximumEntries: Int
  private var entries: [MCPTool: Entry] = [:]
  private var accessOrder: UInt64 = 0

  init(validator: any MCPJSONSchemaValidating, maximumEntries: Int) {
    self.validator = validator
    self.maximumEntries = maximumEntries
  }

  func compiledTool(for tool: MCPTool) throws -> MCPCompiledServerTool {
    if var existing = entries[tool] {
      existing.accessOrder = nextAccessOrder()
      entries[tool] = existing
      return existing.plan
    }
    let plan = try MCPCompiledServerTool(tool: tool, validator: validator)
    if entries.count >= maximumEntries,
      let evicted = entries.min(by: { $0.value.accessOrder < $1.value.accessOrder })?.key
    {
      entries.removeValue(forKey: evicted)
    }
    entries[tool] = Entry(plan: plan, accessOrder: nextAccessOrder())
    return plan
  }

  private func nextAccessOrder() -> UInt64 {
    accessOrder &+= 1
    return accessOrder
  }
}

public struct MCPServerBuilder: Sendable {
  public let implementation: MCPImplementation
  public var instructions: String?
  public var configuration: MCPServerConfiguration
  private var extensionValues: [String: MCPJSONValue]
  private var trustedOfficialCapabilities: [String: MCPJSONValue]
  private var trustedOfficialMethodNames: [String: Set<String>]
  private var rejectedOfficialCapabilityMutation: String?

  /// The capabilities currently configured on this builder. Official extension capabilities are
  /// reserved for the owning product's validated registration and cannot be introduced by this
  /// public mutation surface.
  public var extensions: [String: MCPJSONValue] {
    get { extensionValues }
    set {
      let rejectedIdentifier = newValue.keys.sorted().first {
        MCPMethodRegistry.isOfficialExtensionIdentifier($0)
          && trustedOfficialCapabilities[$0] == nil
      }
      if let rejectedIdentifier, rejectedOfficialCapabilityMutation == nil {
        rejectedOfficialCapabilityMutation = rejectedIdentifier
      }

      var values = newValue
      if let rejectedIdentifier {
        values.removeValue(forKey: rejectedIdentifier)
      }
      for (identifier, capability) in trustedOfficialCapabilities {
        values[identifier] = capability
      }
      extensionValues = values
    }
  }

  private var registry: MCPMethodRegistry
  private var handlers: [String: MCPAnyRequestHandler]
  private var toolListChanged: Bool
  private var promptListChanged: Bool
  private var resourceListChanged: Bool
  private var resourceSubscriptions: Bool
  private var toolResolver: MCPToolResolver?

  public init(
    implementation: MCPImplementation,
    instructions: String? = nil,
    configuration: MCPServerConfiguration = MCPServerConfiguration(),
    extensionMethods: [MCPMethodDescriptor] = [],
    extensions: [String: MCPJSONValue] = [:]
  ) throws {
    let officialDescriptor =
      extensionMethods
      .sorted(by: { $0.name < $1.name })
      .first(where: MCPMethodRegistry.isOfficialExtensionDescriptor)
    if let descriptor = officialDescriptor {
      throw MCPServerBuildError.untrustedOfficialExtension(
        descriptor.extensionIdentifier ?? descriptor.name)
    }
    let officialCapabilityIdentifier = extensions.keys.sorted().first(
      where: MCPMethodRegistry.isOfficialExtensionIdentifier)
    if let identifier = officialCapabilityIdentifier {
      throw MCPServerBuildError.untrustedOfficialExtension(identifier)
    }
    self.implementation = implementation
    self.instructions = instructions
    self.configuration = configuration
    self.extensionValues = extensions
    self.trustedOfficialCapabilities = [:]
    self.trustedOfficialMethodNames = [:]
    self.rejectedOfficialCapabilityMutation = nil
    self.registry = try MCPMethodRegistry(extensionMethods: extensionMethods)
    self.handlers = [:]
    self.toolListChanged = false
    self.promptListChanged = false
    self.resourceListChanged = false
    self.resourceSubscriptions = false
    self.toolResolver = nil
    _ = try MCPServerCapabilities(extensions: extensions)
  }

  /// Installs an official extension atomically with its validated descriptors and capability.
  /// This initializer is package-scoped so only a product in this Swift package that has created
  /// a `MCPOfficialExtensionRegistration` can own the official namespace.
  package init(
    implementation: MCPImplementation,
    instructions: String? = nil,
    configuration: MCPServerConfiguration = MCPServerConfiguration(),
    officialExtension: MCPOfficialExtensionRegistration,
    extensions: [String: MCPJSONValue] = [:]
  ) throws {
    let officialCapabilityIdentifier = extensions.keys.sorted().first(
      where: MCPMethodRegistry.isOfficialExtensionIdentifier)
    if let identifier = officialCapabilityIdentifier {
      throw MCPServerBuildError.untrustedOfficialExtension(identifier)
    }
    var installedExtensions = extensions
    installedExtensions[officialExtension.identifier] = officialExtension.capability

    self.implementation = implementation
    self.instructions = instructions
    self.configuration = configuration
    self.extensionValues = installedExtensions
    self.trustedOfficialCapabilities = [
      officialExtension.identifier: officialExtension.capability
    ]
    self.trustedOfficialMethodNames = [
      officialExtension.identifier: Set(officialExtension.methods.map(\.name))
    ]
    self.rejectedOfficialCapabilityMutation = nil
    self.registry = try MCPMethodRegistry(extensionMethods: officialExtension.methods)
    self.handlers = [:]
    self.toolListChanged = false
    self.promptListChanged = false
    self.resourceListChanged = false
    self.resourceSubscriptions = false
    self.toolResolver = nil
    _ = try MCPServerCapabilities(extensions: installedExtensions)
  }

  public mutating func register<Params: MCPJSONModel, Result: MCPJSONModel>(
    _ method: MCPMethod<Params, Result>,
    handler: @escaping @Sendable (Params, MCPRequestContext) async throws -> Result
  ) throws {
    let descriptor = method.descriptor
    try validateOfficialDescriptorOwnership(descriptor)
    guard descriptor.direction == .clientToServerRequest else {
      throw MCPServerBuildError.invalidHandlerDirection(descriptor.name)
    }
    guard handlers[descriptor.name] == nil else {
      throw MCPServerBuildError.duplicateHandler(descriptor.name)
    }
    handlers[descriptor.name] = MCPAnyRequestHandler(
      descriptor: descriptor,
      invoke: { rawParams, context in
        let params: Params
        do {
          params = try method.decodeParams(.object(rawParams))
        } catch {
          throw MCPInvalidRequestParameters(reason: String(describing: error))
        }
        let result: Result
        do {
          result = try await handler(params, context)
        } catch let error as MCPRPCError {
          throw error
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw MCPServerHandlerFailure()
        }
        guard case .object(let object) = method.encodeResult(result) else {
          throw MCPClientError.protocolViolation(
            "handler result for \(descriptor.name) must encode as an object")
        }
        return object
      })
  }

  public mutating func registerOutcome<Params: MCPJSONModel, Result: MCPJSONModel>(
    _ method: MCPMethod<Params, Result>,
    handler:
      @escaping @Sendable (Params, MCPRequestContext) async throws -> MCPOperationOutcome<Result>
  ) throws {
    try register(method) { params, context in
      let outcome = try await handler(params, context)
      let result: Result
      let expected: MCPResultType
      switch outcome {
      case .complete(let value):
        result = value
        expected = .complete
      case .inputRequired(let value):
        result = value
        expected = .inputRequired
      }
      guard case .object(let object) = result.json,
        case .string(let rawType)? = object["resultType"],
        try MCPResultType(rawValue: rawType) == expected
      else {
        throw MCPClientError.protocolViolation(
          "operation outcome does not match encoded resultType for \(method.descriptor.name)")
      }
      return result
    }
  }

  /// Installs the request-local authority used to resolve and validate tool calls.
  ///
  /// The resolver may vary tools by authorization or request metadata. A tools server cannot be
  /// built without this boundary because advertising a schema without enforcing it is invalid.
  public mutating func setToolResolver(_ resolver: @escaping MCPToolResolver) {
    toolResolver = resolver
  }

  public mutating func enableToolListChanged(_ enabled: Bool = true) {
    toolListChanged = enabled
  }

  public mutating func enablePromptListChanged(_ enabled: Bool = true) {
    promptListChanged = enabled
  }

  public mutating func enableResourceListChanged(_ enabled: Bool = true) {
    resourceListChanged = enabled
  }

  public mutating func enableResourceSubscriptions(_ enabled: Bool = true) {
    resourceSubscriptions = enabled
  }

  public func build(diagnostics: any MCPDiagnosticSink = MCPNoopDiagnosticSink()) throws
    -> MCPServer
  {
    try validateOfficialCapabilityState()
    try validateConfiguration()
    try validateFeatureCompleteness()
    let capabilities = try deriveCapabilities()
    return MCPServer(
      implementation: implementation,
      instructions: instructions,
      configuration: configuration,
      registry: registry,
      handlers: handlers,
      toolResolver: toolResolver,
      capabilities: capabilities,
      diagnostics: diagnostics
    )
  }

  private func validateOfficialCapabilityState() throws {
    if let identifier = rejectedOfficialCapabilityMutation {
      throw MCPServerBuildError.untrustedOfficialExtension(identifier)
    }
    for (identifier, capability) in trustedOfficialCapabilities {
      guard extensionValues[identifier] == capability else {
        throw MCPServerBuildError.untrustedOfficialExtension(identifier)
      }
    }
  }

  private func validateOfficialDescriptorOwnership(_ descriptor: MCPMethodDescriptor) throws {
    guard MCPMethodRegistry.isOfficialExtensionDescriptor(descriptor) else { return }
    guard let identifier = descriptor.extensionIdentifier,
      trustedOfficialMethodNames[identifier]?.contains(descriptor.name) == true
    else {
      throw MCPServerBuildError.untrustedOfficialExtension(
        descriptor.extensionIdentifier ?? descriptor.name)
    }
  }

  private func validateConfiguration() throws {
    guard configuration.maximumMetadataBytes > 0 else {
      throw MCPServerBuildError.invalidConfiguration(
        "maximumMetadataBytes must be greater than zero")
    }
    guard configuration.subscriptionBufferLimit > 0 else {
      throw MCPServerBuildError.invalidConfiguration(
        "subscriptionBufferLimit must be greater than zero")
    }
    guard configuration.maximumToolSchemaCacheEntries > 0 else {
      throw MCPServerBuildError.invalidConfiguration(
        "maximumToolSchemaCacheEntries must be greater than zero")
    }
  }

  private func validateFeatureCompleteness() throws {
    let methods = Set(handlers.keys)
    let toolMethods: Set<String> = ["tools/list", "tools/call"]
    if !methods.isDisjoint(with: toolMethods), !toolMethods.isSubset(of: methods) {
      throw MCPServerBuildError.incompleteFeature("tools requires tools/list and tools/call")
    }
    if toolMethods.isSubset(of: methods), toolResolver == nil {
      throw MCPServerBuildError.incompleteFeature(
        "tools requires a request-local resolver for schema validation")
    }
    let promptMethods: Set<String> = ["prompts/list", "prompts/get"]
    if !methods.isDisjoint(with: promptMethods), !promptMethods.isSubset(of: methods) {
      throw MCPServerBuildError.incompleteFeature("prompts requires prompts/list and prompts/get")
    }
    let resourceRequired: Set<String> = ["resources/list", "resources/read"]
    let resourceMethods: Set<String> = resourceRequired.union(["resources/templates/list"])
    if !methods.isDisjoint(with: resourceMethods), !resourceRequired.isSubset(of: methods) {
      throw MCPServerBuildError.incompleteFeature(
        "resources requires resources/list and resources/read")
    }
    if toolListChanged, !toolMethods.isSubset(of: methods) {
      throw MCPServerBuildError.incompleteFeature("tool list notifications require tools")
    }
    if promptListChanged, !promptMethods.isSubset(of: methods) {
      throw MCPServerBuildError.incompleteFeature("prompt list notifications require prompts")
    }
    if resourceListChanged || resourceSubscriptions, !resourceRequired.isSubset(of: methods) {
      throw MCPServerBuildError.incompleteFeature("resource notifications require resources")
    }
  }

  private func deriveCapabilities() throws -> MCPServerCapabilities {
    let methods = Set(handlers.keys)
    return try MCPServerCapabilities(
      tools: methods.contains("tools/list") && methods.contains("tools/call"),
      toolListChanged: toolListChanged,
      prompts: methods.contains("prompts/list") && methods.contains("prompts/get"),
      promptListChanged: promptListChanged,
      resources: methods.contains("resources/list") && methods.contains("resources/read"),
      resourceListChanged: resourceListChanged,
      resourceSubscriptions: resourceSubscriptions,
      completions: methods.contains("completion/complete"),
      extensions: extensionValues
    )
  }
}

public struct MCPServerExchange: Sendable {
  public let frames: AsyncThrowingStream<MCPWireMessage, Error>
  private let cancelValue: @Sendable (String?) async -> Void
  private let cancelSubscriptionValue: @Sendable (String?) async -> Void

  init(
    frames: AsyncThrowingStream<MCPWireMessage, Error>,
    cancel: @escaping @Sendable (String?) async -> Void,
    cancelSubscription: @escaping @Sendable (String?) async -> Void
  ) {
    self.frames = frames
    self.cancelValue = cancel
    self.cancelSubscriptionValue = cancelSubscription
  }

  /// Cancels exactly this server-side `subscriptions/listen` exchange as a server action.
  ///
  /// For a subscription, transports map this action to the protocol's
  /// `notifications/cancelled` notification. This is intentionally separate from `cancel`,
  /// which represents a transport/client disconnect and must not claim a peer cancellation.
  /// Calling this on a non-subscription exchange has no effect.
  public func cancelSubscription(reason: String? = nil) async {
    await cancelSubscriptionValue(reason)
  }

  /// Cancels execution because the exchange/transport is no longer being consumed.
  ///
  /// This does not produce a server-initiated subscription cancellation notification.
  public func cancel(reason: String? = nil) async {
    await cancelValue(reason)
  }
}

public struct MCPServerSubscriptionCancellation: Error, Sendable, Equatable,
  CustomStringConvertible
{
  public let requestID: MCPRequestID
  public let reason: String?

  public init(requestID: MCPRequestID, reason: String? = nil) {
    self.requestID = requestID
    self.reason = reason
  }

  public var description: String {
    if let reason, !reason.isEmpty {
      return "Server cancelled subscription \(requestID): \(reason)"
    }
    return "Server cancelled subscription \(requestID)"
  }
}

private actor MCPExecutionControl {
  private var task: Task<Void, Never>?
  private var cancellationReason: String?
  private var subscriptionHub: MCPSubscriptionHub?
  private var subscriptionHandle: MCPSubscriptionHubHandle?
  private var subscriptionCancellationRequested = false
  private var pendingSubscriptionCancellationReason: String?

  func install(_ task: Task<Void, Never>) {
    self.task = task
    if cancellationReason != nil { task.cancel() }
  }

  func cancel(reason: String?) {
    cancellationReason = reason
    task?.cancel()
  }

  func installSubscription(
    handle: MCPSubscriptionHubHandle,
    hub: MCPSubscriptionHub
  ) async {
    subscriptionHub = hub
    subscriptionHandle = handle
    guard subscriptionCancellationRequested else { return }
    subscriptionCancellationRequested = false
    let reason = pendingSubscriptionCancellationReason
    pendingSubscriptionCancellationReason = nil
    await hub.cancel(handle: handle, reason: reason)
  }

  func cancelSubscription(reason: String?) async {
    guard let subscriptionHub, let subscriptionHandle else {
      subscriptionCancellationRequested = true
      pendingSubscriptionCancellationReason = reason
      return
    }
    await subscriptionHub.cancel(handle: subscriptionHandle, reason: reason)
  }

  func reason() -> String? { cancellationReason }
}

private actor MCPProgressGate {
  private let token: MCPProgressToken
  private let continuation: AsyncThrowingStream<MCPWireMessage, Error>.Continuation
  private var lastProgress: MCPJSONNumber?
  private var terminal = false

  init(
    token: MCPProgressToken,
    continuation: AsyncThrowingStream<MCPWireMessage, Error>.Continuation
  ) {
    self.token = token
    self.continuation = continuation
  }

  func emit(progress: MCPJSONNumber, total: MCPJSONNumber?, message: String?) throws {
    guard !terminal else {
      throw MCPClientError.protocolViolation("progress emitted after terminal response")
    }
    if let lastProgress, progress.compare(to: lastProgress) != .orderedDescending {
      throw MCPClientError.protocolViolation("progress must strictly increase")
    }
    lastProgress = progress
    let params = try MCPProgressParams(
      progressToken: token,
      progress: progress,
      total: total,
      message: message
    )
    let notification = try MCPWireNotification(
      method: "notifications/progress", params: params.json.objectValue ?? [:])
    switch continuation.yield(.notification(notification)) {
    case .enqueued:
      return
    case .dropped:
      return
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw MCPClientError.protocolViolation("unknown progress buffer state")
    }
  }

  func finish() { terminal = true }
}

public enum MCPServerExecutionError: Error, Sendable, Equatable, CustomStringConvertible {
  case preparedRequestOwnerMismatch

  public var description: String {
    switch self {
    case .preparedRequestOwnerMismatch:
      "Prepared request belongs to a different MCPServer instance"
    }
  }
}

public struct MCPPreparedServerRequest: Sendable {
  fileprivate let request: MCPWireRequest
  fileprivate let authorization: MCPAuthorizationContext
  public let descriptor: MCPMethodDescriptor
  fileprivate let metadata: MCPRequestMetadata
  fileprivate let compiledTool: MCPCompiledServerTool?
  fileprivate let ownerID: UUID

  public var resolvedTool: MCPTool? { compiledTool?.definition }

  fileprivate init(
    request: MCPWireRequest,
    authorization: MCPAuthorizationContext,
    descriptor: MCPMethodDescriptor,
    metadata: MCPRequestMetadata,
    compiledTool: MCPCompiledServerTool?,
    ownerID: UUID
  ) {
    self.request = request
    self.authorization = authorization
    self.descriptor = descriptor
    self.metadata = metadata
    self.compiledTool = compiledTool
    self.ownerID = ownerID
  }
}

public struct MCPServer: Sendable {
  public let implementation: MCPImplementation
  public let instructions: String?
  public let configuration: MCPServerConfiguration
  public let registry: MCPMethodRegistry
  public let capabilities: MCPServerCapabilities

  private let handlers: [String: MCPAnyRequestHandler]
  private let toolResolver: MCPToolResolver?
  private let subscriptions: MCPSubscriptionHub
  private let toolPlanCache: MCPServerToolPlanCache
  private let diagnostics: any MCPDiagnosticSink
  private let ownerID: UUID

  fileprivate init(
    implementation: MCPImplementation,
    instructions: String?,
    configuration: MCPServerConfiguration,
    registry: MCPMethodRegistry,
    handlers: [String: MCPAnyRequestHandler],
    toolResolver: MCPToolResolver?,
    capabilities: MCPServerCapabilities,
    diagnostics: any MCPDiagnosticSink
  ) {
    self.implementation = implementation
    self.instructions = instructions
    self.configuration = configuration
    self.registry = registry
    self.handlers = handlers
    self.toolResolver = toolResolver
    self.capabilities = capabilities
    self.subscriptions = MCPSubscriptionHub(bufferLimit: configuration.subscriptionBufferLimit)
    self.toolPlanCache = MCPServerToolPlanCache(
      validator: configuration.schemaValidator,
      maximumEntries: configuration.maximumToolSchemaCacheEntries
    )
    self.diagnostics = diagnostics
    self.ownerID = UUID()
  }

  /// Resolves all request-local protocol authority that a transport may need before execution.
  /// The resulting value is immutable and can be passed directly to `execute(_:)`, preventing a
  /// transport and the runtime from resolving a dynamic tool definition twice.
  public func prepare(
    _ request: MCPWireRequest,
    authorization: MCPAuthorizationContext = MCPAuthorizationContext()
  ) async throws -> MCPPreparedServerRequest {
    let descriptor = try registry.require(request.method)
    let metadata = try MCPRequestMetadata.extract(from: request.params)
    try metadata.validateEncodedSize(maximumBytes: configuration.maximumMetadataBytes)
    try validateClientCapability(descriptor.requiredClientCapability, metadata: metadata)
    let context = MCPRequestContext(
      id: request.id,
      method: descriptor,
      metadata: metadata,
      authorization: authorization,
      progress: nil
    )
    let compiledTool = try await resolveAndValidateToolCall(request: request, context: context)
    return MCPPreparedServerRequest(
      request: request,
      authorization: authorization,
      descriptor: descriptor,
      metadata: metadata,
      compiledTool: compiledTool,
      ownerID: ownerID
    )
  }

  public func execute(
    _ request: MCPWireRequest,
    authorization: MCPAuthorizationContext = MCPAuthorizationContext()
  ) -> MCPServerExchange {
    makeExchange(request: request, authorization: authorization, prepared: nil)
  }

  public func execute(_ prepared: MCPPreparedServerRequest) throws -> MCPServerExchange {
    guard prepared.ownerID == ownerID else {
      throw MCPServerExecutionError.preparedRequestOwnerMismatch
    }
    return makeExchange(
      request: prepared.request,
      authorization: prepared.authorization,
      prepared: prepared
    )
  }

  private func makeExchange(
    request: MCPWireRequest,
    authorization: MCPAuthorizationContext,
    prepared: MCPPreparedServerRequest?
  ) -> MCPServerExchange {
    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(configuration.subscriptionBufferLimit))
    let control = MCPExecutionControl()
    let task = Task {
      await run(
        request,
        authorization: authorization,
        prepared: prepared,
        continuation: pair.continuation,
        control: control
      )
    }
    Task { await control.install(task) }
    let cancelSubscription: @Sendable (String?) async -> Void
    if request.method == "subscriptions/listen" {
      cancelSubscription = { reason in await control.cancelSubscription(reason: reason) }
    } else {
      cancelSubscription = { _ in }
    }
    return MCPServerExchange(
      frames: pair.stream,
      cancel: { reason in await control.cancel(reason: reason) },
      cancelSubscription: cancelSubscription
    )
  }

  public func notifyToolsChanged() async throws {
    try await subscriptions.publish(method: "notifications/tools/list_changed", params: [:])
  }

  public func notifyPromptsChanged() async throws {
    try await subscriptions.publish(method: "notifications/prompts/list_changed", params: [:])
  }

  public func notifyResourcesChanged() async throws {
    try await subscriptions.publish(method: "notifications/resources/list_changed", params: [:])
  }

  public func notifyResourceUpdated(uri: String) async throws {
    let params = try MCPResourceUpdatedParams(uri: uri)
    try await subscriptions.publish(
      method: "notifications/resources/updated", params: params.json.objectValue ?? [:])
  }

  public func closeAllSubscriptions() async {
    await subscriptions.closeAll()
  }

  public func cancelAllSubscriptions(reason: String? = nil) async {
    await subscriptions.cancelAll(reason: reason)
  }

  private func run(
    _ request: MCPWireRequest,
    authorization: MCPAuthorizationContext,
    prepared: MCPPreparedServerRequest?,
    continuation: AsyncThrowingStream<MCPWireMessage, Error>.Continuation,
    control: MCPExecutionControl
  ) async {
    let started = ContinuousClock.now
    do {
      let authority =
        if let prepared {
          prepared
        } else {
          try await prepare(request, authorization: authorization)
        }
      let descriptor = authority.descriptor
      let metadata = authority.metadata
      let progressGate: MCPProgressGate?
      let reporter: MCPProgressReporter?
      if let token = metadata.progressToken {
        let gate = MCPProgressGate(token: token, continuation: continuation)
        progressGate = gate
        reporter = MCPProgressReporter { progress, total, message in
          try await gate.emit(progress: progress, total: total, message: message)
        }
      } else {
        progressGate = nil
        reporter = nil
      }
      let context = MCPRequestContext(
        id: request.id,
        method: descriptor,
        metadata: metadata,
        authorization: authorization,
        progress: reporter
      )

      if request.method == "server/discover" {
        let result = try MCPDiscoverResult(
          capabilities: capabilities,
          instructions: instructions,
          cache: configuration.discoveryCache,
          metadata: try resultMetadata()
        )
        try yieldResult(result.json, id: request.id, continuation: continuation)
      } else if request.method == "subscriptions/listen" {
        try await runSubscription(
          request: request,
          continuation: continuation,
          control: control
        )
      } else {
        guard let handler = handlers[request.method] else {
          throw MCPRPCError.methodNotFound
        }
        let resolvedTool = authority.compiledTool
        var rawResult = try await handler.invoke(request.params, context)
        do {
          try await validateToolResult(
            rawResult,
            method: request.method,
            resolvedTool: resolvedTool
          )
          rawResult = try enrichAndValidateResult(
            rawResult,
            descriptor: descriptor,
            requestMetadata: metadata
          )
          try yieldResult(.object(rawResult), id: request.id, continuation: continuation)
        } catch let error as MCPRPCError {
          throw error
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw MCPInvalidServerResult()
        }
      }
      await progressGate?.finish()
      continuation.finish()
      let duration = ContinuousClock.now - started
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.request.completed",
          level: .info,
          fields: [
            "method": request.method,
            "requestID": request.id.description,
            "duration": String(describing: duration),
          ]
        ))
    } catch let cancellation as MCPServerSubscriptionCancellation {
      continuation.finish(throwing: cancellation)
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.subscription.server_cancelled",
          level: .info,
          fields: [
            "method": request.method,
            "requestID": request.id.description,
            "reason": cancellation.reason ?? "unspecified",
          ]
        ))
    } catch is CancellationError {
      let reason = await control.reason()
      continuation.finish()
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.request.cancelled",
          level: .info,
          fields: [
            "method": request.method,
            "requestID": request.id.description,
            "reason": reason ?? "unspecified",
          ]
        ))
    } catch let error as MCPRPCError {
      continuation.yield(
        .error(MCPWireErrorResponse(id: request.id, error: Self.outboundError(error))))
      continuation.finish()
    } catch let error as MCPInvalidRequestParameters {
      continuation.yield(
        .error(
          MCPWireErrorResponse(
            id: request.id,
            error: MCPRPCError(
              code: -32602,
              message: "Invalid params",
              data: .object(["reason": .string(error.reason)])
            )
          )))
      continuation.finish()
    } catch let error as MCPJSONError {
      continuation.yield(
        .error(
          MCPWireErrorResponse(
            id: request.id,
            error: MCPRPCError(
              code: -32602,
              message: "Invalid params",
              data: .object(["reason": .string(error.description)])
            )
          )))
      continuation.finish()
    } catch let error as MCPRegistryError {
      let rpc: MCPRPCError =
        switch error {
        case .unsupportedMethod, .wrongDirection: .methodNotFound
        default: .invalidRequest
        }
      continuation.yield(.error(MCPWireErrorResponse(id: request.id, error: rpc)))
      continuation.finish()
    } catch {
      continuation.yield(
        .error(
          MCPWireErrorResponse(
            id: request.id,
            error: .internalError
          )))
      continuation.finish()
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.request.failed",
          level: .error,
          fields: [
            "method": request.method,
            "requestID": request.id.description,
            "failure": String(reflecting: type(of: error)),
          ]
        ))
    }
  }

  public static func outboundError(_ error: MCPRPCError) -> MCPRPCError {
    let permittedReservedCodes: Set<Int64> = [
      -32700, -32600, -32601, -32602, -32603,
      -32020, -32021, -32022,
    ]
    if let code = error.code.int64Value,
      (-32768 ... -32000).contains(code),
      !permittedReservedCodes.contains(code)
    {
      return .internalError
    }
    return error
  }

  private func resolveAndValidateToolCall(
    request: MCPWireRequest,
    context: MCPRequestContext
  ) async throws -> MCPCompiledServerTool? {
    guard request.method == MCPStandardMethods.callTool.descriptor.name else { return nil }
    guard let toolResolver else {
      throw MCPServerBuildError.incompleteFeature("tool resolver is unavailable")
    }
    let params = try MCPCallToolParams(json: .object(request.params))
    let resolved: MCPTool?
    do {
      resolved = try await toolResolver(params.name, context)
    } catch let error as MCPRPCError {
      throw error
    } catch {
      throw MCPServerHandlerFailure()
    }
    guard let tool = resolved, tool.name == params.name else {
      throw MCPRPCError(
        code: -32602,
        message: "Unknown tool",
        data: .object(["name": .string(params.name)])
      )
    }
    let compiled: MCPCompiledServerTool
    do {
      compiled = try await toolPlanCache.compiledTool(for: tool)
    } catch {
      throw MCPInvalidServerResult()
    }
    do {
      try compiled.inputPlan.validate(.object(params.arguments))
    } catch MCPJSONSchemaError.validationFailed(let issues) {
      throw MCPRPCError(
        code: -32602,
        message: "Invalid tool arguments",
        data: .object([
          "name": .string(params.name),
          "issues": .array(issues.prefix(16).map(Self.schemaIssueJSON)),
        ])
      )
    } catch MCPJSONSchemaError.resourceLimit(let reason) {
      throw MCPRPCError(
        code: -32602,
        message: "Invalid tool arguments",
        data: .object([
          "name": .string(params.name),
          "reason": .string(reason),
        ])
      )
    }
    return compiled
  }

  private func validateToolResult(
    _ rawResult: [String: MCPJSONValue],
    method: String,
    resolvedTool: MCPCompiledServerTool?
  ) async throws {
    if method == MCPStandardMethods.listTools.descriptor.name {
      let result = try MCPListToolsResult(json: .object(rawResult))
      var names = Set<String>()
      for tool in result.tools {
        guard names.insert(tool.name).inserted else {
          throw MCPJSONError.invalidField(
            field: "tools", reason: "duplicate tool name \(tool.name)")
        }
        _ = try await toolPlanCache.compiledTool(for: tool)
      }
      return
    }
    guard method == MCPStandardMethods.callTool.descriptor.name, let resolvedTool else { return }
    let result = try MCPCallToolResult(json: .object(rawResult))
    guard result.resultType == .complete, let outputPlan = resolvedTool.outputPlan else {
      return
    }
    guard let structuredContent = result.structuredContent else {
      throw MCPJSONError.missingField("structuredContent")
    }
    try outputPlan.validate(structuredContent)
  }

  private static func schemaIssueJSON(_ issue: MCPJSONSchemaIssue) -> MCPJSONValue {
    .object([
      "keyword": .string(issue.keyword),
      "instanceLocation": .string(issue.instanceLocation),
      "schemaLocation": .string(issue.schemaLocation),
      "message": .string(issue.message),
    ])
  }

  private func runSubscription(
    request: MCPWireRequest,
    continuation: AsyncThrowingStream<MCPWireMessage, Error>.Continuation,
    control: MCPExecutionControl
  ) async throws {
    let params = try MCPSubscriptionsListenParams(json: .object(request.params))
    let accepted = try params.notifications.accepted(by: capabilities)
    var state = MCPSubscriptionState.opening(requested: params.notifications)
    let ackTransition = try MCPSubscriptionReducer.reduce(
      state: state, event: .acknowledge(accepted))
    state = ackTransition.0
    let opened = await subscriptions.open(id: request.id, filter: accepted)
    let subscriptionHandle = opened.handle
    let stream = opened.stream
    await control.installSubscription(handle: subscriptionHandle, hub: subscriptions)
    let acknowledgement = try MCPSubscriptionsAcknowledgedParams(
      notifications: accepted,
      subscriptionID: request.id
    )
    let acknowledgementNotification = try MCPWireNotification(
      method: "notifications/subscriptions/acknowledged",
      params: acknowledgement.json.objectValue ?? [:]
    )
    guard case .enqueued = continuation.yield(.notification(acknowledgementNotification)) else {
      await subscriptions.remove(handle: subscriptionHandle)
      throw CancellationError()
    }
    await diagnostics.record(
      MCPDiagnosticEvent(
        id: "mcp.subscription.acknowledged",
        level: .info,
        fields: ["requestID": request.id.description]
      ))
    state = try MCPSubscriptionReducer.reduce(state: state, event: .beginListening).0

    do {
      for try await message in stream {
        try Task.checkCancellation()
        switch message {
        case .notification(let notification):
          state = try MCPSubscriptionReducer.reduce(state: state, event: .receiveNotification).0
          guard case .enqueued = continuation.yield(.notification(notification)) else {
            throw CancellationError()
          }
        case .close:
          state = try MCPSubscriptionReducer.reduce(state: state, event: .gracefulClose).0
          let result = try MCPSubscriptionsListenResult(
            subscriptionID: request.id,
            serverInfo: configuration.includeServerInfo ? implementation : nil
          )
          try yieldResult(result.json, id: request.id, continuation: continuation)
          await diagnostics.record(
            MCPDiagnosticEvent(
              id: "mcp.subscription.completed",
              level: .info,
              fields: ["requestID": request.id.description]
            ))
          return
        case .cancel(let reason):
          state = try MCPSubscriptionReducer.reduce(
            state: state,
            event: .serverCancel(reason)
          ).0
          throw MCPServerSubscriptionCancellation(requestID: request.id, reason: reason)
        }
      }
      if case .listening = state {
        _ = try MCPSubscriptionReducer.reduce(state: state, event: .disconnect("stream ended"))
      }
    } catch let cancellation as MCPServerSubscriptionCancellation {
      await subscriptions.remove(handle: subscriptionHandle)
      throw cancellation
    } catch is CancellationError {
      await subscriptions.remove(handle: subscriptionHandle)
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.subscription.cancelled",
          level: .info,
          fields: ["requestID": request.id.description]
        ))
      throw CancellationError()
    } catch {
      await subscriptions.remove(handle: subscriptionHandle)
      await diagnostics.record(
        MCPDiagnosticEvent(
          id: "mcp.subscription.failed",
          level: .error,
          fields: [
            "requestID": request.id.description,
            "failure": String(reflecting: type(of: error)),
          ]
        ))
      throw error
    }
  }

  private func enrichAndValidateResult(
    _ raw: [String: MCPJSONValue],
    descriptor: MCPMethodDescriptor,
    requestMetadata: MCPRequestMetadata
  ) throws -> [String: MCPJSONValue] {
    var result = raw
    guard case .string(let rawResultType)? = result["resultType"] else {
      throw MCPWireError.missingResultType
    }
    let resultType = try MCPResultType(rawValue: rawResultType)
    if case .extensionValue(let value) = resultType,
      !descriptor.extensionResultTypes.contains(value)
    {
      throw MCPWireError.invalidResultType(value)
    }
    if resultType == .inputRequired {
      guard descriptor.allowsMRTR else {
        throw MCPClientError.protocolViolation(
          "\(descriptor.name) does not permit input_required")
      }
      guard result["ttlMs"] == nil, result["cacheScope"] == nil else {
        throw MCPJSONError.invalidField(field: "ttlMs", reason: "input_required is not cacheable")
      }
      try validateInputRequirements(
        result["inputRequests"], capabilities: requestMetadata.clientCapabilities)
    }
    // Extension result types own their payload fields. A task handle, for example, must carry
    // `ttlMs` even though tools/call itself is not cacheable; do not mistake that extension field
    // for the core cache metadata pair.
    let isExtensionResult: Bool
    if case .extensionValue = resultType {
      isExtensionResult = true
    } else {
      isExtensionResult = false
    }
    if descriptor.cacheability == .none, !descriptor.isExtension, !isExtensionResult,
      result["ttlMs"] != nil || result["cacheScope"] != nil
    {
      throw MCPJSONError.invalidField(
        field: "ttlMs", reason: "cache metadata is not allowed for \(descriptor.name)")
    }
    var metadata =
      try result["_meta"].map(MCPResultMetadata.init(json:))
      ?? MCPResultMetadata()
    if configuration.includeServerInfo { metadata.serverInfo = implementation }
    result["_meta"] = metadata.json
    return result
  }

  private func validateInputRequirements(
    _ rawInputRequests: MCPJSONValue?,
    capabilities: MCPClientCapabilities
  ) throws {
    guard let rawInputRequests else { return }
    guard case .object(let inputRequests) = rawInputRequests else {
      throw MCPJSONError.invalidField(field: "inputRequests", reason: "expected object")
    }
    for request in inputRequests.values {
      let elicitation = try MCPElicitationRequest(json: request)
      let supported: Bool =
        switch elicitation.params.mode {
        case .form: capabilities.elicitation?.form == true
        case .url: capabilities.elicitation?.url == true
        }
      guard supported else {
        let required = try MCPClientCapabilities(
          elicitation: try MCPElicitationCapabilities(
            form: elicitation.params.mode == .form,
            url: elicitation.params.mode == .url
          ))
        throw MCPRPCError.missingRequiredClientCapabilities(
          "Client did not declare the elicitation capability required by the result",
          requiredCapabilities: required
        )
      }
    }
  }

  private func validateClientCapability(
    _ path: MCPClientCapabilityPath,
    metadata: MCPRequestMetadata
  ) throws {
    let supported: Bool =
      switch path {
      case .none: true
      case .elicitationForm: metadata.clientCapabilities.elicitation?.form == true
      case .elicitationURL: metadata.clientCapabilities.elicitation?.url == true
      }
    guard supported else {
      let required = try MCPClientCapabilities(
        elicitation: try MCPElicitationCapabilities(
          form: path == .elicitationForm,
          url: path == .elicitationURL
        ))
      throw MCPRPCError.missingRequiredClientCapabilities(
        "Missing required client capability \(path.rawValue)",
        requiredCapabilities: required
      )
    }
  }

  private func resultMetadata() throws -> MCPResultMetadata {
    try MCPResultMetadata(serverInfo: configuration.includeServerInfo ? implementation : nil)
  }

  private func yieldResult(
    _ json: MCPJSONValue,
    id: MCPRequestID,
    continuation: AsyncThrowingStream<MCPWireMessage, Error>.Continuation
  ) throws {
    guard case .object(let object) = json,
      case .string(let rawResultType)? = object["resultType"]
    else {
      throw MCPWireError.missingResultType
    }
    let result = MCPWireResult(
      id: id,
      resultType: try MCPResultType(rawValue: rawResultType),
      value: object
    )
    switch continuation.yield(.result(result)) {
    case .enqueued:
      return
    case .dropped:
      return
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw MCPClientError.protocolViolation("unknown server exchange buffer state")
    }
  }
}
