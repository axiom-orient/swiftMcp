import Foundation

public struct MCPMRTRContext: Sendable, Hashable {
  public let method: String
  public let requestKey: String
  public let round: Int

  public init(method: String, requestKey: String, round: Int) {
    self.method = method
    self.requestKey = requestKey
    self.round = round
  }
}

public protocol MCPElicitationProvider: Sendable {
  func elicit(
    _ request: MCPElicitationRequest,
    context: MCPMRTRContext
  ) async throws -> MCPElicitationResult
}

public struct MCPMRTRPolicy: Sendable, Hashable {
  public let maximumRoundTrips: Int
  public let maximumInputRequestsPerRound: Int
  public let maximumTotalInputRequests: Int
  public let maximumRequestStateBytes: Int
  public let retryDelay: Duration

  public init(
    maximumRoundTrips: Int = 8,
    maximumInputRequestsPerRound: Int = 16,
    maximumTotalInputRequests: Int = 64,
    maximumRequestStateBytes: Int = 65_536,
    retryDelay: Duration = .milliseconds(100)
  ) throws {
    guard maximumRoundTrips > 0 else {
      throw MCPJSONError.invalidField(field: "maximumRoundTrips", reason: "must be positive")
    }
    guard maximumInputRequestsPerRound > 0 else {
      throw MCPJSONError.invalidField(
        field: "maximumInputRequestsPerRound", reason: "must be positive")
    }
    guard maximumTotalInputRequests >= maximumInputRequestsPerRound else {
      throw MCPJSONError.invalidField(
        field: "maximumTotalInputRequests",
        reason: "must be at least maximumInputRequestsPerRound"
      )
    }
    guard maximumRequestStateBytes > 0 else {
      throw MCPJSONError.invalidField(
        field: "maximumRequestStateBytes", reason: "must be positive")
    }
    guard retryDelay >= .zero else {
      throw MCPJSONError.invalidField(field: "retryDelay", reason: "must be non-negative")
    }
    self.maximumRoundTrips = maximumRoundTrips
    self.maximumInputRequestsPerRound = maximumInputRequestsPerRound
    self.maximumTotalInputRequests = maximumTotalInputRequests
    self.maximumRequestStateBytes = maximumRequestStateBytes
    self.retryDelay = retryDelay
  }

  public static let `default` = MCPMRTRPolicy(
    uncheckedMaximumRoundTrips: 8,
    maximumInputRequestsPerRound: 16,
    maximumTotalInputRequests: 64,
    maximumRequestStateBytes: 65_536,
    retryDelay: .milliseconds(100)
  )

  private init(
    uncheckedMaximumRoundTrips: Int,
    maximumInputRequestsPerRound: Int,
    maximumTotalInputRequests: Int,
    maximumRequestStateBytes: Int,
    retryDelay: Duration
  ) {
    maximumRoundTrips = uncheckedMaximumRoundTrips
    self.maximumInputRequestsPerRound = maximumInputRequestsPerRound
    self.maximumTotalInputRequests = maximumTotalInputRequests
    self.maximumRequestStateBytes = maximumRequestStateBytes
    self.retryDelay = retryDelay
  }
}

public enum MCPMRTRState: Sendable, Equatable {
  case ready(round: Int, totalInputRequests: Int)
  case collecting(
    round: Int,
    totalInputRequests: Int,
    requestKeys: [String],
    requestState: String?
  )
  case retrying(round: Int, totalInputRequests: Int)
  case completed(rounds: Int)
}

public enum MCPMRTREvent: Sendable, Equatable {
  case inputRequired(requestKeys: [String], requestState: String?)
  case inputCollected(count: Int)
  case retryIssued
  case completed
}

public enum MCPMRTREffect: Sendable, Equatable {
  case collectInput(keys: [String])
  case delayBeforeRetry
  case issueRetry
  case finish
}

public enum MCPMRTRReducerError: Error, Sendable, Equatable {
  case invalidTransition
  case invalidInputCount
}

public enum MCPMRTRReducer {
  public static func reduce(
    state: MCPMRTRState,
    event: MCPMRTREvent
  ) throws -> (MCPMRTRState, [MCPMRTREffect]) {
    switch (state, event) {
    case (.ready(let round, let total), .inputRequired(let keys, let requestState)):
      let effects: [MCPMRTREffect] =
        keys.isEmpty
        ? [.delayBeforeRetry, .issueRetry]
        : [.collectInput(keys: keys)]
      return (
        .collecting(
          round: round,
          totalInputRequests: total,
          requestKeys: keys,
          requestState: requestState
        ),
        effects
      )

    case (.collecting(let round, let total, let keys, _), .inputCollected(let count)):
      guard count == keys.count else { throw MCPMRTRReducerError.invalidInputCount }
      return (
        .retrying(round: round, totalInputRequests: total + count),
        [.issueRetry]
      )

    case (.collecting(let round, let total, let keys, _), .retryIssued) where keys.isEmpty:
      return (.ready(round: round + 1, totalInputRequests: total), [])

    case (.retrying(let round, let total), .retryIssued):
      return (.ready(round: round + 1, totalInputRequests: total), [])

    case (.ready(let round, _), .completed):
      return (.completed(rounds: round), [.finish])

    case (.completed, _):
      throw MCPMRTRReducerError.invalidTransition

    default:
      throw MCPMRTRReducerError.invalidTransition
    }
  }
}

private protocol MCPMRTRRequestParameters: MCPJSONModel {
  func retrying(
    inputResponses: [String: MCPElicitationResult],
    requestState: String?
  ) throws -> Self
}

private protocol MCPMRTRResponse: MCPJSONModel {
  var resultType: MCPResultType { get }
  var inputRequests: [String: MCPElicitationRequest] { get }
  var requestState: String? { get }
}

extension MCPCallToolParams: MCPMRTRRequestParameters {
  fileprivate func retrying(
    inputResponses: [String: MCPElicitationResult], requestState: String?
  ) throws -> Self {
    try Self(
      name: name,
      arguments: arguments,
      inputResponses: inputResponses,
      requestState: requestState
    )
  }
}

extension MCPGetPromptParams: MCPMRTRRequestParameters {
  fileprivate func retrying(
    inputResponses: [String: MCPElicitationResult], requestState: String?
  ) throws -> Self {
    try Self(
      name: name,
      arguments: arguments,
      inputResponses: inputResponses,
      requestState: requestState
    )
  }
}

extension MCPReadResourceParams: MCPMRTRRequestParameters {
  fileprivate func retrying(
    inputResponses: [String: MCPElicitationResult], requestState: String?
  ) throws -> Self {
    try Self(uri: uri, inputResponses: inputResponses, requestState: requestState)
  }
}

extension MCPCallToolResult: MCPMRTRResponse {}
extension MCPGetPromptResult: MCPMRTRResponse {}
extension MCPReadResourceResult: MCPMRTRResponse {}

extension MCPClient {
  public func callToolResolvingInput(
    _ params: MCPCallToolParams,
    provider: any MCPElicitationProvider,
    policy: MCPMRTRPolicy = .default,
    progress: MCPProgressHandler? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPCallToolResult {
    try await resolveMRTR(
      MCPStandardMethods.callTool,
      initialParams: params,
      provider: provider,
      policy: policy,
      progress: progress,
      metadataExtensions: metadataExtensions
    )
  }

  public func getPromptResolvingInput(
    _ params: MCPGetPromptParams,
    provider: any MCPElicitationProvider,
    policy: MCPMRTRPolicy = .default,
    progress: MCPProgressHandler? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPGetPromptResult {
    try await resolveMRTR(
      MCPStandardMethods.getPrompt,
      initialParams: params,
      provider: provider,
      policy: policy,
      progress: progress,
      metadataExtensions: metadataExtensions
    )
  }

  public func readResourceResolvingInput(
    _ params: MCPReadResourceParams,
    provider: any MCPElicitationProvider,
    policy: MCPMRTRPolicy = .default,
    progress: MCPProgressHandler? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) async throws -> MCPReadResourceResult {
    try await resolveMRTR(
      MCPStandardMethods.readResource,
      initialParams: params,
      provider: provider,
      policy: policy,
      progress: progress,
      metadataExtensions: metadataExtensions
    )
  }

  private func resolveMRTR<Params: MCPMRTRRequestParameters, Result: MCPMRTRResponse>(
    _ method: MCPMethod<Params, Result>,
    initialParams: Params,
    provider: any MCPElicitationProvider,
    policy: MCPMRTRPolicy,
    progress: MCPProgressHandler?,
    metadataExtensions: [String: MCPJSONValue]
  ) async throws -> Result {
    guard method.descriptor.allowsMRTR else {
      throw MCPClientError.protocolViolation(
        "method \(method.descriptor.name) is not registered for multi-round-trip requests")
    }

    var params = initialParams
    var state = MCPMRTRState.ready(round: 0, totalInputRequests: 0)

    while true {
      let result = try await call(
        method,
        params: params,
        progress: progress,
        metadataExtensions: metadataExtensions
      )

      switch result.resultType {
      case .complete:
        _ = try MCPMRTRReducer.reduce(state: state, event: .completed)
        return result

      case .inputRequired:
        guard case .ready(let round, let totalInputRequests) = state else {
          throw MCPClientError.protocolViolation("MRTR coordinator state is not ready")
        }
        guard round < policy.maximumRoundTrips else {
          throw MCPClientError.maximumRoundTripsExceeded(policy.maximumRoundTrips)
        }
        guard result.inputRequests.count <= policy.maximumInputRequestsPerRound else {
          throw MCPClientError.protocolViolation(
            "MRTR input request count exceeds per-round limit \(policy.maximumInputRequestsPerRound)"
          )
        }
        let projectedInputRequests = totalInputRequests + result.inputRequests.count
        guard projectedInputRequests <= policy.maximumTotalInputRequests else {
          throw MCPClientError.protocolViolation(
            "MRTR input request count exceeds total limit \(policy.maximumTotalInputRequests)"
          )
        }
        if let requestState = result.requestState {
          guard requestState.utf8.count <= policy.maximumRequestStateBytes else {
            throw MCPClientError.protocolViolation(
              "MRTR requestState exceeds \(policy.maximumRequestStateBytes) UTF-8 bytes")
          }
        }

        let keys = result.inputRequests.keys.sorted()
        let transition = try MCPMRTRReducer.reduce(
          state: state,
          event: .inputRequired(requestKeys: keys, requestState: result.requestState)
        )
        state = transition.0

        var responses: [String: MCPElicitationResult] = [:]
        if keys.isEmpty {
          if policy.retryDelay > .zero {
            try await ContinuousClock().sleep(for: policy.retryDelay)
          }
          state = try MCPMRTRReducer.reduce(state: state, event: .retryIssued).0
        } else {
          for key in keys {
            guard let request = result.inputRequests[key] else {
              throw MCPClientError.protocolViolation("MRTR input request key disappeared")
            }
            let response = try await provider.elicit(
              request,
              context: MCPMRTRContext(
                method: method.descriptor.name,
                requestKey: key,
                round: round
              )
            )
            try request.params.validate(result: response)
            responses[key] = response
          }
          state = try MCPMRTRReducer.reduce(
            state: state,
            event: .inputCollected(count: responses.count)
          ).0
          state = try MCPMRTRReducer.reduce(state: state, event: .retryIssued).0
        }
        params = try initialParams.retrying(
          inputResponses: responses,
          requestState: result.requestState
        )

      case .extensionValue(let value):
        throw MCPClientError.protocolViolation(
          "MRTR coordinator does not handle extension resultType \(value)")
      }
    }
  }

}
