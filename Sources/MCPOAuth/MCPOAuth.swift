@preconcurrency import Foundation
import MCP
import MCPHTTPClient
import MCPHTTPShared
import MCPPlatformCrypto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum MCPOAuthError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidURL(String)
  case insecureURL(String)
  case metadataNotFound
  case invalidMetadata(String)
  case issuerMismatch(expected: String, actual: String)
  case resourceMismatch(expected: String, actual: String)
  case multipleAuthorizationServers([String])
  case authorizationServerNotAdvertised(String)
  case pkceNotSupported
  case registrationNotSupported
  case redirectURINotRegistered(String)
  case stateMismatch
  case authorizationStateNotPending
  case missingAuthorizationCode
  case authorizationResponseIssuerMissing
  case authorizationResponseIssuerMismatch(expected: String, actual: String)
  case authorizationDenied(code: String, description: String?)
  case pendingAuthorizationLimitExceeded(Int)
  case tokenEndpointFailure(status: Int, code: String?, description: String?)
  case invalidTokenResponse(String)
  case noCredentials
  case noRefreshToken
  case invalidGrantCredentialRemovalFailed(String)
  case responseTooLarge(Int)
  case unexpectedRedirect(URL)
  case transport(String)
  case randomGenerationFailed
  case digestFailed

  public var description: String {
    switch self {
    case .invalidURL(let value): "Invalid OAuth URL: \(value)"
    case .insecureURL(let value): "OAuth URL must use HTTPS or loopback HTTP: \(value)"
    case .metadataNotFound: "OAuth metadata was not found"
    case .invalidMetadata(let reason): "Invalid OAuth metadata: \(reason)"
    case .issuerMismatch(let expected, let actual):
      "OAuth issuer mismatch: expected \(expected), got \(actual)"
    case .resourceMismatch(let expected, let actual):
      "OAuth resource mismatch: expected \(expected), got \(actual)"
    case .multipleAuthorizationServers(let values):
      "Protected resource advertises multiple authorization servers: \(values.joined(separator: ", "))"
    case .authorizationServerNotAdvertised(let value):
      "Selected authorization server is not advertised: \(value)"
    case .pkceNotSupported: "Authorization server does not advertise PKCE S256"
    case .registrationNotSupported: "Configured OAuth client registration is not supported"
    case .redirectURINotRegistered(let value): "Redirect URI is not registered: \(value)"
    case .stateMismatch: "OAuth authorization response state mismatch"
    case .authorizationStateNotPending:
      "OAuth authorization state is not pending or was already consumed"
    case .missingAuthorizationCode: "OAuth authorization response is missing code"
    case .authorizationResponseIssuerMissing: "OAuth authorization response is missing required iss"
    case .authorizationResponseIssuerMismatch(let expected, let actual):
      "OAuth authorization response issuer mismatch: expected \(expected), got \(actual)"
    case .authorizationDenied(let code, let description):
      "OAuth authorization failed: \(code)\(description.map { " (\($0))" } ?? "")"
    case .pendingAuthorizationLimitExceeded(let limit):
      "OAuth pending authorization limit of \(limit) was reached"
    case .tokenEndpointFailure(let status, let code, let description):
      "OAuth token endpoint failed with HTTP \(status): \(code ?? "unknown")\(description.map { " (\($0))" } ?? "")"
    case .invalidTokenResponse(let reason): "Invalid OAuth token response: \(reason)"
    case .noCredentials: "No OAuth credentials are available"
    case .noRefreshToken: "No OAuth refresh token is available"
    case .invalidGrantCredentialRemovalFailed(let reason):
      "OAuth refresh was rejected with invalid_grant and persisted credential removal failed: \(reason)"
    case .responseTooLarge(let limit): "OAuth response exceeds \(limit) bytes"
    case .unexpectedRedirect(let url):
      "OAuth metadata/token request redirected to \(url.absoluteString)"
    case .transport(let reason): "OAuth transport error: \(reason)"
    case .randomGenerationFailed: "Secure random generation failed"
    case .digestFailed: "SHA-256 digest failed"
    }
  }
}

public struct MCPOAuthURLPolicy: Sendable, Hashable {
  public let allowLoopbackHTTP: Bool
  public let allowedHosts: Set<String>?

  public init(allowLoopbackHTTP: Bool = true, allowedHosts: Set<String>? = nil) {
    self.allowLoopbackHTTP = allowLoopbackHTTP
    self.allowedHosts = allowedHosts.map { Set($0.map { $0.lowercased() }) }
  }

  public func validate(_ url: URL, purpose: String) throws {
    let (scheme, host) = try validatedAuthority(url, purpose: purpose)
    if scheme == "https" { return }
    if scheme == "http", allowLoopbackHTTP, Self.isLoopback(host) { return }
    throw MCPOAuthError.insecureURL(url.absoluteString)
  }

  fileprivate func validateAuthorizationServer(_ url: URL, purpose: String) throws {
    let (scheme, _) = try validatedAuthority(url, purpose: purpose)
    guard scheme == "https" else { throw MCPOAuthError.insecureURL(url.absoluteString) }
  }

  private func validatedAuthority(_ url: URL, purpose: String) throws -> (String, String) {
    guard url.user == nil, url.password == nil, url.fragment == nil,
      let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty
    else { throw MCPOAuthError.invalidURL("\(purpose): \(url.absoluteString)") }
    if let allowedHosts, !allowedHosts.contains(host) {
      throw MCPOAuthError.invalidURL("\(purpose) host is not allowed: \(host)")
    }
    return (scheme, host)
  }

  public static func isLoopback(_ host: String) -> Bool {
    let value = host.lowercased()
    if value == "localhost" || value == "::1" || value == "[::1]" { return true }
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 4 else { return false }
    let octets = components.compactMap { component -> UInt8? in
      guard !component.isEmpty,
        component.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
        let value = UInt8(component)
      else { return nil }
      return value
    }
    return octets.count == 4 && octets[0] == 127
  }
}

public struct MCPOAuthChallenge: Sendable, Hashable {
  public let resourceMetadataURL: URL?
  public let scopes: [String]

  public init(resourceMetadataURL: URL? = nil, scopes: [String] = []) {
    self.resourceMetadataURL = resourceMetadataURL
    self.scopes = scopes
  }

  public init(wwwAuthenticate: String) throws {
    let parameters = try Self.bearerParameters(in: wwwAuthenticate)
    if let raw = parameters["resource_metadata"] {
      guard let url = URL(string: raw) else { throw MCPOAuthError.invalidURL(raw) }
      resourceMetadataURL = url
    } else {
      resourceMetadataURL = nil
    }
    scopes =
      parameters["scope"]?.split(whereSeparator: \Character.isWhitespace).map(String.init) ?? []
  }

  /// Extracts the Bearer challenge from an HTTP transport response without deciding whether to
  /// retry the originating MCP request.
  public init(unauthorizedResponse: MCPHTTPUnauthorizedResponse) throws {
    guard let wwwAuthenticate = unauthorizedResponse.wwwAuthenticate else {
      throw MCPOAuthError.invalidMetadata("HTTP 401 response is missing WWW-Authenticate")
    }
    try self.init(wwwAuthenticate: wwwAuthenticate)
  }

  /// Extracts an HTTP Bearer challenge preserved by the high-level stateless MCP client.
  public init(clientError: MCPClientError) throws {
    guard case .transportFailure(let failure) = clientError,
      let response = failure as? MCPHTTPUnauthorizedResponse
    else {
      throw MCPOAuthError.invalidMetadata("MCP client error is not an HTTP 401 response")
    }
    try self.init(unauthorizedResponse: response)
  }

  private static func bearerParameters(in header: String) throws -> [String: String] {
    guard let start = bearerParameterStart(in: header) else {
      throw MCPOAuthError.invalidMetadata("WWW-Authenticate is not a Bearer challenge")
    }
    let end = bearerParameterEnd(in: header, startingAt: start)
    return try parseParameters(String(header[start..<end]))
  }

  /// Finds Bearer only at an auth-scheme boundary (the header start or an unquoted comma). A
  /// Bearer-looking string inside a quoted realm or an auth-param name is not a challenge.
  private static func bearerParameterStart(in header: String) -> String.Index? {
    var index = header.startIndex
    var quoted = false
    var escaped = false
    var atBoundary = true
    while index < header.endIndex {
      if atBoundary {
        var candidate = index
        skipWhitespace(in: header, index: &candidate)
        let schemeStart = candidate
        while candidate < header.endIndex, isTokenCharacter(header[candidate]) {
          candidate = header.index(after: candidate)
        }
        if schemeStart != candidate,
          header[schemeStart..<candidate].caseInsensitiveCompare("Bearer") == .orderedSame,
          candidate == header.endIndex || header[candidate].isWhitespace || header[candidate] == ","
        {
          return candidate
        }
        atBoundary = false
      }

      let character = header[index]
      if quoted {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          quoted = false
        }
      } else if character == "\"" {
        quoted = true
      } else if character == "," {
        atBoundary = true
      }
      index = header.index(after: index)
    }
    return nil
  }

  /// Limits parsing to the selected Bearer challenge, stopping at a comma that introduces another
  /// auth scheme. Commas followed by `name=` remain part of the Bearer auth-param list.
  private static func bearerParameterEnd(
    in header: String,
    startingAt start: String.Index
  ) -> String.Index {
    var index = start
    var quoted = false
    var escaped = false
    while index < header.endIndex {
      let character = header[index]
      if quoted {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          quoted = false
        }
      } else if character == "\"" {
        quoted = true
      } else if character == "," {
        var candidate = header.index(after: index)
        skipWhitespace(in: header, index: &candidate)
        let schemeStart = candidate
        while candidate < header.endIndex, isTokenCharacter(header[candidate]) {
          candidate = header.index(after: candidate)
        }
        if schemeStart != candidate,
          candidate == header.endIndex || header[candidate].isWhitespace
        {
          return index
        }
      }
      index = header.index(after: index)
    }
    return header.endIndex
  }

  private static func parseParameters(_ input: String) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = input.startIndex
    skipWhitespace(in: input, index: &index)
    while index < input.endIndex {
      let nameStart = index
      while index < input.endIndex, isTokenCharacter(input[index]) {
        index = input.index(after: index)
      }
      guard nameStart != index, index < input.endIndex, input[index] == "=" else {
        throw MCPOAuthError.invalidMetadata("malformed WWW-Authenticate parameter")
      }
      let name = input[nameStart..<index].lowercased()
      index = input.index(after: index)
      skipWhitespace(in: input, index: &index)
      let value: String
      if index < input.endIndex, input[index] == "\"" {
        index = input.index(after: index)
        var output = ""
        var closed = false
        while index < input.endIndex {
          let character = input[index]
          index = input.index(after: index)
          if character == "\"" {
            closed = true
            break
          }
          if character == "\\" {
            guard index < input.endIndex else {
              throw MCPOAuthError.invalidMetadata("malformed quoted challenge value")
            }
            output.append(input[index])
            index = input.index(after: index)
          } else {
            output.append(character)
          }
        }
        guard closed else { throw MCPOAuthError.invalidMetadata("unterminated challenge value") }
        value = output
      } else {
        let valueStart = index
        while index < input.endIndex, isTokenCharacter(input[index]) {
          index = input.index(after: index)
        }
        guard valueStart != index else {
          throw MCPOAuthError.invalidMetadata("malformed WWW-Authenticate parameter")
        }
        value = String(input[valueStart..<index])
      }
      guard !value.isEmpty, result[name] == nil else {
        throw MCPOAuthError.invalidMetadata("duplicate or empty challenge parameter")
      }
      result[name] = value
      skipWhitespace(in: input, index: &index)
      guard index == input.endIndex || input[index] == "," else {
        throw MCPOAuthError.invalidMetadata("malformed WWW-Authenticate parameter")
      }
      guard index < input.endIndex else { break }
      index = input.index(after: index)
      skipWhitespace(in: input, index: &index)
      guard index < input.endIndex else {
        throw MCPOAuthError.invalidMetadata("malformed WWW-Authenticate parameter")
      }
    }
    return result
  }

  private static func skipWhitespace(in input: String, index: inout String.Index) {
    while index < input.endIndex, input[index].isWhitespace {
      index = input.index(after: index)
    }
  }

  private static func isTokenCharacter(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
      return false
    }
    switch scalar.value {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
      0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E...0x60, 0x7C, 0x7E:
      return true
    default:
      return false
    }
  }
}

public struct MCPProtectedResourceMetadata: Sendable, Hashable {
  public let resource: URL
  public let authorizationServers: [URL]
  public let scopesSupported: [String]
  public let bearerMethodsSupported: [String]

  public init(json: MCPJSONValue, expectedResource: URL, urlPolicy: MCPOAuthURLPolicy) throws {
    let object = try MCPJSONObject(json)
    let resourceText = try object.requiredString("resource")
    guard let resource = URL(string: resourceText) else {
      throw MCPOAuthError.invalidURL(resourceText)
    }
    try urlPolicy.validate(resource, purpose: "protected resource")
    guard Self.canonicalResource(resource) == Self.canonicalResource(expectedResource) else {
      throw MCPOAuthError.resourceMismatch(
        expected: Self.canonicalResource(expectedResource), actual: Self.canonicalResource(resource)
      )
    }
    let serverValues = try object.requiredArray("authorization_servers")
    guard !serverValues.isEmpty else {
      throw MCPOAuthError.invalidMetadata("authorization_servers must not be empty")
    }
    var servers: [URL] = []
    var seen = Set<String>()
    for value in serverValues {
      guard case .string(let text) = value, let url = URL(string: text) else {
        throw MCPOAuthError.invalidMetadata("authorization_servers must contain URLs")
      }
      try urlPolicy.validateAuthorizationServer(url, purpose: "authorization server")
      guard seen.insert(url.absoluteString).inserted else {
        throw MCPOAuthError.invalidMetadata("duplicate authorization server")
      }
      servers.append(url)
    }
    self.resource = resource
    authorizationServers = servers
    scopesSupported = try Self.stringArray(
      object.values["scopes_supported"], field: "scopes_supported")
    bearerMethodsSupported = try Self.stringArray(
      object.values["bearer_methods_supported"], field: "bearer_methods_supported")
  }

  public static func canonicalResource(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    components.fragment = nil
    return components.string ?? url.absoluteString
  }

  fileprivate static func stringArray(_ value: MCPJSONValue?, field: String) throws -> [String] {
    guard let value else { return [] }
    guard case .array(let values) = value else {
      throw MCPOAuthError.invalidMetadata("\(field) must be an array")
    }
    return try values.map {
      guard case .string(let text) = $0, !text.isEmpty else {
        throw MCPOAuthError.invalidMetadata("\(field) must contain non-empty strings")
      }
      return text
    }
  }
}

public struct MCPAuthorizationServerMetadata: Sendable, Hashable {
  public let issuer: URL
  public let authorizationEndpoint: URL
  public let tokenEndpoint: URL
  public let codeChallengeMethodsSupported: Set<String>
  public let authorizationResponseIssuerParameterSupported: Bool
  public let clientIDMetadataDocumentSupported: Bool
  public let scopesSupported: [String]

  public init(json: MCPJSONValue, expectedIssuer: URL, urlPolicy: MCPOAuthURLPolicy) throws {
    let object = try MCPJSONObject(json)
    let issuerText = try object.requiredString("issuer")
    guard let issuer = URL(string: issuerText) else { throw MCPOAuthError.invalidURL(issuerText) }
    try urlPolicy.validateAuthorizationServer(issuer, purpose: "issuer")
    guard issuer.absoluteString == expectedIssuer.absoluteString else {
      throw MCPOAuthError.issuerMismatch(
        expected: expectedIssuer.absoluteString, actual: issuer.absoluteString)
    }
    let authorizationText = try object.requiredString("authorization_endpoint")
    let tokenText = try object.requiredString("token_endpoint")
    guard let authorizationEndpoint = URL(string: authorizationText),
      let tokenEndpoint = URL(string: tokenText)
    else { throw MCPOAuthError.invalidMetadata("invalid authorization or token endpoint") }
    try urlPolicy.validateAuthorizationServer(
      authorizationEndpoint, purpose: "authorization endpoint")
    try urlPolicy.validateAuthorizationServer(tokenEndpoint, purpose: "token endpoint")
    let methods = Set(
      try MCPProtectedResourceMetadata.stringArray(
        object.values["code_challenge_methods_supported"],
        field: "code_challenge_methods_supported"))
    guard methods.contains("S256") else { throw MCPOAuthError.pkceNotSupported }
    self.issuer = issuer
    self.authorizationEndpoint = authorizationEndpoint
    self.tokenEndpoint = tokenEndpoint
    codeChallengeMethodsSupported = methods
    authorizationResponseIssuerParameterSupported =
      try object.optionalBool(
        "authorization_response_iss_parameter_supported") ?? false
    clientIDMetadataDocumentSupported =
      try object.optionalBool(
        "client_id_metadata_document_supported") ?? false
    scopesSupported = try MCPProtectedResourceMetadata.stringArray(
      object.values["scopes_supported"], field: "scopes_supported")
  }
}

public enum MCPOAuthTokenEndpointAuthMethod: String, Sendable, Hashable {
  case none
  case clientSecretBasic = "client_secret_basic"
  case clientSecretPost = "client_secret_post"
}

public struct MCPPreRegisteredOAuthClient: Sendable, Hashable {
  public let issuer: URL
  public let clientID: String
  public let clientSecret: String?
  public let tokenEndpointAuthMethod: MCPOAuthTokenEndpointAuthMethod
  public let redirectURIs: [URL]

  public init(
    issuer: URL,
    clientID: String,
    clientSecret: String? = nil,
    tokenEndpointAuthMethod: MCPOAuthTokenEndpointAuthMethod = .none,
    redirectURIs: [URL],
    urlPolicy: MCPOAuthURLPolicy = MCPOAuthURLPolicy()
  ) throws {
    guard !clientID.isEmpty, !redirectURIs.isEmpty else {
      throw MCPOAuthError.invalidMetadata("clientID and redirectURIs are required")
    }
    try urlPolicy.validateAuthorizationServer(issuer, purpose: "pre-registered client issuer")
    var seenRedirects = Set<String>()
    for redirect in redirectURIs {
      try MCPClientIDMetadataDocument.validateRedirectURI(redirect)
      guard seenRedirects.insert(redirect.absoluteString).inserted else {
        throw MCPOAuthError.invalidMetadata("duplicate redirect URI")
      }
    }
    switch tokenEndpointAuthMethod {
    case .none:
      guard clientSecret == nil else {
        throw MCPOAuthError.invalidMetadata(
          "client secret must not be supplied for auth method none")
      }
    case .clientSecretBasic, .clientSecretPost:
      guard clientSecret?.isEmpty == false else {
        throw MCPOAuthError.invalidMetadata("client secret is required for selected auth method")
      }
    }
    self.issuer = issuer
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
    self.redirectURIs = redirectURIs
  }
}

public struct MCPClientIDMetadataDocument: Sendable, Hashable, MCPJSONModel {
  public let clientID: URL
  public let clientName: String
  public let redirectURIs: [URL]
  public let clientURI: URL?
  public let tokenEndpointAuthMethod: MCPOAuthTokenEndpointAuthMethod

  public init(
    clientID: URL,
    clientName: String,
    redirectURIs: [URL],
    clientURI: URL? = nil,
    tokenEndpointAuthMethod: MCPOAuthTokenEndpointAuthMethod = .none,
    urlPolicy: MCPOAuthURLPolicy = MCPOAuthURLPolicy()
  ) throws {
    try urlPolicy.validate(clientID, purpose: "client metadata document")
    guard clientID.scheme?.lowercased() == "https", !clientID.path.isEmpty, clientID.path != "/"
    else {
      throw MCPOAuthError.invalidMetadata("CIMD client_id must be an HTTPS URL with a path")
    }
    guard !clientName.isEmpty, !redirectURIs.isEmpty else {
      throw MCPOAuthError.invalidMetadata("CIMD client_name and redirect_uris are required")
    }
    guard tokenEndpointAuthMethod == .none else {
      throw MCPOAuthError.invalidMetadata(
        "CIMD supports token_endpoint_auth_method none in this strict SDK")
    }
    var seenRedirects = Set<String>()
    for redirect in redirectURIs {
      try Self.validateRedirectURI(redirect)
      guard seenRedirects.insert(redirect.absoluteString).inserted else {
        throw MCPOAuthError.invalidMetadata("duplicate redirect URI")
      }
    }
    if let clientURI { try urlPolicy.validate(clientURI, purpose: "client URI") }
    self.clientID = clientID
    self.clientName = clientName
    self.redirectURIs = redirectURIs
    self.clientURI = clientURI
    self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let clientIDText = try object.requiredString("client_id")
    guard let clientID = URL(string: clientIDText) else {
      throw MCPOAuthError.invalidURL(clientIDText)
    }
    let redirects = try object.requiredArray("redirect_uris").map { value -> URL in
      guard case .string(let text) = value, let url = URL(string: text) else {
        throw MCPOAuthError.invalidMetadata("redirect_uris must contain URLs")
      }
      return url
    }
    let clientURI: URL?
    if let text = try object.optionalString("client_uri") {
      guard let value = URL(string: text) else { throw MCPOAuthError.invalidURL(text) }
      clientURI = value
    } else {
      clientURI = nil
    }
    let methodText = try object.optionalString("token_endpoint_auth_method") ?? "none"
    guard let method = MCPOAuthTokenEndpointAuthMethod(rawValue: methodText) else {
      throw MCPOAuthError.invalidMetadata("unsupported token_endpoint_auth_method")
    }
    try self.init(
      clientID: clientID,
      clientName: try object.requiredNonEmptyString("client_name"),
      redirectURIs: redirects,
      clientURI: clientURI,
      tokenEndpointAuthMethod: method
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("client_id", .string(clientID.absoluteString)),
      ("client_name", .string(clientName)),
      ("client_uri", clientURI.map { .string($0.absoluteString) }),
      ("redirect_uris", .array(redirectURIs.map { .string($0.absoluteString) })),
      ("grant_types", .array([.string("authorization_code"), .string("refresh_token")])),
      ("response_types", .array([.string("code")])),
      ("token_endpoint_auth_method", .string(tokenEndpointAuthMethod.rawValue)),
    ])
  }

  fileprivate static func validateRedirectURI(_ url: URL) throws {
    guard url.fragment == nil, url.user == nil, url.password == nil,
      let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
    else { throw MCPOAuthError.invalidURL(url.absoluteString) }
    guard scheme == "https" || (scheme == "http" && MCPOAuthURLPolicy.isLoopback(host)) else {
      throw MCPOAuthError.insecureURL(url.absoluteString)
    }
  }
}

public enum MCPOAuthClientRegistration: Sendable, Hashable {
  case preRegistered(MCPPreRegisteredOAuthClient)
  case clientMetadataDocument(MCPClientIDMetadataDocument)

  fileprivate var clientID: String {
    switch self {
    case .preRegistered(let value): value.clientID
    case .clientMetadataDocument(let value): value.clientID.absoluteString
    }
  }

  fileprivate var redirectURIs: [URL] {
    switch self {
    case .preRegistered(let value): value.redirectURIs
    case .clientMetadataDocument(let value): value.redirectURIs
    }
  }

  fileprivate var authMethod: MCPOAuthTokenEndpointAuthMethod {
    switch self {
    case .preRegistered(let value): value.tokenEndpointAuthMethod
    case .clientMetadataDocument(let value): value.tokenEndpointAuthMethod
    }
  }

  fileprivate var clientSecret: String? {
    switch self {
    case .preRegistered(let value): value.clientSecret
    case .clientMetadataDocument: nil
    }
  }
}

public struct MCPOAuthCredentialKey: Sendable, Hashable, Codable {
  public let resource: String
  public let issuer: String
  public let clientID: String

  public init(resource: URL, issuer: URL, clientID: String) {
    self.resource = MCPProtectedResourceMetadata.canonicalResource(resource)
    self.issuer = issuer.absoluteString
    self.clientID = clientID
  }
}

public struct MCPOAuthTokenSet: Sendable, Hashable, Codable {
  public let accessToken: String
  public let tokenType: String
  public let expiresAt: Date?
  public let refreshToken: String?
  public let scopes: [String]

  public init(
    accessToken: String,
    tokenType: String = "Bearer",
    expiresAt: Date? = nil,
    refreshToken: String? = nil,
    scopes: [String] = []
  ) throws {
    guard !accessToken.isEmpty, tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
      throw MCPOAuthError.invalidTokenResponse("access_token and Bearer token_type are required")
    }
    self.accessToken = accessToken
    self.tokenType = "Bearer"
    self.expiresAt = expiresAt
    self.refreshToken = refreshToken
    self.scopes = scopes
  }

  public func isUsable(at date: Date, leeway: TimeInterval) -> Bool {
    guard let expiresAt else { return true }
    return expiresAt.timeIntervalSince(date) > leeway
  }
}

public protocol MCPCredentialStore: Sendable {
  func load(for key: MCPOAuthCredentialKey) async throws -> MCPOAuthTokenSet?
  func save(_ token: MCPOAuthTokenSet, for key: MCPOAuthCredentialKey) async throws
  func remove(for key: MCPOAuthCredentialKey) async throws
}

public actor MCPMemoryCredentialStore: MCPCredentialStore {
  private var values: [MCPOAuthCredentialKey: MCPOAuthTokenSet] = [:]

  public init() {}
  public func load(for key: MCPOAuthCredentialKey) -> MCPOAuthTokenSet? { values[key] }
  public func save(_ token: MCPOAuthTokenSet, for key: MCPOAuthCredentialKey) {
    values[key] = token
  }
  public func remove(for key: MCPOAuthCredentialKey) { values.removeValue(forKey: key) }
}

public struct MCPOAuthHTTPRequest: Sendable {
  public let url: URL
  public let method: String
  public let headers: [String: String]
  public let body: Data?
  public let timeout: TimeInterval
  public let maximumResponseBytes: Int

  public init(
    url: URL,
    method: String = "GET",
    headers: [String: String] = [:],
    body: Data? = nil,
    timeout: TimeInterval = 15,
    maximumResponseBytes: Int = 1_048_576
  ) {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
    self.timeout = timeout
    self.maximumResponseBytes = maximumResponseBytes
  }
}

public struct MCPOAuthHTTPResponse: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data) {
    self.status = status
    self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    self.body = body
  }
}

public protocol MCPOAuthHTTPTransport: Sendable {
  func send(_ request: MCPOAuthHTTPRequest) async throws -> MCPOAuthHTTPResponse
}

// URLSession delegate callbacks may be concurrent. All mutable response state is protected by
// `lock`; oversized responses and redirects complete the caller exactly once and cancel the task.
private final class MCPOAuthResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable
{
  private let lock = NSLock()
  private let maximumResponseBytes: Int
  private var body = Data()
  private var response: HTTPURLResponse?
  private var task: URLSessionDataTask?
  private var continuation: CheckedContinuation<MCPOAuthHTTPResponse, Error>?
  private var completedResult: Result<MCPOAuthHTTPResponse, Error>?

  init(maximumResponseBytes: Int) {
    self.maximumResponseBytes = maximumResponseBytes
  }

  func install(task: URLSessionDataTask) {
    let shouldCancel = lock.withLock {
      self.task = task
      return completedResult != nil
    }
    if shouldCancel {
      task.cancel()
    } else {
      task.resume()
    }
  }

  func value() async throws -> MCPOAuthHTTPResponse {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let completed = lock.withLock { () -> Result<MCPOAuthHTTPResponse, Error>? in
          if let completedResult { return completedResult }
          self.continuation = continuation
          return nil
        }
        if let completed { continuation.resume(with: completed) }
      }
    } onCancel: {
      self.cancelByCaller()
    }
  }

  private func cancelByCaller() {
    let task = lock.withLock { self.task }
    finish(.failure(CancellationError()))
    task?.cancel()
  }

  private func finish(_ result: Result<MCPOAuthHTTPResponse, Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<MCPOAuthHTTPResponse, Error>? in
      guard completedResult == nil else { return nil }
      completedResult = result
      let value = self.continuation
      self.continuation = nil
      return value
    }
    continuation?.resume(with: result)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    if let redirect = request.url ?? response.url {
      finish(.failure(MCPOAuthError.unexpectedRedirect(redirect)))
    } else {
      finish(.failure(MCPOAuthError.transport("redirect response is missing a URL")))
    }
    completionHandler(nil)
    task.cancel()
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(.failure(MCPOAuthError.transport("response is not HTTP")))
      dataTask.cancel()
      return
    }
    if response.expectedContentLength > Int64(maximumResponseBytes) {
      completionHandler(.cancel)
      finish(.failure(MCPOAuthError.responseTooLarge(maximumResponseBytes)))
      dataTask.cancel()
      return
    }
    lock.withLock { self.response = http }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    let exceeded = lock.withLock { () -> Bool in
      guard completedResult == nil else { return false }
      guard data.count <= maximumResponseBytes - body.count else { return true }
      body.append(data)
      return false
    }
    if exceeded {
      finish(.failure(MCPOAuthError.responseTooLarge(maximumResponseBytes)))
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error {
      finish(.failure(MCPOAuthError.transport(error.localizedDescription)))
      return
    }
    let value = lock.withLock { () -> MCPOAuthHTTPResponse? in
      guard let response else { return nil }
      var headers: [String: String] = [:]
      for (name, value) in response.allHeaderFields {
        headers[String(describing: name)] = String(describing: value)
      }
      return MCPOAuthHTTPResponse(status: response.statusCode, headers: headers, body: body)
    }
    guard let value else {
      finish(.failure(MCPOAuthError.transport("response is not HTTP")))
      return
    }
    finish(.success(value))
  }
}

public struct MCPURLSessionOAuthTransport: MCPOAuthHTTPTransport, @unchecked Sendable {
  private let baseConfiguration: URLSessionConfiguration

  public init() {
    baseConfiguration = .ephemeral
  }

  init(configuration: URLSessionConfiguration) {
    baseConfiguration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
  }

  public func send(_ request: MCPOAuthHTTPRequest) async throws -> MCPOAuthHTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = request.timeout
    for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
    guard request.maximumResponseBytes >= 0 else {
      throw MCPOAuthError.responseTooLarge(request.maximumResponseBytes)
    }
    let configuration =
      baseConfiguration.copy() as? URLSessionConfiguration ?? URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = request.timeout
    configuration.timeoutIntervalForResource = request.timeout
    let delegate = MCPOAuthResponseDelegate(
      maximumResponseBytes: request.maximumResponseBytes)
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: urlRequest)
    delegate.install(task: task)
    do {
      return try await delegate.value()
    } catch let error as MCPOAuthError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw MCPOAuthError.transport(error.localizedDescription)
    }
  }
}

public protocol MCPOAuthRandomSource: Sendable {
  func bytes(count: Int) throws -> [UInt8]
}

public struct MCPSystemOAuthRandomSource: MCPOAuthRandomSource {
  public init() {}
  public func bytes(count: Int) throws -> [UInt8] {
    guard count > 0 else { return [] }
    var output = [UInt8](repeating: 0, count: count)
    guard mcp_secure_random(&output, output.count) == 0 else {
      throw MCPOAuthError.randomGenerationFailed
    }
    return output
  }
}

public struct MCPOAuthPKCE: Sendable, Hashable {
  public let verifier: String
  public let challenge: String

  public init(randomSource: any MCPOAuthRandomSource = MCPSystemOAuthRandomSource()) throws {
    let bytes = try randomSource.bytes(count: 64)
    verifier = Self.base64URL(bytes)
    guard (43...128).contains(verifier.count) else {
      throw MCPOAuthError.randomGenerationFailed
    }
    var digest = [UInt8](repeating: 0, count: 32)
    let input = Array(verifier.utf8)
    guard mcp_sha256(input, input.count, &digest) == 0 else { throw MCPOAuthError.digestFailed }
    challenge = Self.base64URL(digest)
  }

  private static func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

public struct MCPOAuthDiscovery: Sendable, Hashable {
  public let resourceMetadata: MCPProtectedResourceMetadata
  public let authorizationServer: MCPAuthorizationServerMetadata
  public let metadataURL: URL
}

public struct MCPOAuthPendingAuthorization: Sendable, Hashable {
  public let authorizationURL: URL
  public let resource: URL
  public let issuer: URL
  public let tokenEndpoint: URL
  public let clientID: String
  public let redirectURI: URL
  public let state: String
  public let codeVerifier: String
  public let scopes: [String]
  public let authorizationResponseIssuerParameterSupported: Bool
  fileprivate let registration: MCPOAuthClientRegistration
}

private struct MCPOAuthRefreshOperation: Sendable {
  let generation: UInt64
  let identity: UUID
  let task: Task<MCPOAuthTokenSet, Error>
}

private struct MCPOAuthPreparedRefresh: Sendable {
  let operation: MCPOAuthRefreshOperation
  let ownsOperation: Bool
}

private enum MCPOAuthCredentialAction: Sendable {
  case missing
  case usable(MCPOAuthTokenSet)
  case refresh(MCPOAuthPreparedRefresh)
}

private actor MCPOAuthCredentialMutationGate {
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !isHeld {
      isHeld = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      isHeld = false
    } else {
      let next = waiters.removeFirst()
      next.resume()
    }
  }
}

/// Coordinates refresh and credential mutation within this live client instance.
///
/// A host must reuse one live `MCPOAuthClient` for each credential-store key. Two client instances
/// that share the same store and resource/issuer/client key do not share a refresh coordinator and
/// may otherwise overwrite or remove each other's credentials.
public actor MCPOAuthClient: MCPHTTPAuthorizationProvider {
  public let resource: URL
  public let registration: MCPOAuthClientRegistration

  private let store: any MCPCredentialStore
  private let http: any MCPOAuthHTTPTransport
  private let random: any MCPOAuthRandomSource
  private let urlPolicy: MCPOAuthURLPolicy
  private let responseLimit: Int
  private let timeout: TimeInterval
  private let refreshLeeway: TimeInterval
  private let pendingAuthorizationTTL: TimeInterval
  private let maximumPendingAuthorizations: Int
  private let now: @Sendable () -> Date
  private var selectedDiscovery: MCPOAuthDiscovery?
  private var pendingStates: [String: Date] = [:]
  private var refreshGenerations: [MCPOAuthCredentialKey: UInt64] = [:]
  private var refreshTasks: [MCPOAuthCredentialKey: MCPOAuthRefreshOperation] = [:]
  private let credentialMutationGate = MCPOAuthCredentialMutationGate()

  public init(
    resource: URL,
    registration: MCPOAuthClientRegistration,
    store: any MCPCredentialStore,
    http: any MCPOAuthHTTPTransport = MCPURLSessionOAuthTransport(),
    random: any MCPOAuthRandomSource = MCPSystemOAuthRandomSource(),
    urlPolicy: MCPOAuthURLPolicy = MCPOAuthURLPolicy(),
    responseLimit: Int = 1_048_576,
    timeout: TimeInterval = 15,
    refreshLeeway: TimeInterval = 30,
    pendingAuthorizationTTL: TimeInterval = 600,
    maximumPendingAuthorizations: Int = 64,
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    try urlPolicy.validate(resource, purpose: "MCP resource")
    guard responseLimit > 0, timeout > 0, refreshLeeway >= 0,
      pendingAuthorizationTTL.isFinite, pendingAuthorizationTTL > 0,
      maximumPendingAuthorizations > 0
    else {
      throw MCPOAuthError.invalidMetadata("OAuth limits are invalid")
    }
    self.resource = resource
    self.registration = registration
    self.store = store
    self.http = http
    self.random = random
    self.urlPolicy = urlPolicy
    self.responseLimit = responseLimit
    self.timeout = timeout
    self.refreshLeeway = refreshLeeway
    self.pendingAuthorizationTTL = pendingAuthorizationTTL
    self.maximumPendingAuthorizations = maximumPendingAuthorizations
    self.now = now
  }

  public func discover(
    challenge: MCPOAuthChallenge? = nil,
    selectedAuthorizationServer: URL? = nil
  ) async throws -> MCPOAuthDiscovery {
    let candidates: [URL]
    if let challengeURL = challenge?.resourceMetadataURL {
      try urlPolicy.validate(challengeURL, purpose: "resource metadata")
      candidates = [challengeURL]
    } else {
      candidates = try Self.protectedResourceMetadataCandidates(resource: resource)
    }
    var resourceMetadata: MCPProtectedResourceMetadata?
    var successfulURL: URL?
    for candidate in candidates {
      do {
        let json = try await fetchJSON(candidate)
        resourceMetadata = try MCPProtectedResourceMetadata(
          json: json, expectedResource: resource, urlPolicy: urlPolicy)
        successfulURL = candidate
        break
      } catch let error as MCPOAuthError {
        if error == .metadataNotFound { continue }
        throw error
      }
    }
    guard let resourceMetadata, let successfulURL else { throw MCPOAuthError.metadataNotFound }
    let issuer: URL
    if let selectedAuthorizationServer {
      guard
        resourceMetadata.authorizationServers.contains(where: {
          $0.absoluteString == selectedAuthorizationServer.absoluteString
        })
      else {
        throw MCPOAuthError.authorizationServerNotAdvertised(
          selectedAuthorizationServer.absoluteString)
      }
      issuer = selectedAuthorizationServer
    } else {
      guard resourceMetadata.authorizationServers.count == 1 else {
        throw MCPOAuthError.multipleAuthorizationServers(
          resourceMetadata.authorizationServers.map(\.absoluteString))
      }
      issuer = resourceMetadata.authorizationServers[0]
    }
    if case .preRegistered(let client) = registration,
      client.issuer.absoluteString != issuer.absoluteString
    {
      throw MCPOAuthError.issuerMismatch(
        expected: client.issuer.absoluteString, actual: issuer.absoluteString)
    }
    let authorizationServer = try await discoverAuthorizationServer(issuer: issuer)
    if case .clientMetadataDocument = registration,
      !authorizationServer.clientIDMetadataDocumentSupported
    {
      throw MCPOAuthError.registrationNotSupported
    }
    let discovery = MCPOAuthDiscovery(
      resourceMetadata: resourceMetadata,
      authorizationServer: authorizationServer,
      metadataURL: successfulURL
    )
    selectedDiscovery = discovery
    return discovery
  }

  public func beginAuthorization(
    redirectURI: URL,
    scopes requestedScopes: [String] = [],
    challenge: MCPOAuthChallenge? = nil,
    selectedAuthorizationServer: URL? = nil
  ) async throws -> MCPOAuthPendingAuthorization {
    try MCPClientIDMetadataDocument.validateRedirectURI(redirectURI)
    guard
      registration.redirectURIs.contains(where: { $0.absoluteString == redirectURI.absoluteString })
    else {
      throw MCPOAuthError.redirectURINotRegistered(redirectURI.absoluteString)
    }
    prunePendingStates(at: now())
    guard pendingStates.count < maximumPendingAuthorizations else {
      throw MCPOAuthError.pendingAuthorizationLimitExceeded(maximumPendingAuthorizations)
    }
    let discovery = try await discover(
      challenge: challenge,
      selectedAuthorizationServer: selectedAuthorizationServer
    )
    let pkce = try MCPOAuthPKCE(randomSource: random)
    let stateCreatedAt = now()
    prunePendingStates(at: stateCreatedAt)
    guard pendingStates.count < maximumPendingAuthorizations else {
      throw MCPOAuthError.pendingAuthorizationLimitExceeded(maximumPendingAuthorizations)
    }
    var state: String?
    for _ in 0..<4 {
      let candidate = Self.base64URL(try random.bytes(count: 32))
      if !candidate.isEmpty, pendingStates[candidate] == nil {
        state = candidate
        break
      }
    }
    guard let state else { throw MCPOAuthError.randomGenerationFailed }
    let scopes = Self.selectScopes(
      explicit: requestedScopes,
      challenge: challenge?.scopes ?? [],
      resourceMetadata: discovery.resourceMetadata.scopesSupported,
      authorizationServer: discovery.authorizationServer.scopesSupported
    )
    var components = URLComponents(
      url: discovery.authorizationServer.authorizationEndpoint,
      resolvingAgainstBaseURL: false
    )
    var items = components?.queryItems ?? []
    let reservedAuthorizationParameters: Set<String> = [
      "response_type", "client_id", "redirect_uri", "code_challenge",
      "code_challenge_method", "state", "resource", "scope",
    ]
    guard !items.contains(where: { reservedAuthorizationParameters.contains($0.name) }) else {
      throw MCPOAuthError.invalidMetadata(
        "authorization endpoint contains a reserved request parameter")
    }
    items.append(contentsOf: [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: registration.clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(
        name: "resource", value: MCPProtectedResourceMetadata.canonicalResource(resource)),
    ])
    if !scopes.isEmpty {
      items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
    }
    components?.queryItems = items
    guard let authorizationURL = components?.url else {
      throw MCPOAuthError.invalidURL("authorization request")
    }
    guard pendingStates[state] == nil else {
      throw MCPOAuthError.randomGenerationFailed
    }
    pendingStates[state] = stateCreatedAt.addingTimeInterval(pendingAuthorizationTTL)
    return MCPOAuthPendingAuthorization(
      authorizationURL: authorizationURL,
      resource: resource,
      issuer: discovery.authorizationServer.issuer,
      tokenEndpoint: discovery.authorizationServer.tokenEndpoint,
      clientID: registration.clientID,
      redirectURI: redirectURI,
      state: state,
      codeVerifier: pkce.verifier,
      scopes: scopes,
      authorizationResponseIssuerParameterSupported:
        discovery.authorizationServer.authorizationResponseIssuerParameterSupported,
      registration: registration
    )
  }

  public func completeAuthorization(
    callbackURL: URL,
    pending: MCPOAuthPendingAuthorization
  ) async throws -> MCPOAuthTokenSet {
    guard callbackURL.user == nil, callbackURL.password == nil, callbackURL.fragment == nil,
      callbackURL.scheme?.lowercased() == pending.redirectURI.scheme?.lowercased(),
      callbackURL.host?.lowercased() == pending.redirectURI.host?.lowercased(),
      callbackURL.port == pending.redirectURI.port,
      callbackURL.path == pending.redirectURI.path
    else { throw MCPOAuthError.redirectURINotRegistered(callbackURL.absoluteString) }
    let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let parameters = try Self.uniqueQueryItems(items)
    prunePendingStates(at: now())
    guard parameters["state"] == pending.state else { throw MCPOAuthError.stateMismatch }
    guard pendingStates.removeValue(forKey: pending.state) != nil else {
      throw MCPOAuthError.authorizationStateNotPending
    }
    let responseParameterNames: Set<String> = [
      "code", "state", "iss", "error", "error_description", "error_uri",
    ]
    let callbackBaseParameters = parameters.filter { !responseParameterNames.contains($0.key) }
    let registeredBaseParameters = try Self.uniqueQueryItems(
      URLComponents(url: pending.redirectURI, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    guard callbackBaseParameters == registeredBaseParameters else {
      throw MCPOAuthError.redirectURINotRegistered(callbackURL.absoluteString)
    }
    if let actualIssuer = parameters["iss"] {
      guard actualIssuer == pending.issuer.absoluteString else {
        throw MCPOAuthError.authorizationResponseIssuerMismatch(
          expected: pending.issuer.absoluteString, actual: actualIssuer)
      }
    } else if pending.authorizationResponseIssuerParameterSupported {
      throw MCPOAuthError.authorizationResponseIssuerMissing
    }
    if let code = parameters["error"] {
      throw MCPOAuthError.authorizationDenied(
        code: code, description: parameters["error_description"])
    }
    guard let code = parameters["code"], !code.isEmpty else {
      throw MCPOAuthError.missingAuthorizationCode
    }
    var form: [String: String] = [
      "grant_type": "authorization_code",
      "code": code,
      "redirect_uri": pending.redirectURI.absoluteString,
      "client_id": pending.clientID,
      "code_verifier": pending.codeVerifier,
      "resource": MCPProtectedResourceMetadata.canonicalResource(pending.resource),
    ]
    var headers = [
      "content-type": "application/x-www-form-urlencoded", "accept": "application/json",
    ]
    try Self.applyClientAuthentication(
      registration: pending.registration,
      form: &form,
      headers: &headers
    )
    let key = MCPOAuthCredentialKey(
      resource: pending.resource, issuer: pending.issuer, clientID: pending.clientID)
    let expectedGeneration = refreshGenerations[key] ?? 0
    let token = try await requestToken(
      endpoint: pending.tokenEndpoint,
      form: form,
      headers: headers,
      previousRefreshToken: nil
    )
    guard (refreshGenerations[key] ?? 0) == expectedGeneration else {
      throw CancellationError()
    }
    let replacementGeneration = advanceCredentialGeneration(for: key)
    let gate = credentialMutationGate
    await gate.acquire()
    do {
      guard (refreshGenerations[key] ?? 0) == replacementGeneration else {
        throw CancellationError()
      }
      try await store.save(token, for: key)
      await gate.release()
    } catch {
      await gate.release()
      throw error
    }
    guard (refreshGenerations[key] ?? 0) == replacementGeneration else {
      throw CancellationError()
    }
    return token
  }

  public func authorizationHeader(for resource: URL) async throws -> String? {
    guard
      MCPProtectedResourceMetadata.canonicalResource(resource)
        == MCPProtectedResourceMetadata.canonicalResource(self.resource)
    else {
      throw MCPOAuthError.resourceMismatch(
        expected: MCPProtectedResourceMetadata.canonicalResource(self.resource),
        actual: MCPProtectedResourceMetadata.canonicalResource(resource)
      )
    }
    guard let discovery = selectedDiscovery else { return nil }
    let key = MCPOAuthCredentialKey(
      resource: self.resource,
      issuer: discovery.authorizationServer.issuer,
      clientID: registration.clientID
    )
    switch try await prepareAuthorizationCredential(key: key, discovery: discovery) {
    case .missing:
      return nil
    case .usable(let token):
      return "Bearer \(token.accessToken)"
    case .refresh(let prepared):
      let token = try await completeRefresh(prepared, key: key)
      return "Bearer \(token.accessToken)"
    }
  }

  public func refreshCurrentToken() async throws -> MCPOAuthTokenSet {
    guard let discovery = selectedDiscovery else { throw MCPOAuthError.noCredentials }
    let key = MCPOAuthCredentialKey(
      resource: resource,
      issuer: discovery.authorizationServer.issuer,
      clientID: registration.clientID
    )
    let prepared = try await prepareExplicitRefresh(key: key, discovery: discovery)
    return try await completeRefresh(prepared, key: key)
  }

  public func invalidateCurrentToken() async throws {
    guard let discovery = selectedDiscovery else { return }
    let key = MCPOAuthCredentialKey(
      resource: resource,
      issuer: discovery.authorizationServer.issuer,
      clientID: registration.clientID
    )
    _ = advanceCredentialGeneration(for: key)
    let gate = credentialMutationGate
    await gate.acquire()
    do {
      try await store.remove(for: key)
      await gate.release()
    } catch {
      await gate.release()
      throw error
    }
  }

  private func prepareAuthorizationCredential(
    key: MCPOAuthCredentialKey,
    discovery: MCPOAuthDiscovery
  ) async throws -> MCPOAuthCredentialAction {
    let gate = credentialMutationGate
    await gate.acquire()
    let generation = refreshGenerations[key] ?? 0
    let action: MCPOAuthCredentialAction
    do {
      if let token = try await store.load(for: key) {
        guard (refreshGenerations[key] ?? 0) == generation else {
          throw CancellationError()
        }
        if token.isUsable(at: now(), leeway: refreshLeeway) {
          action = .usable(token)
        } else if token.refreshToken == nil {
          try await store.remove(for: key)
          action = .missing
        } else {
          action = .refresh(
            try registerRefreshOperation(token: token, key: key, discovery: discovery))
        }
      } else {
        action = .missing
      }
      await gate.release()
    } catch {
      await gate.release()
      throw error
    }
    guard (refreshGenerations[key] ?? 0) == generation else {
      throw CancellationError()
    }
    return action
  }

  private func prepareExplicitRefresh(
    key: MCPOAuthCredentialKey,
    discovery: MCPOAuthDiscovery
  ) async throws -> MCPOAuthPreparedRefresh {
    let gate = credentialMutationGate
    await gate.acquire()
    let generation = refreshGenerations[key] ?? 0
    let prepared: MCPOAuthPreparedRefresh
    do {
      guard let token = try await store.load(for: key) else {
        throw MCPOAuthError.noCredentials
      }
      guard (refreshGenerations[key] ?? 0) == generation else {
        throw CancellationError()
      }
      prepared = try registerRefreshOperation(token: token, key: key, discovery: discovery)
      await gate.release()
    } catch {
      await gate.release()
      throw error
    }
    guard (refreshGenerations[key] ?? 0) == generation else {
      throw CancellationError()
    }
    return prepared
  }

  private func registerRefreshOperation(
    token: MCPOAuthTokenSet,
    key: MCPOAuthCredentialKey,
    discovery: MCPOAuthDiscovery
  ) throws -> MCPOAuthPreparedRefresh {
    if let operation = refreshTasks[key] {
      return MCPOAuthPreparedRefresh(operation: operation, ownsOperation: false)
    }
    guard let refreshToken = token.refreshToken else { throw MCPOAuthError.noRefreshToken }
    let registration = self.registration
    let endpoint = discovery.authorizationServer.tokenEndpoint
    let resource = self.resource
    let http = self.http
    let responseLimit = self.responseLimit
    let timeout = self.timeout
    let now = self.now
    let task = Task<MCPOAuthTokenSet, Error> {
      var form: [String: String] = [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": registration.clientID,
        "resource": MCPProtectedResourceMetadata.canonicalResource(resource),
      ]
      var headers = [
        "content-type": "application/x-www-form-urlencoded", "accept": "application/json",
      ]
      try Self.applyClientAuthentication(registration: registration, form: &form, headers: &headers)
      return try await Self.requestToken(
        http: http,
        endpoint: endpoint,
        form: form,
        headers: headers,
        responseLimit: responseLimit,
        timeout: timeout,
        now: now(),
        previousRefreshToken: refreshToken
      )
    }
    let operation = MCPOAuthRefreshOperation(
      generation: refreshGenerations[key] ?? 0,
      identity: UUID(),
      task: task
    )
    refreshTasks[key] = operation
    return MCPOAuthPreparedRefresh(operation: operation, ownsOperation: true)
  }

  private func completeRefresh(
    _ prepared: MCPOAuthPreparedRefresh,
    key: MCPOAuthCredentialKey
  ) async throws -> MCPOAuthTokenSet {
    let operation = prepared.operation
    if !prepared.ownsOperation {
      let result = try await operation.task.value
      guard (refreshGenerations[key] ?? 0) == operation.generation else {
        throw CancellationError()
      }
      return result
    }
    do {
      let result = try await operation.task.value
      guard isCurrentRefresh(operation, for: key) else { throw CancellationError() }
      let gate = credentialMutationGate
      await gate.acquire()
      do {
        guard isCurrentRefresh(operation, for: key) else { throw CancellationError() }
        try await store.save(result, for: key)
        await gate.release()
      } catch {
        await gate.release()
        throw error
      }
      guard isCurrentRefresh(operation, for: key) else { throw CancellationError() }
      removeRefreshIfCurrent(operation, for: key)
      return result
    } catch let refreshError {
      guard isCurrentRefresh(operation, for: key) else { throw refreshError }
      if case MCPOAuthError.tokenEndpointFailure(_, let code, _) = refreshError,
        code == "invalid_grant"
      {
        let gate = credentialMutationGate
        await gate.acquire()
        guard isCurrentRefresh(operation, for: key) else {
          await gate.release()
          throw refreshError
        }
        do {
          try await store.remove(for: key)
          await gate.release()
        } catch let removalError {
          await gate.release()
          guard isCurrentRefresh(operation, for: key) else { throw refreshError }
          removeRefreshIfCurrent(operation, for: key)
          throw MCPOAuthError.invalidGrantCredentialRemovalFailed(
            String(describing: removalError)
          )
        }
      }
      removeRefreshIfCurrent(operation, for: key)
      throw refreshError
    }
  }

  private func isCurrentRefresh(
    _ operation: MCPOAuthRefreshOperation,
    for key: MCPOAuthCredentialKey
  ) -> Bool {
    guard (refreshGenerations[key] ?? 0) == operation.generation,
      let current = refreshTasks[key]
    else { return false }
    return current.identity == operation.identity
  }

  private func removeRefreshIfCurrent(
    _ operation: MCPOAuthRefreshOperation,
    for key: MCPOAuthCredentialKey
  ) {
    guard isCurrentRefresh(operation, for: key) else { return }
    refreshTasks.removeValue(forKey: key)
  }

  @discardableResult
  private func advanceCredentialGeneration(for key: MCPOAuthCredentialKey) -> UInt64 {
    let generation = (refreshGenerations[key] ?? 0) &+ 1
    refreshGenerations[key] = generation
    let operation = refreshTasks.removeValue(forKey: key)
    operation?.task.cancel()
    return generation
  }

  private func discoverAuthorizationServer(issuer: URL) async throws
    -> MCPAuthorizationServerMetadata
  {
    let candidates = try Self.authorizationServerMetadataCandidates(issuer: issuer)
    for candidate in candidates {
      do {
        let json = try await fetchJSON(candidate)
        return try MCPAuthorizationServerMetadata(
          json: json, expectedIssuer: issuer, urlPolicy: urlPolicy)
      } catch let error as MCPOAuthError {
        if error == .metadataNotFound { continue }
        throw error
      }
    }
    throw MCPOAuthError.metadataNotFound
  }

  private func fetchJSON(_ url: URL) async throws -> MCPJSONValue {
    try urlPolicy.validate(url, purpose: "metadata")
    let response = try await http.send(
      MCPOAuthHTTPRequest(
        url: url,
        headers: ["accept": "application/json"],
        timeout: timeout,
        maximumResponseBytes: responseLimit
      ))
    guard response.status == 200 else {
      if response.status == 404 { throw MCPOAuthError.metadataNotFound }
      throw MCPOAuthError.transport("metadata HTTP \(response.status)")
    }
    let mediaType = response.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard mediaType == "application/json" else {
      throw MCPOAuthError.invalidMetadata("metadata content type must be application/json")
    }
    do { return try MCPJSONValue.parse(response.body) } catch {
      throw MCPOAuthError.invalidMetadata("metadata is not strict JSON")
    }
  }

  private func requestToken(
    endpoint: URL,
    form: [String: String],
    headers: [String: String],
    previousRefreshToken: String?
  ) async throws -> MCPOAuthTokenSet {
    try await Self.requestToken(
      http: http,
      endpoint: endpoint,
      form: form,
      headers: headers,
      responseLimit: responseLimit,
      timeout: timeout,
      now: now(),
      previousRefreshToken: previousRefreshToken
    )
  }

  private static func requestToken(
    http: any MCPOAuthHTTPTransport,
    endpoint: URL,
    form: [String: String],
    headers: [String: String],
    responseLimit: Int,
    timeout: TimeInterval,
    now: Date,
    previousRefreshToken: String?
  ) async throws -> MCPOAuthTokenSet {
    let response = try await http.send(
      MCPOAuthHTTPRequest(
        url: endpoint,
        method: "POST",
        headers: headers,
        body: formEncoded(form),
        timeout: timeout,
        maximumResponseBytes: responseLimit
      ))
    if (200...299).contains(response.status) {
      let mediaType = response.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard mediaType == "application/json" else {
        throw MCPOAuthError.invalidTokenResponse("token content type must be application/json")
      }
    }
    let json: MCPJSONValue?
    do {
      json = try MCPJSONValue.parse(response.body)
    } catch {
      json = nil
    }
    if !(200...299).contains(response.status) {
      var code: String?
      var description: String?
      if let json {
        do {
          let object = try MCPJSONObject(json)
          code = try object.optionalString("error")
          description = try object.optionalString("error_description")
        } catch {
          // Error details are optional diagnostics; the non-success HTTP status remains authoritative.
        }
      }
      throw MCPOAuthError.tokenEndpointFailure(
        status: response.status,
        code: code,
        description: description
      )
    }
    guard let json else { throw MCPOAuthError.invalidTokenResponse("body is not JSON") }
    let object = try MCPJSONObject(json)
    let accessToken = try object.requiredNonEmptyString("access_token")
    let tokenType = try object.requiredNonEmptyString("token_type")
    let expiresAt: Date?
    if let seconds = try object.optionalInteger("expires_in") {
      guard seconds >= 0 else { throw MCPOAuthError.invalidTokenResponse("expires_in is negative") }
      expiresAt = now.addingTimeInterval(TimeInterval(seconds))
    } else {
      expiresAt = nil
    }
    let refreshToken = try object.optionalString("refresh_token") ?? previousRefreshToken
    let scopes =
      try object.optionalString("scope")?.split(whereSeparator: \Character.isWhitespace).map(
        String.init) ?? []
    return try MCPOAuthTokenSet(
      accessToken: accessToken,
      tokenType: tokenType,
      expiresAt: expiresAt,
      refreshToken: refreshToken,
      scopes: scopes
    )
  }

  private static func applyClientAuthentication(
    registration: MCPOAuthClientRegistration,
    form: inout [String: String],
    headers: inout [String: String]
  ) throws {
    switch registration.authMethod {
    case .none:
      break
    case .clientSecretPost:
      guard let secret = registration.clientSecret else {
        throw MCPOAuthError.invalidMetadata("missing client secret")
      }
      form["client_secret"] = secret
    case .clientSecretBasic:
      guard let secret = registration.clientSecret else {
        throw MCPOAuthError.invalidMetadata("missing client secret")
      }
      let value = "\(formPercentEncode(registration.clientID)):\(formPercentEncode(secret))"
      headers["authorization"] = "Basic \(Data(value.utf8).base64EncodedString())"
      form.removeValue(forKey: "client_id")
    }
  }

  private static func selectScopes(
    explicit: [String],
    challenge: [String],
    resourceMetadata: [String],
    authorizationServer: [String]
  ) -> [String] {
    // A WWW-Authenticate scope challenge is authoritative for the failed operation and must not
    // be filtered against discovery metadata: the MCP authorization specification explicitly
    // permits the challenged set to be unrelated to scopes_supported. Explicit caller scopes are
    // additive when a challenge is present; otherwise they take precedence over metadata defaults.
    let source: [String]
    if !challenge.isEmpty {
      source = challenge + explicit
    } else if !explicit.isEmpty {
      source = explicit
    } else {
      source = resourceMetadata
    }
    _ = authorizationServer  // Informational only; never use it to discard required scopes.
    var seen = Set<String>()
    return source.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  private func prunePendingStates(at date: Date) {
    pendingStates = pendingStates.filter { $0.value > date }
  }

  private static func uniqueQueryItems(_ items: [URLQueryItem]) throws -> [String: String] {
    var result: [String: String] = [:]
    for item in items {
      guard result[item.name] == nil else {
        throw MCPOAuthError.invalidMetadata(
          "duplicate authorization response parameter \(item.name)")
      }
      result[item.name] = item.value ?? ""
    }
    return result
  }

  private static func protectedResourceMetadataCandidates(resource: URL) throws -> [URL] {
    guard var base = URLComponents(url: resource, resolvingAgainstBaseURL: false) else {
      throw MCPOAuthError.invalidURL(resource.absoluteString)
    }
    base.query = nil
    base.fragment = nil
    let resourcePath = base.percentEncodedPath
    base.percentEncodedPath =
      "/.well-known/oauth-protected-resource" + (resourcePath == "/" ? "" : resourcePath)
    guard let pathSpecific = base.url else {
      throw MCPOAuthError.invalidURL(resource.absoluteString)
    }
    base.percentEncodedPath = "/.well-known/oauth-protected-resource"
    guard let root = base.url else { throw MCPOAuthError.invalidURL(resource.absoluteString) }
    return pathSpecific == root ? [root] : [pathSpecific, root]
  }

  private static func authorizationServerMetadataCandidates(issuer: URL) throws -> [URL] {
    guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else {
      throw MCPOAuthError.invalidURL(issuer.absoluteString)
    }
    components.query = nil
    components.fragment = nil
    let path = components.percentEncodedPath
    var result: [URL] = []
    if !path.isEmpty, path != "/" {
      components.percentEncodedPath = "/.well-known/oauth-authorization-server" + path
      if let value = components.url { result.append(value) }
      components.percentEncodedPath = "/.well-known/openid-configuration" + path
      if let value = components.url { result.append(value) }
      components.percentEncodedPath = path + "/.well-known/openid-configuration"
      if let value = components.url { result.append(value) }
    } else {
      components.percentEncodedPath = "/.well-known/oauth-authorization-server"
      if let value = components.url { result.append(value) }
      components.percentEncodedPath = "/.well-known/openid-configuration"
      if let value = components.url { result.append(value) }
    }
    return result
  }

  private static func formEncoded(_ values: [String: String]) -> Data {
    Data(
      values.keys.sorted().map { key in
        "\(formPercentEncode(key))=\(formPercentEncode(values[key] ?? ""))"
      }.joined(separator: "&").utf8)
  }

  private static func formPercentEncode(_ value: String) -> String {
    var result = ""
    for byte in value.utf8 {
      switch byte {
      case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
        result.append(Character(UnicodeScalar(byte)))
      case 0x20:
        result.append("+")
      default:
        result += String(format: "%%%02X", byte)
      }
    }
    return result
  }

  private static func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
