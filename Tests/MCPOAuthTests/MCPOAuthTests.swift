@preconcurrency import Foundation
import XCTest

@testable import MCP
@testable import MCPOAuth

#if canImport(FoundationNetworking)
  @preconcurrency import FoundationNetworking
#endif

private struct FixedOAuthRandomSource: MCPOAuthRandomSource {
  func bytes(count: Int) throws -> [UInt8] {
    (0..<count).map { UInt8($0 & 0xFF) }
  }
}

private actor OAuthScriptTransport: MCPOAuthHTTPTransport {
  private var responses: [String: [MCPOAuthHTTPResponse]]
  private var requests: [MCPOAuthHTTPRequest] = []
  private let refreshDelay: Duration?

  init(responses: [String: [MCPOAuthHTTPResponse]], refreshDelay: Duration? = nil) {
    self.responses = responses
    self.refreshDelay = refreshDelay
  }

  func send(_ request: MCPOAuthHTTPRequest) async throws -> MCPOAuthHTTPResponse {
    requests.append(request)
    if let refreshDelay,
      request.body.map({ String(decoding: $0, as: UTF8.self) })?
        .contains("grant_type=refresh_token") == true
    {
      try await Task.sleep(for: refreshDelay)
    }
    let key = "\(request.method) \(request.url.absoluteString)"
    guard var queue = responses[key], !queue.isEmpty else {
      throw MCPOAuthError.transport("unexpected request \(key)")
    }
    let response = queue.removeFirst()
    responses[key] = queue
    return response
  }

  func capturedRequests() -> [MCPOAuthHTTPRequest] { requests }
}

private actor CancellationIgnoringRefreshTransport: MCPOAuthHTTPTransport {
  private var responses: [String: [MCPOAuthHTTPResponse]]
  private let blocksAuthorizationCode: Bool
  private var authorizationContinuation: CheckedContinuation<MCPOAuthHTTPResponse, Never>?
  private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
  private var authorizationStarted = false
  private var refreshContinuations: [Int: CheckedContinuation<MCPOAuthHTTPResponse, Never>] = [:]
  private var refreshCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var refreshCount = 0

  init(
    responses: [String: [MCPOAuthHTTPResponse]],
    blocksAuthorizationCode: Bool = false
  ) {
    self.responses = responses
    self.blocksAuthorizationCode = blocksAuthorizationCode
  }

  func send(_ request: MCPOAuthHTTPRequest) async throws -> MCPOAuthHTTPResponse {
    let body = request.body.map { String(decoding: $0, as: UTF8.self) }
    if blocksAuthorizationCode, body?.contains("grant_type=authorization_code") == true {
      authorizationStarted = true
      let waiters = authorizationWaiters
      authorizationWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      return await withCheckedContinuation { continuation in
        authorizationContinuation = continuation
      }
    }
    if body?.contains("grant_type=refresh_token") == true {
      refreshCount += 1
      let index = refreshCount
      resumeCountWaiters()
      if index >= 3 {
        return MCPOAuthHTTPResponse(
          status: 200,
          headers: ["content-type": "application/json"],
          body: Data(
            #"{"access_token":"unexpected-third","token_type":"Bearer","expires_in":3600}"#
              .utf8)
        )
      }
      return await withCheckedContinuation { continuation in
        refreshContinuations[index] = continuation
      }
    }
    let key = "\(request.method) \(request.url.absoluteString)"
    guard var queue = responses[key], !queue.isEmpty else {
      throw MCPOAuthError.transport("unexpected request \(key)")
    }
    let response = queue.removeFirst()
    responses[key] = queue
    return response
  }

  func waitForRefreshCount(_ expected: Int) async {
    guard refreshCount < expected else { return }
    await withCheckedContinuation { continuation in
      refreshCountWaiters[expected, default: []].append(continuation)
    }
  }

  func waitForAuthorizationCodeRequest() async {
    guard !authorizationStarted else { return }
    await withCheckedContinuation { continuation in
      authorizationWaiters.append(continuation)
    }
  }

  func completeAuthorizationCode(with response: MCPOAuthHTTPResponse) -> Bool {
    guard let continuation = authorizationContinuation else { return false }
    self.authorizationContinuation = nil
    continuation.resume(returning: response)
    return true
  }

  func completeRefresh(_ index: Int, with response: MCPOAuthHTTPResponse) -> Bool {
    guard let continuation = refreshContinuations.removeValue(forKey: index) else { return false }
    continuation.resume(returning: response)
    return true
  }

  func capturedRefreshCount() -> Int { refreshCount }

  private func resumeCountWaiters() {
    let readyCounts = refreshCountWaiters.keys.filter { $0 <= refreshCount }
    for count in readyCounts {
      let waiters = refreshCountWaiters.removeValue(forKey: count) ?? []
      for waiter in waiters { waiter.resume() }
    }
  }
}

private enum OAuthCredentialStoreFailure: Error, Sendable {
  case removal
}

private actor RemovalFailingCredentialStore: MCPCredentialStore {
  private var values: [MCPOAuthCredentialKey: MCPOAuthTokenSet] = [:]

  func load(for key: MCPOAuthCredentialKey) -> MCPOAuthTokenSet? { values[key] }
  func save(_ token: MCPOAuthTokenSet, for key: MCPOAuthCredentialKey) { values[key] = token }
  func remove(for key: MCPOAuthCredentialKey) throws { throw OAuthCredentialStoreFailure.removal }
}

private actor BlockingSaveCredentialStore: MCPCredentialStore {
  private var values: [MCPOAuthCredentialKey: MCPOAuthTokenSet] = [:]
  private var shouldBlockNextSave = false
  private var saveEntered = false
  private var saveEnteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var saveRelease: CheckedContinuation<Void, Never>?

  func load(for key: MCPOAuthCredentialKey) -> MCPOAuthTokenSet? { values[key] }

  func save(_ token: MCPOAuthTokenSet, for key: MCPOAuthCredentialKey) async {
    if shouldBlockNextSave {
      shouldBlockNextSave = false
      saveEntered = true
      let enteredWaiters = saveEnteredWaiters
      saveEnteredWaiters.removeAll()
      for waiter in enteredWaiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        saveRelease = continuation
      }
    }
    values[key] = token
  }

  func remove(for key: MCPOAuthCredentialKey) { values.removeValue(forKey: key) }

  func blockNextSave() {
    shouldBlockNextSave = true
    saveEntered = false
  }

  func waitForSaveEntry() async {
    guard !saveEntered else { return }
    await withCheckedContinuation { continuation in
      saveEnteredWaiters.append(continuation)
    }
  }

  func releaseBlockedSave() -> Bool {
    guard let saveRelease else { return false }
    self.saveRelease = nil
    saveRelease.resume()
    return true
  }

}

private actor BlockingLoadCredentialStore: MCPCredentialStore {
  private var values: [MCPOAuthCredentialKey: MCPOAuthTokenSet] = [:]
  private var shouldBlockNextLoad = false
  private var loadEntered = false
  private var loadEnteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var loadRelease: CheckedContinuation<Void, Never>?

  func load(for key: MCPOAuthCredentialKey) async -> MCPOAuthTokenSet? {
    let snapshot = values[key]
    if shouldBlockNextLoad {
      shouldBlockNextLoad = false
      loadEntered = true
      let waiters = loadEnteredWaiters
      loadEnteredWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        loadRelease = continuation
      }
    }
    return snapshot
  }

  func save(_ token: MCPOAuthTokenSet, for key: MCPOAuthCredentialKey) { values[key] = token }
  func remove(for key: MCPOAuthCredentialKey) { values.removeValue(forKey: key) }

  func blockNextLoad() {
    shouldBlockNextLoad = true
    loadEntered = false
  }

  func waitForLoadEntry() async {
    guard !loadEntered else { return }
    await withCheckedContinuation { continuation in
      loadEnteredWaiters.append(continuation)
    }
  }

  func releaseBlockedLoad() -> Bool {
    guard let loadRelease else { return false }
    self.loadRelease = nil
    loadRelease.resume()
    return true
  }
}

private final class OAuthTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date { lock.withLock { value } }

  func advance(by interval: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(interval) }
  }
}

private final class OAuthStreamingURLProtocol: URLProtocol {
  fileprivate struct Script: Sendable {
    let chunks: [Data]
    let delay: TimeInterval
  }

  fileprivate static let scriptLock = NSLock()
  nonisolated(unsafe) fileprivate static var script = Script(chunks: [], delay: 0)
  nonisolated(unsafe) fileprivate static var deliveredChunks = 0

  fileprivate let stateLock = NSLock()
  fileprivate var stopped = false

  static func configure(chunks: [Data], delay: TimeInterval) {
    scriptLock.withLock {
      script = Script(chunks: chunks, delay: delay)
      deliveredChunks = 0
    }
  }

  static func deliveredChunkCount() -> Int {
    scriptLock.withLock { deliveredChunks }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "oauth-stream.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let script = Self.scriptLock.withLock { Self.script }
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let delivery = OAuthStreamingDelivery(protocol: self, script: script)
    DispatchQueue.global().async { delivery.run() }
  }

  override func stopLoading() {
    stateLock.withLock { stopped = true }
  }
}

private final class OAuthStreamingDelivery: @unchecked Sendable {
  private weak var protocolInstance: OAuthStreamingURLProtocol?
  private let script: OAuthStreamingURLProtocol.Script

  init(protocol: OAuthStreamingURLProtocol, script: OAuthStreamingURLProtocol.Script) {
    protocolInstance = `protocol`
    self.script = script
  }

  func run() {
    guard let protocolInstance else { return }
    for chunk in script.chunks {
      if script.delay > 0 { Thread.sleep(forTimeInterval: script.delay) }
      guard !protocolInstance.stateLock.withLock({ protocolInstance.stopped }) else { return }
      OAuthStreamingURLProtocol.scriptLock.withLock {
        OAuthStreamingURLProtocol.deliveredChunks += 1
      }
      protocolInstance.client?.urlProtocol(protocolInstance, didLoad: chunk)
    }
    guard !protocolInstance.stateLock.withLock({ protocolInstance.stopped }) else { return }
    protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
  }
}

final class MCPOAuthTests: XCTestCase {
  private let resource = URL(string: "http://127.0.0.1:9000/mcp")!
  private let issuer = URL(string: "https://127.0.0.1:9001/issuer")!
  private let redirect = URL(string: "http://127.0.0.1:7777/callback?channel=desktop")!

  private var resourceMetadataURL: URL {
    URL(string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp")!
  }

  private var rootResourceMetadataURL: URL {
    URL(string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource")!
  }

  private var authorizationServerMetadataURL: URL {
    URL(string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer")!
  }

  private var tokenEndpoint: URL { URL(string: "https://127.0.0.1:9001/token")! }

  func testPKCEUsesTheS256KnownAnswer() throws {
    let pkce = try MCPOAuthPKCE(randomSource: FixedOAuthRandomSource())
    XCTAssertEqual(
      pkce.verifier,
      "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0-Pw"
    )
    XCTAssertEqual(pkce.challenge, "wsNdZaf3VpLTsEDmR5gPk2C6xYVWxKb0xcaG3O6kX10")
  }

  private func jsonResponse(_ text: String, status: Int = 200) -> MCPOAuthHTTPResponse {
    MCPOAuthHTTPResponse(
      status: status,
      headers: ["content-type": "application/json"],
      body: Data(text.utf8)
    )
  }

  private func resourceMetadata(
    scopes: [String] = ["resource:read"],
    authorizationServers: [URL]? = nil
  ) -> MCPOAuthHTTPResponse {
    let servers = (authorizationServers ?? [issuer])
      .map { "\"\($0.absoluteString)\"" }
      .joined(separator: ",")
    let scopeJSON = scopes.map { "\"\($0)\"" }.joined(separator: ",")
    return jsonResponse(
      """
      {
        "resource":"\(resource.absoluteString)",
        "authorization_servers":[\(servers)],
        "scopes_supported":[\(scopeJSON)],
        "bearer_methods_supported":["header"]
      }
      """
    )
  }

  private func authorizationServerMetadata(
    issuer: URL? = nil,
    supportedScopes: [String] = ["resource:read"],
    authorizationEndpoint: String = "https://127.0.0.1:9001/authorize"
  ) -> MCPOAuthHTTPResponse {
    let scopeJSON = supportedScopes.map { "\"\($0)\"" }.joined(separator: ",")
    return jsonResponse(
      """
      {
        "issuer":"\((issuer ?? self.issuer).absoluteString)",
        "authorization_endpoint":"\(authorizationEndpoint)",
        "token_endpoint":"\(tokenEndpoint.absoluteString)",
        "code_challenge_methods_supported":["S256"],
        "authorization_response_iss_parameter_supported":true,
        "client_id_metadata_document_supported":true,
        "scopes_supported":[\(scopeJSON)]
      }
      """
    )
  }

  private func registration(
    authMethod: MCPOAuthTokenEndpointAuthMethod = .none,
    secret: String? = nil
  ) throws -> MCPOAuthClientRegistration {
    .preRegistered(
      try MCPPreRegisteredOAuthClient(
        issuer: issuer,
        clientID: "desktop-client",
        clientSecret: secret,
        tokenEndpointAuthMethod: authMethod,
        redirectURIs: [redirect]
      ))
  }

  private func client(
    transport: OAuthScriptTransport,
    store: MCPMemoryCredentialStore = MCPMemoryCredentialStore(),
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000) },
    refreshLeeway: TimeInterval = 0
  ) throws -> (MCPOAuthClient, MCPMemoryCredentialStore) {
    (
      try MCPOAuthClient(
        resource: resource,
        registration: registration(),
        store: store,
        http: transport,
        random: FixedOAuthRandomSource(),
        refreshLeeway: refreshLeeway,
        now: now
      ),
      store
    )
  }

  private func standardDiscoveryResponses(
    tokenResponses: [MCPOAuthHTTPResponse] = []
  ) -> [String: [MCPOAuthHTTPResponse]] {
    var result = [
      "GET \(resourceMetadataURL.absoluteString)": [resourceMetadata()],
      "GET \(authorizationServerMetadataURL.absoluteString)": [authorizationServerMetadata()],
    ]
    if !tokenResponses.isEmpty {
      result["POST \(tokenEndpoint.absoluteString)"] = tokenResponses
    }
    return result
  }

  private func refreshRaceClient() async throws -> (
    MCPOAuthClient, MCPMemoryCredentialStore, CancellationIgnoringRefreshTransport
  ) {
    let initial = jsonResponse(
      #"{"access_token":"expired","token_type":"Bearer","expires_in":0,"refresh_token":"refresh-1"}"#
    )
    let transport = CancellationIgnoringRefreshTransport(
      responses: standardDiscoveryResponses(tokenResponses: [initial]))
    let store = MCPMemoryCredentialStore()
    let oauth = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: store,
      http: transport,
      random: FixedOAuthRandomSource(),
      refreshLeeway: 0,
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    let pending = try await oauth.beginAuthorization(redirectURI: redirect)
    _ = try await oauth.completeAuthorization(
      callbackURL: callback(pending: pending),
      pending: pending
    )
    return (oauth, store, transport)
  }

  private func query(_ url: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
      guard result.updateValue(item.value ?? "", forKey: item.name) == nil else {
        throw MCPOAuthError.invalidMetadata("duplicate query item \(item.name)")
      }
    }
    return result
  }

  private func form(_ data: Data?) -> [String: String] {
    guard let data else { return [:] }
    return String(decoding: data, as: UTF8.self)
      .split(separator: "&")
      .reduce(into: [:]) { result, component in
        let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(pair[0]).removingPercentEncoding ?? String(pair[0])
        let raw = pair.count == 2 ? String(pair[1]).replacingOccurrences(of: "+", with: " ") : ""
        result[name] = raw.removingPercentEncoding ?? raw
      }
  }

  private func callback(pending: MCPOAuthPendingAuthorization, issuer: String? = nil) -> URL {
    var components = URLComponents(url: pending.redirectURI, resolvingAgainstBaseURL: false)!
    var items = components.queryItems ?? []
    items.append(contentsOf: [
      URLQueryItem(name: "code", value: "authorization-code"),
      URLQueryItem(name: "state", value: pending.state),
      URLQueryItem(name: "iss", value: issuer ?? pending.issuer.absoluteString),
    ])
    components.queryItems = items
    return components.url!
  }

  func testChallengeURLPolicyAndRegistrationValidation() throws {
    let challenge = try MCPOAuthChallenge(
      wwwAuthenticate:
        #"Bearer resource_metadata="http://127.0.0.1:9000/meta", scope="files:read files:write""#
    )
    XCTAssertEqual(challenge.resourceMetadataURL?.absoluteString, "http://127.0.0.1:9000/meta")
    XCTAssertEqual(challenge.scopes, ["files:read", "files:write"])
    XCTAssertThrowsError(try MCPOAuthChallenge(wwwAuthenticate: "Basic realm=example"))

    let policy = MCPOAuthURLPolicy()
    XCTAssertNoThrow(try policy.validate(resource, purpose: "resource"))
    XCTAssertThrowsError(
      try policy.validate(URL(string: "http://example.com/mcp")!, purpose: "resource"))
    for host in ["127.0.0.1", "127.255.255.255", "localhost", "::1", "[::1]"] {
      XCTAssertTrue(MCPOAuthURLPolicy.isLoopback(host), host)
    }
    for host in [
      "127.sub.example.com", "127.evil.attacker.net", "127.0.0.999", "127.0.0", "127..0.1",
    ] {
      XCTAssertFalse(MCPOAuthURLPolicy.isLoopback(host), host)
    }
    XCTAssertThrowsError(
      try policy.validate(
        URL(string: "http://127.evil.attacker.net/mcp")!, purpose: "resource"))

    let insecureAuthorizationServer = URL(string: "http://127.0.0.1:9001/issuer")!
    XCTAssertThrowsError(
      try MCPPreRegisteredOAuthClient(
        issuer: insecureAuthorizationServer,
        clientID: "client",
        redirectURIs: [redirect]
      )
    ) { error in
      XCTAssertEqual(
        error as? MCPOAuthError,
        .insecureURL(insecureAuthorizationServer.absoluteString)
      )
    }

    XCTAssertThrowsError(
      try MCPPreRegisteredOAuthClient(
        issuer: issuer,
        clientID: "client",
        clientSecret: "unused",
        redirectURIs: [redirect]
      )
    )
    XCTAssertThrowsError(
      try MCPPreRegisteredOAuthClient(
        issuer: issuer,
        clientID: "client",
        tokenEndpointAuthMethod: .clientSecretBasic,
        redirectURIs: [redirect]
      )
    )
    XCTAssertThrowsError(
      try MCPClientIDMetadataDocument(
        clientID: URL(string: "https://client.example/metadata.json")!,
        clientName: "Client",
        redirectURIs: [redirect],
        tokenEndpointAuthMethod: .clientSecretPost
      )
    )
  }

  func testChallengeSelectsBearerFromCompoundHeadersAndRejectsMalformedParameters() throws {
    let header =
      "Basic realm=\"legacy\", Bearer scope=\"files:read files:write\", "
      + "resource_metadata=\"https://auth.example/metadata?label=a,b\""
    let challenge = try MCPOAuthChallenge(
      wwwAuthenticate: header
    )
    XCTAssertEqual(
      challenge.resourceMetadataURL,
      URL(string: "https://auth.example/metadata?label=a,b")
    )
    XCTAssertEqual(challenge.scopes, ["files:read", "files:write"])

    for value in [
      #"BearerX resource_metadata="https://auth.example/metadata""#,
      #"Basic realm="legacy""#,
      #"Bearer resource_metadata="https://auth.example/metadata" scope="files:read""#,
      #"Bearer scope="files:read", scope="files:write""#,
      #"Bearer scope="files:read",, resource_metadata="https://auth.example/metadata""#,
    ] {
      XCTAssertThrowsError(try MCPOAuthChallenge(wwwAuthenticate: value), value)
    }
  }

  func testURLSessionTransportHardStopsOversizedStreamingResponse() async throws {
    let chunks = (0..<8).map { _ in Data(repeating: 0x61, count: 8) }
    OAuthStreamingURLProtocol.configure(chunks: chunks, delay: 0.05)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OAuthStreamingURLProtocol.self]
    let transport = MCPURLSessionOAuthTransport(configuration: configuration)

    do {
      _ = try await transport.send(
        MCPOAuthHTTPRequest(
          url: URL(string: "https://oauth-stream.test/metadata")!,
          timeout: 5,
          maximumResponseBytes: 12
        ))
      XCTFail("expected streaming response limit failure")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(error, .responseTooLarge(12))
    }
    XCTAssertLessThan(OAuthStreamingURLProtocol.deliveredChunkCount(), chunks.count)
  }

  func testURLSessionTransportPreservesCallerCancellation() async throws {
    OAuthStreamingURLProtocol.configure(
      chunks: (0..<20).map { _ in Data(repeating: 0x61, count: 8) },
      delay: 0.05
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OAuthStreamingURLProtocol.self]
    let transport = MCPURLSessionOAuthTransport(configuration: configuration)
    let request = MCPOAuthHTTPRequest(
      url: URL(string: "https://oauth-stream.test/token")!,
      timeout: 5,
      maximumResponseBytes: 1_024
    )
    let task = Task { try await transport.send(request) }
    try await Task.sleep(for: .milliseconds(10))
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // The caller's cancellation is not collapsed into a generic transport failure.
    } catch {
      XCTFail("unexpected cancellation error: \(error)")
    }
  }

  func testPendingAuthorizationLimitsAreValidated() throws {
    let transport = OAuthScriptTransport(responses: [:])
    for ttl in [0, -1, .infinity, .nan] as [TimeInterval] {
      XCTAssertThrowsError(
        try MCPOAuthClient(
          resource: resource,
          registration: registration(),
          store: MCPMemoryCredentialStore(),
          http: transport,
          pendingAuthorizationTTL: ttl
        ))
    }
    for limit in [0, -1] {
      XCTAssertThrowsError(
        try MCPOAuthClient(
          resource: resource,
          registration: registration(),
          store: MCPMemoryCredentialStore(),
          http: transport,
          maximumPendingAuthorizations: limit
        ))
    }
  }

  func testPendingAuthorizationCapacityAndExpiryAreEnforced() async throws {
    let transport = OAuthScriptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [resourceMetadata(), resourceMetadata()],
      "GET \(authorizationServerMetadataURL.absoluteString)": [
        authorizationServerMetadata(), authorizationServerMetadata(),
      ],
    ])
    let clock = OAuthTestClock(Date(timeIntervalSince1970: 1_000))
    let oauth = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: transport,
      random: FixedOAuthRandomSource(),
      pendingAuthorizationTTL: 60,
      maximumPendingAuthorizations: 1,
      now: { clock.now() }
    )
    let first = try await oauth.beginAuthorization(redirectURI: redirect)

    do {
      _ = try await oauth.beginAuthorization(redirectURI: redirect)
      XCTFail("expected pending authorization capacity failure")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(error, .pendingAuthorizationLimitExceeded(1))
    }
    let requestsBeforeExpiry = await transport.capturedRequests()
    XCTAssertEqual(requestsBeforeExpiry.count, 2)

    clock.advance(by: 60)
    do {
      _ = try await oauth.completeAuthorization(
        callbackURL: callback(pending: first),
        pending: first
      )
      XCTFail("expected expired state rejection")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(error, .authorizationStateNotPending)
    }

    _ = try await oauth.beginAuthorization(redirectURI: redirect)
    let requestsAfterExpiry = await transport.capturedRequests()
    XCTAssertEqual(requestsAfterExpiry.count, 4)
  }

  func testDiscoveryDoesNotHideTransportOrServerFailureBehindFallback() async throws {
    let transport = OAuthScriptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [
        jsonResponse(#"{"error":"down"}"#, status: 500)
      ],
      "GET \(rootResourceMetadataURL.absoluteString)": [resourceMetadata()],
    ])
    let (oauth, _) = try client(transport: transport)
    do {
      _ = try await oauth.discover()
      XCTFail("expected discovery failure")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(error, .transport("metadata HTTP 500"))
    }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.url), [resourceMetadataURL])
  }

  func testAuthorizationCodeFlowPreservesRequiredChallengeScopesAndCredentials() async throws {
    let token = jsonResponse(
      #"{"access_token":"access-1","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh-1","scope":"required:write explicit:read"}"#
    )
    let transport = OAuthScriptTransport(
      responses: standardDiscoveryResponses(tokenResponses: [token]))
    let (oauth, _) = try client(transport: transport)
    let challenge = MCPOAuthChallenge(scopes: ["required:write"])
    let pending = try await oauth.beginAuthorization(
      redirectURI: redirect,
      scopes: ["explicit:read"],
      challenge: challenge
    )

    let authorizationQuery = try query(pending.authorizationURL)
    XCTAssertEqual(authorizationQuery["response_type"], "code")
    XCTAssertEqual(authorizationQuery["code_challenge_method"], "S256")
    XCTAssertEqual(authorizationQuery["scope"], "required:write explicit:read")
    XCTAssertEqual(authorizationQuery["resource"], resource.absoluteString)
    XCTAssertFalse(pending.codeVerifier.isEmpty)

    let completed = try await oauth.completeAuthorization(
      callbackURL: callback(pending: pending), pending: pending)
    XCTAssertEqual(completed.accessToken, "access-1")
    let authorizationHeader = try await oauth.authorizationHeader(for: resource)
    XCTAssertEqual(authorizationHeader, "Bearer access-1")

    let requests = await transport.capturedRequests()
    guard let tokenRequest = requests.last else { return XCTFail("missing token request") }
    XCTAssertEqual(tokenRequest.method, "POST")
    let tokenForm = form(tokenRequest.body)
    XCTAssertEqual(tokenForm["grant_type"], "authorization_code")
    XCTAssertEqual(tokenForm["code"], "authorization-code")
    XCTAssertEqual(tokenForm["code_verifier"], pending.codeVerifier)
    XCTAssertEqual(tokenForm["resource"], resource.absoluteString)
    XCTAssertNil(tokenRequest.headers["authorization"])
  }

  func testAuthorizationCallbackIsExactIssuerBoundAndSingleUse() async throws {
    let transport = OAuthScriptTransport(responses: standardDiscoveryResponses())
    let (oauth, _) = try client(transport: transport)
    let pending = try await oauth.beginAuthorization(redirectURI: redirect)

    do {
      _ = try await oauth.completeAuthorization(
        callbackURL: callback(pending: pending, issuer: "http://127.0.0.1:9999/evil"),
        pending: pending
      )
      XCTFail("expected issuer mismatch")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(
        error,
        .authorizationResponseIssuerMismatch(
          expected: issuer.absoluteString,
          actual: "http://127.0.0.1:9999/evil"
        )
      )
    }

    do {
      _ = try await oauth.completeAuthorization(
        callbackURL: callback(pending: pending), pending: pending)
      XCTFail("expected consumed state")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(error, .authorizationStateNotPending)
    }
  }

  func testCallbackRejectsModifiedRegisteredQueryAndDuplicateParameters() async throws {
    let transport = OAuthScriptTransport(responses: standardDiscoveryResponses())
    let (oauth, _) = try client(transport: transport)
    let pending = try await oauth.beginAuthorization(redirectURI: redirect)

    var modified = URLComponents(url: callback(pending: pending), resolvingAgainstBaseURL: false)!
    modified.queryItems = modified.queryItems?.filter { $0.name != "channel" }
    do {
      _ = try await oauth.completeAuthorization(callbackURL: modified.url!, pending: pending)
      XCTFail("expected redirect mismatch")
    } catch let error as MCPOAuthError {
      guard case .redirectURINotRegistered = error else { return XCTFail("unexpected \(error)") }
    }

    let secondTransport = OAuthScriptTransport(responses: standardDiscoveryResponses())
    let (second, _) = try client(transport: secondTransport)
    let secondPending = try await second.beginAuthorization(redirectURI: redirect)
    var duplicate = URLComponents(
      url: callback(pending: secondPending), resolvingAgainstBaseURL: false)!
    duplicate.queryItems?.append(URLQueryItem(name: "state", value: secondPending.state))
    do {
      _ = try await second.completeAuthorization(
        callbackURL: duplicate.url!, pending: secondPending)
      XCTFail("expected duplicate query rejection")
    } catch let error as MCPOAuthError {
      guard case .invalidMetadata = error else { return XCTFail("unexpected \(error)") }
    }
  }

  func testExpiredTokenRefreshIsSingleFlight() async throws {
    let initial = jsonResponse(
      #"{"access_token":"expired","token_type":"Bearer","expires_in":0,"refresh_token":"refresh-1"}"#
    )
    let refreshed = jsonResponse(
      #"{"access_token":"fresh","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh-2"}"#
    )
    let transport = OAuthScriptTransport(
      responses: standardDiscoveryResponses(tokenResponses: [initial, refreshed]),
      refreshDelay: .milliseconds(50)
    )
    let (oauth, _) = try client(transport: transport)
    let pending = try await oauth.beginAuthorization(redirectURI: redirect)
    _ = try await oauth.completeAuthorization(
      callbackURL: callback(pending: pending), pending: pending)

    let targetResource = resource
    async let first = oauth.authorizationHeader(for: targetResource)
    async let second = oauth.authorizationHeader(for: targetResource)
    let values = try await [first, second]
    XCTAssertEqual(values, ["Bearer fresh", "Bearer fresh"])

    let requests = await transport.capturedRequests()
    let refreshRequests = requests.filter {
      form($0.body)["grant_type"] == "refresh_token"
    }
    XCTAssertEqual(refreshRequests.count, 1)
    XCTAssertEqual(form(refreshRequests[0].body)["refresh_token"], "refresh-1")
  }

  func testInvalidationFencesLateCancellationIgnoringRefreshSuccess() async throws {
    let (oauth, store, transport) = try await refreshRaceClient()
    let targetResource = resource
    let firstRefresh = Task { try await oauth.authorizationHeader(for: targetResource) }
    await transport.waitForRefreshCount(1)

    try await oauth.invalidateCurrentToken()
    let lateResponse = jsonResponse(
      #"{"access_token":"late-first","token_type":"Bearer","expires_in":0,"refresh_token":"late-refresh"}"#
    )
    let resumed = await transport.completeRefresh(1, with: lateResponse)
    XCTAssertTrue(resumed)
    do {
      _ = try await firstRefresh.value
      XCTFail("expected invalidated refresh cancellation")
    } catch is CancellationError {
      // The transport ignored cancellation, but the generation fence rejects its result.
    } catch {
      XCTFail("unexpected refresh error: \(error)")
    }

    let key = MCPOAuthCredentialKey(resource: resource, issuer: issuer, clientID: "desktop-client")
    let persisted = await store.load(for: key)
    XCTAssertNil(persisted)
  }

  func testInvalidationFencesLateAuthorizationCodeCredentialSave() async throws {
    let transport = CancellationIgnoringRefreshTransport(
      responses: standardDiscoveryResponses(),
      blocksAuthorizationCode: true
    )
    let store = MCPMemoryCredentialStore()
    let oauth = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: store,
      http: transport,
      random: FixedOAuthRandomSource(),
      refreshLeeway: 0,
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    let pending = try await oauth.beginAuthorization(redirectURI: redirect)
    let callbackURL = callback(pending: pending)
    let completion = Task {
      try await oauth.completeAuthorization(callbackURL: callbackURL, pending: pending)
    }
    await transport.waitForAuthorizationCodeRequest()

    try await oauth.invalidateCurrentToken()
    let tokenResponse = jsonResponse(
      #"{"access_token":"late-authorization","token_type":"Bearer","expires_in":3600}"#
    )
    let resumed = await transport.completeAuthorizationCode(with: tokenResponse)
    XCTAssertTrue(resumed)
    do {
      _ = try await completion.value
      XCTFail("expected stale authorization completion cancellation")
    } catch is CancellationError {
      // Invalidation changed the captured credential generation before the response arrived.
    } catch {
      XCTFail("unexpected authorization completion error: \(error)")
    }

    let key = MCPOAuthCredentialKey(resource: resource, issuer: issuer, clientID: "desktop-client")
    let persisted = await store.load(for: key)
    XCTAssertNil(persisted)
  }

  func testAuthorizationCompletionSupersedesInFlightRefresh() async throws {
    let initial = jsonResponse(
      #"{"access_token":"expired","token_type":"Bearer","expires_in":0,"refresh_token":"refresh-1"}"#
    )
    let replacement = jsonResponse(
      #"{"access_token":"new-authorization","token_type":"Bearer","expires_in":3600}"#
    )
    let transport = CancellationIgnoringRefreshTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [resourceMetadata(), resourceMetadata()],
      "GET \(authorizationServerMetadataURL.absoluteString)": [
        authorizationServerMetadata(), authorizationServerMetadata(),
      ],
      "POST \(tokenEndpoint.absoluteString)": [initial, replacement],
    ])
    let store = MCPMemoryCredentialStore()
    let oauth = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: store,
      http: transport,
      random: FixedOAuthRandomSource(),
      refreshLeeway: 0,
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    let firstPending = try await oauth.beginAuthorization(redirectURI: redirect)
    _ = try await oauth.completeAuthorization(
      callbackURL: callback(pending: firstPending),
      pending: firstPending
    )

    let targetResource = resource
    let refresh = Task { try await oauth.authorizationHeader(for: targetResource) }
    await transport.waitForRefreshCount(1)
    let replacementPending = try await oauth.beginAuthorization(redirectURI: redirect)
    let replacementToken = try await oauth.completeAuthorization(
      callbackURL: callback(pending: replacementPending),
      pending: replacementPending
    )
    XCTAssertEqual(replacementToken.accessToken, "new-authorization")

    let lateRefresh = jsonResponse(
      #"{"access_token":"late-refresh","token_type":"Bearer","expires_in":3600}"#
    )
    let resumed = await transport.completeRefresh(1, with: lateRefresh)
    XCTAssertTrue(resumed)
    do {
      _ = try await refresh.value
      XCTFail("expected superseded refresh cancellation")
    } catch is CancellationError {
      // The authorization completion advanced generation and canceled the old refresh lease.
    } catch {
      XCTFail("unexpected refresh error: \(error)")
    }

    let header = try await oauth.authorizationHeader(for: resource)
    XCTAssertEqual(header, "Bearer new-authorization")
  }

  func testInvalidationWaitsForInFlightCredentialSaveThenRemovesIt() async throws {
    let initial = jsonResponse(
      #"{"access_token":"expired","token_type":"Bearer","expires_in":0,"refresh_token":"refresh-1"}"#
    )
    let refreshed = jsonResponse(
      #"{"access_token":"fresh","token_type":"Bearer","expires_in":3600}"#
    )
    let transport = OAuthScriptTransport(
      responses: standardDiscoveryResponses(tokenResponses: [initial, refreshed]))
    let store = BlockingSaveCredentialStore()
    let oauth = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: store,
      http: transport,
      random: FixedOAuthRandomSource(),
      refreshLeeway: 0,
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    let pending = try await oauth.beginAuthorization(redirectURI: redirect)
    _ = try await oauth.completeAuthorization(
      callbackURL: callback(pending: pending),
      pending: pending
    )

    await store.blockNextSave()
    let targetResource = resource
    let refresh = Task { try await oauth.authorizationHeader(for: targetResource) }
    await store.waitForSaveEntry()
    let invalidation = Task { try await oauth.invalidateCurrentToken() }
    try await Task.sleep(for: .milliseconds(20))
    let released = await store.releaseBlockedSave()
    XCTAssertTrue(released)

    do {
      _ = try await refresh.value
      XCTFail("expected refresh invalidation")
    } catch is CancellationError {
      // The save finishes, then the queued invalidation performs the final removal.
    } catch {
      XCTFail("unexpected refresh error: \(error)")
    }
    try await invalidation.value

    let key = MCPOAuthCredentialKey(resource: resource, issuer: issuer, clientID: "desktop-client")
    let persisted = await store.load(for: key)
    XCTAssertNil(persisted)
  }

  func testInvalidationFencesStaleCredentialLoadBeforeRefreshRegistration() async throws {
    let unexpectedRefresh = jsonResponse(
      #"{"access_token":"unexpected-refresh","token_type":"Bearer","expires_in":3600}"#
    )
    let transport = OAuthScriptTransport(
      responses: standardDiscoveryResponses(tokenResponses: [unexpectedRefresh]))
    let store = BlockingLoadCredentialStore()
    let oauth = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: store,
      http: transport,
      random: FixedOAuthRandomSource(),
      refreshLeeway: 0,
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    _ = try await oauth.beginAuthorization(redirectURI: redirect)
    let key = MCPOAuthCredentialKey(resource: resource, issuer: issuer, clientID: "desktop-client")
    let expired = try MCPOAuthTokenSet(
      accessToken: "expired",
      expiresAt: Date(timeIntervalSince1970: 1_000),
      refreshToken: "refresh-1"
    )
    await store.save(expired, for: key)
    await store.blockNextLoad()

    let targetResource = resource
    let header = Task { try await oauth.authorizationHeader(for: targetResource) }
    await store.waitForLoadEntry()
    let invalidation = Task { try await oauth.invalidateCurrentToken() }
    try await Task.sleep(for: .milliseconds(20))
    let released = await store.releaseBlockedLoad()
    XCTAssertTrue(released)

    do {
      _ = try await header.value
      XCTFail("expected stale credential load cancellation")
    } catch is CancellationError {
      // The old snapshot cannot be promoted into a refresh after invalidation changes generation.
    } catch {
      XCTFail("unexpected authorization header error: \(error)")
    }
    try await invalidation.value
    let requests = await transport.capturedRequests()
    let refreshRequests = requests.filter {
      form($0.body)["grant_type"] == "refresh_token"
    }
    XCTAssertTrue(refreshRequests.isEmpty)
    let persisted = await store.load(for: key)
    XCTAssertNil(persisted)
  }

  func testLateRefreshCleanupCannotRemoveNewSingleFlightOperation() async throws {
    let (oauth, store, transport) = try await refreshRaceClient()
    let targetResource = resource
    let firstRefresh = Task { try await oauth.authorizationHeader(for: targetResource) }
    await transport.waitForRefreshCount(1)
    try await oauth.invalidateCurrentToken()

    let key = MCPOAuthCredentialKey(resource: resource, issuer: issuer, clientID: "desktop-client")
    let replacement = try MCPOAuthTokenSet(
      accessToken: "expired-second",
      expiresAt: Date(timeIntervalSince1970: 1_000),
      refreshToken: "refresh-2"
    )
    await store.save(replacement, for: key)
    let secondRefresh = Task { try await oauth.authorizationHeader(for: targetResource) }
    await transport.waitForRefreshCount(2)

    let lateResponse = jsonResponse(
      #"{"access_token":"late-first","token_type":"Bearer","expires_in":0,"refresh_token":"late-refresh"}"#
    )
    let resumed = await transport.completeRefresh(1, with: lateResponse)
    XCTAssertTrue(resumed)
    do {
      _ = try await firstRefresh.value
      XCTFail("expected invalidated refresh cancellation")
    } catch is CancellationError {
      // Expected: T1 is stale while T2 remains the current operation.
    } catch {
      XCTFail("unexpected refresh error: \(error)")
    }

    let currentResponse = jsonResponse(
      #"{"access_token":"fresh-second","token_type":"Bearer","expires_in":3600}"#
    )
    let delayedRelease = Task {
      try await Task.sleep(for: .milliseconds(50))
      return await transport.completeRefresh(2, with: currentResponse)
    }
    let joinedHeader = try await oauth.authorizationHeader(for: targetResource)
    let ownerHeader = try await secondRefresh.value
    let released = try await delayedRelease.value
    XCTAssertTrue(released)
    XCTAssertEqual(joinedHeader, "Bearer fresh-second")
    XCTAssertEqual(ownerHeader, "Bearer fresh-second")
    let refreshCount = await transport.capturedRefreshCount()
    XCTAssertEqual(refreshCount, 2)
  }

  func testInvalidGrantRemovesPersistedCredential() async throws {
    let initial = jsonResponse(
      #"{"access_token":"expired","token_type":"Bearer","expires_in":0,"refresh_token":"refresh-1"}"#
    )
    let invalidGrant = jsonResponse(
      #"{"error":"invalid_grant","error_description":"revoked"}"#,
      status: 400
    )
    let transport = OAuthScriptTransport(
      responses: standardDiscoveryResponses(tokenResponses: [initial, invalidGrant]))
    let store = MCPMemoryCredentialStore()
    let (oauth, _) = try client(transport: transport, store: store)
    let pending = try await oauth.beginAuthorization(redirectURI: redirect)
    _ = try await oauth.completeAuthorization(
      callbackURL: callback(pending: pending), pending: pending)

    do {
      _ = try await oauth.authorizationHeader(for: resource)
      XCTFail("expected invalid_grant")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(
        error,
        .tokenEndpointFailure(status: 400, code: "invalid_grant", description: "revoked")
      )
    }
    let key = MCPOAuthCredentialKey(resource: resource, issuer: issuer, clientID: "desktop-client")
    let persisted = await store.load(for: key)
    XCTAssertNil(persisted)
  }

  func testInvalidGrantDoesNotHideCredentialRemovalFailure() async throws {
    let initial = jsonResponse(
      #"{"access_token":"expired","token_type":"Bearer","expires_in":0,"refresh_token":"refresh-1"}"#
    )
    let invalidGrant = jsonResponse(
      #"{"error":"invalid_grant","error_description":"revoked"}"#,
      status: 400
    )
    let transport = OAuthScriptTransport(
      responses: standardDiscoveryResponses(tokenResponses: [initial, invalidGrant]))
    let store = RemovalFailingCredentialStore()
    let oauth = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: store,
      http: transport,
      random: FixedOAuthRandomSource(),
      refreshLeeway: 0,
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    let pending = try await oauth.beginAuthorization(redirectURI: redirect)
    _ = try await oauth.completeAuthorization(
      callbackURL: callback(pending: pending), pending: pending)

    do {
      _ = try await oauth.authorizationHeader(for: resource)
      XCTFail("expected credential removal failure")
    } catch let error as MCPOAuthError {
      guard case .invalidGrantCredentialRemovalFailed(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("removal"))
    }
  }

}
