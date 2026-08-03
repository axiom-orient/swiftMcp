@preconcurrency import Foundation
import XCTest

@testable import MCP
@testable import MCPOAuth

private actor OAuthConceptTransport: MCPOAuthHTTPTransport {
  private var responses: [String: [MCPOAuthHTTPResponse]]
  private var requests: [MCPOAuthHTTPRequest] = []

  init(responses: [String: [MCPOAuthHTTPResponse]]) {
    self.responses = responses
  }

  func send(_ request: MCPOAuthHTTPRequest) async throws -> MCPOAuthHTTPResponse {
    requests.append(request)
    let key = "\(request.method) \(request.url.absoluteString)"
    guard var queue = responses[key], !queue.isEmpty else {
      throw MCPOAuthError.transport("unexpected request \(key)")
    }
    let response = queue.removeFirst()
    responses[key] = queue
    return response
  }

  func capturedURLs() -> [URL] { requests.map(\.url) }
  func capturedRequests() -> [MCPOAuthHTTPRequest] { requests }
}

final class MCPOAuthProtocolConceptTests: XCTestCase {
  private let resource = URL(string: "http://127.0.0.1:9000/mcp")!
  private let issuer = URL(string: "https://127.0.0.1:9001/issuer")!
  private let redirect = URL(string: "http://127.0.0.1:7777/callback")!
  private let tokenEndpoint = URL(string: "https://127.0.0.1:9001/token")!

  private func response(
    _ body: String,
    status: Int = 200,
    contentType: String = "application/json"
  ) -> MCPOAuthHTTPResponse {
    MCPOAuthHTTPResponse(
      status: status,
      headers: ["content-type": contentType],
      body: Data(body.utf8)
    )
  }

  private func registration(issuer: URL? = nil) throws -> MCPOAuthClientRegistration {
    .preRegistered(
      try MCPPreRegisteredOAuthClient(
        issuer: issuer ?? self.issuer,
        clientID: "desktop-client",
        redirectURIs: [redirect]
      )
    )
  }

  private func resourceMetadata(
    authorizationServer: URL? = nil,
    contentType: String = "application/json"
  ) -> MCPOAuthHTTPResponse {
    response(
      """
      {"resource":"\(resource.absoluteString)","authorization_servers":["\((authorizationServer ?? issuer).absoluteString)"]}
      """,
      contentType: contentType
    )
  }

  private func authorizationMetadata(
    codeChallengeMethods: String = #"["S256"]"#,
    authorizationEndpoint: String = "https://127.0.0.1:9001/authorize",
    contentType: String = "application/json"
  ) -> MCPOAuthHTTPResponse {
    response(
      """
      {"issuer":"\(issuer.absoluteString)","authorization_endpoint":"\(authorizationEndpoint)","token_endpoint":"https://127.0.0.1:9001/token","code_challenge_methods_supported":\(codeChallengeMethods)}
      """,
      contentType: contentType
    )
  }

  private func callback(
    pending: MCPOAuthPendingAuthorization,
    items: [URLQueryItem]
  ) -> URL {
    var components = URLComponents(url: pending.redirectURI, resolvingAgainstBaseURL: false)!
    components.queryItems = (components.queryItems ?? []) + items
    return components.url!
  }

  func testDiscoveryRejectsMetadataContentTypesThatOnlyPrefixMatchJSON() async throws {
    let metadataURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp")
    )
    let transport = OAuthConceptTransport(responses: [
      "GET \(metadataURL.absoluteString)": [
        MCPOAuthHTTPResponse(
          status: 200,
          headers: ["content-type": "application/json-seq"],
          body: Data("{}".utf8)
        )
      ]
    ])
    let client = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: transport
    )

    do {
      _ = try await client.discover()
      XCTFail("metadata media types must be application/json, not a prefix match")
    } catch {
      XCTAssertEqual(
        error as? MCPOAuthError,
        .invalidMetadata("metadata content type must be application/json")
      )
    }
  }

  func testDiscoveryRequiresMetadataContentTypeAndAcceptsJSONParameters() async throws {
    let resourceMetadataURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp")
    )
    let authorizationMetadataURL = try XCTUnwrap(
      URL(string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer")
    )

    let missingContentTypeTransport = OAuthConceptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [
        MCPOAuthHTTPResponse(status: 200, body: resourceMetadata().body)
      ]
    ])
    let missingContentTypeClient = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: missingContentTypeTransport
    )
    do {
      _ = try await missingContentTypeClient.discover()
      XCTFail("successful metadata responses without Content-Type must be rejected")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(error, .invalidMetadata("metadata content type must be application/json"))
    }

    let parameterizedTransport = OAuthConceptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [
        resourceMetadata(contentType: "application/json;charset=utf-8")
      ],
      "GET \(authorizationMetadataURL.absoluteString)": [
        authorizationMetadata(contentType: "application/json; charset=utf-8")
      ],
    ])
    let parameterizedClient = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: parameterizedTransport
    )
    let discovery = try await parameterizedClient.discover()
    XCTAssertEqual(discovery.metadataURL, resourceMetadataURL)
    XCTAssertEqual(discovery.authorizationServer.issuer, issuer)
  }

  func testDiscoveryFallsBackOnlyAfterPathSpecificMetadataIsNotFound() async throws {
    let pathSpecific = URL(
      string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp"
    )!
    let root = URL(string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource")!
    let issuerMetadata = URL(
      string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer"
    )!
    let openIDMetadata = URL(
      string: "https://127.0.0.1:9001/.well-known/openid-configuration/issuer"
    )!
    let transport = OAuthConceptTransport(responses: [
      "GET \(pathSpecific.absoluteString)": [response("{}", status: 404)],
      "GET \(root.absoluteString)": [resourceMetadata()],
      "GET \(issuerMetadata.absoluteString)": [response("{}", status: 404)],
      "GET \(openIDMetadata.absoluteString)": [authorizationMetadata()],
    ])
    let client = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: transport
    )

    let discovery = try await client.discover()
    XCTAssertEqual(discovery.metadataURL, root)
    XCTAssertEqual(discovery.authorizationServer.issuer, issuer)
    let requestedURLs = await transport.capturedURLs()
    XCTAssertEqual(
      requestedURLs,
      [pathSpecific, root, issuerMetadata, openIDMetadata]
    )
  }

  func testDiscoveryUsesBearerChallengeMetadataURLBeforeWellKnownCandidates() async throws {
    let challengeMetadata = URL(string: "http://127.0.0.1:9000/metadata-from-challenge")!
    let authorizationMetadataURL = URL(
      string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer"
    )!
    let transport = OAuthConceptTransport(responses: [
      "GET \(challengeMetadata.absoluteString)": [resourceMetadata()],
      "GET \(authorizationMetadataURL.absoluteString)": [authorizationMetadata()],
    ])
    let client = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: transport
    )

    let header =
      "Basic realm=\"legacy\", Bearer resource_metadata="
      + "\"http://127.0.0.1:9000/metadata-from-challenge\""
    let discovery = try await client.discover(
      challenge: try MCPOAuthChallenge(wwwAuthenticate: header)
    )
    XCTAssertEqual(discovery.metadataURL, challengeMetadata)
    let requestedURLs = await transport.capturedURLs()
    XCTAssertEqual(requestedURLs, [challengeMetadata, authorizationMetadataURL])
  }

  func testDiscoveryFallsBackToPathAppendingOpenIDMetadataForPathIssuer() async throws {
    let resourceMetadataURL = URL(
      string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp"
    )!
    let oauthPathInsertion = URL(
      string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer"
    )!
    let openIDPathInsertion = URL(
      string: "https://127.0.0.1:9001/.well-known/openid-configuration/issuer"
    )!
    let openIDPathAppending = URL(
      string: "https://127.0.0.1:9001/issuer/.well-known/openid-configuration"
    )!
    let transport = OAuthConceptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [resourceMetadata()],
      "GET \(oauthPathInsertion.absoluteString)": [response("{}", status: 404)],
      "GET \(openIDPathInsertion.absoluteString)": [response("{}", status: 404)],
      "GET \(openIDPathAppending.absoluteString)": [authorizationMetadata()],
    ])
    let client = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: transport
    )

    let discovery = try await client.discover()
    XCTAssertEqual(discovery.authorizationServer.issuer, issuer)
    let requestedURLs = await transport.capturedURLs()
    XCTAssertEqual(
      requestedURLs,
      [resourceMetadataURL, oauthPathInsertion, openIDPathInsertion, openIDPathAppending]
    )
  }

  func testDiscoveryRejectsMismatchedProtectedResourceAndAuthorizationIssuer() async throws {
    let resourceMetadataURL = URL(
      string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp"
    )!
    let wrongResource = URL(string: "http://127.0.0.1:9000/other")!
    let resourceMismatchTransport = OAuthConceptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [
        response(
          """
          {"resource":"\(wrongResource.absoluteString)","authorization_servers":["\(issuer.absoluteString)"]}
          """)
      ]
    ])
    let resourceMismatchClient = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: resourceMismatchTransport
    )
    do {
      _ = try await resourceMismatchClient.discover()
      XCTFail("protected-resource metadata must bind to the MCP resource")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(
        error,
        .resourceMismatch(
          expected: MCPProtectedResourceMetadata.canonicalResource(resource),
          actual: MCPProtectedResourceMetadata.canonicalResource(wrongResource)
        )
      )
    }
    let resourceMismatchURLs = await resourceMismatchTransport.capturedURLs()
    XCTAssertEqual(resourceMismatchURLs, [resourceMetadataURL])

    let authorizationMetadataURL = URL(
      string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer"
    )!
    let wrongIssuer = URL(string: "https://127.0.0.1:9001/other")!
    let issuerMismatchTransport = OAuthConceptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [resourceMetadata()],
      "GET \(authorizationMetadataURL.absoluteString)": [
        response(
          """
          {"issuer":"\(wrongIssuer.absoluteString)","authorization_endpoint":"https://127.0.0.1:9001/authorize","token_endpoint":"https://127.0.0.1:9001/token","code_challenge_methods_supported":["S256"]}
          """)
      ],
    ])
    let issuerMismatchClient = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: issuerMismatchTransport
    )
    do {
      _ = try await issuerMismatchClient.discover()
      XCTFail("authorization metadata must bind to the issuer used for discovery")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(
        error,
        .issuerMismatch(expected: issuer.absoluteString, actual: wrongIssuer.absoluteString)
      )
    }
  }

  func testDiscoveryFailsClosedInsteadOfTreatingServerFailureAsMetadataFallback() async throws {
    let pathSpecific = URL(
      string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp"
    )!
    let root = URL(string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource")!
    let transport = OAuthConceptTransport(responses: [
      "GET \(pathSpecific.absoluteString)": [response("{}", status: 500)],
      "GET \(root.absoluteString)": [resourceMetadata()],
    ])
    let client = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: transport
    )

    do {
      _ = try await client.discover()
      XCTFail("only a 404 can select the root protected-resource metadata fallback")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(error, .transport("metadata HTTP 500"))
    }
    let requestedURLs = await transport.capturedURLs()
    XCTAssertEqual(requestedURLs, [pathSpecific])
  }

  func testDiscoveryRejectsIssuerBindingAndMetadataWithoutS256OrHTTPS() async throws {
    let otherIssuer = URL(string: "https://127.0.0.1:9002/issuer")!
    let pathSpecific = URL(
      string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp"
    )!

    let bindingTransport = OAuthConceptTransport(responses: [
      "GET \(pathSpecific.absoluteString)": [resourceMetadata(authorizationServer: otherIssuer)]
    ])
    let bindingClient = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: bindingTransport
    )
    do {
      _ = try await bindingClient.discover()
      XCTFail("pre-registered credentials must not cross authorization-server issuers")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(
        error,
        .issuerMismatch(expected: issuer.absoluteString, actual: otherIssuer.absoluteString)
      )
    }

    let metadataURL = URL(
      string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer"
    )!
    let noPKCETransport = OAuthConceptTransport(responses: [
      "GET \(pathSpecific.absoluteString)": [resourceMetadata()],
      "GET \(metadataURL.absoluteString)": [
        authorizationMetadata(codeChallengeMethods: #"["plain"]"#)
      ],
    ])
    let noPKCEClient = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: noPKCETransport
    )
    do {
      _ = try await noPKCEClient.beginAuthorization(redirectURI: redirect)
      XCTFail("authorization must not proceed without PKCE S256 support")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(error, .pkceNotSupported)
    }

    let insecureTransport = OAuthConceptTransport(responses: [
      "GET \(pathSpecific.absoluteString)": [resourceMetadata()],
      "GET \(metadataURL.absoluteString)": [
        authorizationMetadata(authorizationEndpoint: "http://authorization.example/authorize")
      ],
    ])
    let insecureClient = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: insecureTransport
    )
    do {
      _ = try await insecureClient.beginAuthorization(redirectURI: redirect)
      XCTFail("non-loopback OAuth authorization endpoints must use HTTPS")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(error, .insecureURL("http://authorization.example/authorize"))
    }
  }

  func testAuthorizationDenialAndRequiredIssuerAreRejectedBeforeTokenExchange() async throws {
    let resourceMetadataURL = URL(
      string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp"
    )!
    let authorizationMetadataURL = URL(
      string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer"
    )!
    let metadataWithIssuerRequired = response(
      """
      {"issuer":"\(issuer.absoluteString)","authorization_endpoint":"https://127.0.0.1:9001/authorize","token_endpoint":"\(tokenEndpoint.absoluteString)","code_challenge_methods_supported":["S256"],"authorization_response_iss_parameter_supported":true}
      """
    )
    let transport = OAuthConceptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [resourceMetadata()],
      "GET \(authorizationMetadataURL.absoluteString)": [metadataWithIssuerRequired],
    ])
    let client = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: transport
    )
    let pending = try await client.beginAuthorization(redirectURI: redirect)

    do {
      _ = try await client.completeAuthorization(
        callbackURL: callback(
          pending: pending,
          items: [
            URLQueryItem(name: "code", value: "unused"),
            URLQueryItem(name: "state", value: pending.state),
          ]
        ),
        pending: pending
      )
      XCTFail("an issuer-supporting server requires iss in its authorization response")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(error, .authorizationResponseIssuerMissing)
    }

    let denialTransport = OAuthConceptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [resourceMetadata()],
      "GET \(authorizationMetadataURL.absoluteString)": [metadataWithIssuerRequired],
    ])
    let denialClient = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: denialTransport
    )
    let deniedPending = try await denialClient.beginAuthorization(redirectURI: redirect)
    do {
      _ = try await denialClient.completeAuthorization(
        callbackURL: callback(
          pending: deniedPending,
          items: [
            URLQueryItem(name: "error", value: "access_denied"),
            URLQueryItem(name: "error_description", value: "user declined"),
            URLQueryItem(name: "state", value: deniedPending.state),
            URLQueryItem(name: "iss", value: issuer.absoluteString),
          ]
        ),
        pending: deniedPending
      )
      XCTFail("authorization endpoint errors must not be exchanged as authorization codes")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(
        error, .authorizationDenied(code: "access_denied", description: "user declined"))
    }
    let denialRequests = await denialTransport.capturedRequests()
    XCTAssertFalse(denialRequests.contains { $0.method == "POST" })
  }

  func testBasicClientAuthenticationBindsRefreshAndPreservesRotatedTokenFallback() async throws {
    let resourceMetadataURL = URL(
      string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp"
    )!
    let authorizationMetadataURL = URL(
      string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer"
    )!
    let initial = response(
      #"{"access_token":"expired","token_type":"Bearer","expires_in":0,"refresh_token":"refresh-1"}"#
    )
    let refreshed = response(
      #"{"access_token":"fresh","token_type":"Bearer","expires_in":3600}"#
    )
    let transport = OAuthConceptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [resourceMetadata()],
      "GET \(authorizationMetadataURL.absoluteString)": [authorizationMetadata()],
      "POST \(tokenEndpoint.absoluteString)": [initial, refreshed],
    ])
    let clientRegistration = MCPOAuthClientRegistration.preRegistered(
      try MCPPreRegisteredOAuthClient(
        issuer: issuer,
        clientID: "desktop-client",
        clientSecret: "secret",
        tokenEndpointAuthMethod: .clientSecretBasic,
        redirectURIs: [redirect]
      )
    )
    let store = MCPMemoryCredentialStore()
    let client = try MCPOAuthClient(
      resource: resource,
      registration: clientRegistration,
      store: store,
      http: transport,
      refreshLeeway: 0,
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    let pending = try await client.beginAuthorization(redirectURI: redirect)
    _ = try await client.completeAuthorization(
      callbackURL: callback(
        pending: pending,
        items: [
          URLQueryItem(name: "code", value: "authorization-code"),
          URLQueryItem(name: "state", value: pending.state),
          URLQueryItem(name: "iss", value: issuer.absoluteString),
        ]
      ),
      pending: pending
    )

    let authorizationHeader = try await client.authorizationHeader(for: resource)
    XCTAssertEqual(authorizationHeader, "Bearer fresh")
    let requests = await transport.capturedRequests().filter { $0.method == "POST" }
    XCTAssertEqual(requests.count, 2)
    let expectedAuthorization = "Basic " + Data("desktop-client:secret".utf8).base64EncodedString()
    XCTAssertEqual(
      requests.map { $0.headers["authorization"] }, [expectedAuthorization, expectedAuthorization])
    let requestBodies = requests.compactMap { $0.body.map { String(decoding: $0, as: UTF8.self) } }
    XCTAssertTrue(requestBodies.allSatisfy { !$0.contains("client_id=") })
    XCTAssertTrue(
      requestBodies.allSatisfy { $0.contains("resource=http%3A%2F%2F127.0.0.1%3A9000%2Fmcp") })
    let refreshBody = try XCTUnwrap(requestBodies.dropFirst().first)
    XCTAssertTrue(refreshBody.contains("refresh_token=refresh-1"))

    let key = MCPOAuthCredentialKey(
      resource: resource,
      issuer: issuer,
      clientID: "desktop-client"
    )
    let storedToken = await store.load(for: key)
    let persisted = try XCTUnwrap(storedToken)
    XCTAssertEqual(persisted.refreshToken, "refresh-1")
  }

  func testTokenResponseValidationRejectsMalformedCredentialsAndResourceMismatches() async throws {
    let resourceMetadataURL = URL(
      string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp"
    )!
    let authorizationMetadataURL = URL(
      string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer"
    )!
    let transport = OAuthConceptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [
        resourceMetadata(), resourceMetadata(), resourceMetadata(),
      ],
      "GET \(authorizationMetadataURL.absoluteString)": [
        authorizationMetadata(), authorizationMetadata(), authorizationMetadata(),
      ],
      "POST \(tokenEndpoint.absoluteString)": [
        response("not-json"),
        response(#"{"access_token":"token","token_type":"MAC"}"#),
        response(#"{"access_token":"token","token_type":"Bearer","expires_in":-1}"#),
      ],
    ])
    let client = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: MCPMemoryCredentialStore(),
      http: transport
    )
    let expectedErrors: [MCPOAuthError] = [
      .invalidTokenResponse("body is not JSON"),
      .invalidTokenResponse("access_token and Bearer token_type are required"),
      .invalidTokenResponse("expires_in is negative"),
    ]

    for expected in expectedErrors {
      let pending = try await client.beginAuthorization(redirectURI: redirect)
      do {
        _ = try await client.completeAuthorization(
          callbackURL: callback(
            pending: pending,
            items: [
              URLQueryItem(name: "code", value: "authorization-code"),
              URLQueryItem(name: "state", value: pending.state),
              URLQueryItem(name: "iss", value: issuer.absoluteString),
            ]
          ),
          pending: pending
        )
        XCTFail("malformed token responses must not be persisted or used")
      } catch let error as MCPOAuthError {
        XCTAssertEqual(error, expected)
      }
    }

    let otherResource = URL(string: "http://127.0.0.1:9000/other")!
    do {
      _ = try await client.authorizationHeader(for: otherResource)
      XCTFail("a resource-bound token provider must not disclose a token to another resource")
    } catch let error as MCPOAuthError {
      XCTAssertEqual(
        error,
        .resourceMismatch(
          expected: MCPProtectedResourceMetadata.canonicalResource(resource),
          actual: MCPProtectedResourceMetadata.canonicalResource(otherResource)
        )
      )
    }
  }

  func testSuccessfulTokenResponsesRequireJSONContentTypeBeforeCredentialStorage() async throws {
    let resourceMetadataURL = URL(
      string: "http://127.0.0.1:9000/.well-known/oauth-protected-resource/mcp"
    )!
    let authorizationMetadataURL = URL(
      string: "https://127.0.0.1:9001/.well-known/oauth-authorization-server/issuer"
    )!
    let validToken = Data(
      #"{"access_token":"access-token","token_type":"Bearer","expires_in":3600}"#.utf8
    )
    let transport = OAuthConceptTransport(responses: [
      "GET \(resourceMetadataURL.absoluteString)": [resourceMetadata(), resourceMetadata()],
      "GET \(authorizationMetadataURL.absoluteString)": [
        authorizationMetadata(), authorizationMetadata(),
      ],
      "POST \(tokenEndpoint.absoluteString)": [
        MCPOAuthHTTPResponse(status: 200, body: validToken),
        MCPOAuthHTTPResponse(
          status: 200,
          headers: ["content-type": "text/plain"],
          body: validToken
        ),
      ],
    ])
    let store = MCPMemoryCredentialStore()
    let client = try MCPOAuthClient(
      resource: resource,
      registration: registration(),
      store: store,
      http: transport
    )

    for _ in 0..<2 {
      let pending = try await client.beginAuthorization(redirectURI: redirect)
      do {
        _ = try await client.completeAuthorization(
          callbackURL: callback(
            pending: pending,
            items: [
              URLQueryItem(name: "code", value: "authorization-code"),
              URLQueryItem(name: "state", value: pending.state),
              URLQueryItem(name: "iss", value: issuer.absoluteString),
            ]
          ),
          pending: pending
        )
        XCTFail("OAuth must fail closed when a successful token response is not JSON")
      } catch let error as MCPOAuthError {
        XCTAssertEqual(error, .invalidTokenResponse("token content type must be application/json"))
      }
    }

    let key = MCPOAuthCredentialKey(
      resource: resource,
      issuer: issuer,
      clientID: "desktop-client"
    )
    let storedToken = await store.load(for: key)
    XCTAssertNil(storedToken)
  }
}
