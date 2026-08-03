import Foundation

public struct MCPCacheKey: Sendable, Hashable {
  public let endpointIdentity: String
  public let method: String
  public let parameters: Data
  public let clientCapabilities: Data
  public let semanticMetadata: Data
  public let authorizationPartition: String?
  public let resourceURI: String?

  public init(
    endpointIdentity: String,
    method: String,
    parameters: Data,
    clientCapabilities: Data,
    semanticMetadata: Data,
    authorizationPartition: String?,
    resourceURI: String? = nil
  ) {
    self.endpointIdentity = endpointIdentity
    self.method = method
    self.parameters = parameters
    self.clientCapabilities = clientCapabilities
    self.semanticMetadata = semanticMetadata
    self.authorizationPartition = authorizationPartition
    self.resourceURI = resourceURI
  }
}

public struct MCPCacheEntry: Sendable, Hashable {
  public let value: [String: MCPJSONValue]
  public let scope: MCPCacheScope
  public let expiresAt: Date

  public init(value: [String: MCPJSONValue], scope: MCPCacheScope, expiresAt: Date) {
    self.value = value
    self.scope = scope
    self.expiresAt = expiresAt
  }
}

public enum MCPCacheInvalidation: Sendable, Hashable {
  case tools
  case prompts
  case resources
  case resource(uri: String)
  case endpoint(String)
  case all
}

public protocol MCPCacheStore: Sendable {
  func value(for key: MCPCacheKey) async throws -> MCPCacheEntry?
  func insert(_ entry: MCPCacheEntry, for key: MCPCacheKey) async throws
  func invalidate(_ invalidation: MCPCacheInvalidation) async throws
}

public actor MCPMemoryCache: MCPCacheStore {
  private struct StoredEntry: Sendable {
    var entry: MCPCacheEntry
    var accessOrder: UInt64
  }

  private var entries: [MCPCacheKey: StoredEntry] = [:]
  private var accessOrder: UInt64 = 0
  public let maximumEntries: Int
  private let now: @Sendable () -> Date

  /// Rejects an unusable bound instead of trapping, matching the no-trap contract the rest of the
  /// package applies to public initializers.
  public init(
    maximumEntries: Int = 1_024,
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    guard maximumEntries > 0 else {
      throw MCPJSONError.invalidField(field: "maximumEntries", reason: "must be greater than zero")
    }
    self.maximumEntries = maximumEntries
    self.now = now
  }

  public func value(for key: MCPCacheKey) -> MCPCacheEntry? {
    guard var stored = entries[key] else { return nil }
    guard stored.entry.expiresAt > now() else {
      entries.removeValue(forKey: key)
      return nil
    }
    stored.accessOrder = nextAccessOrder()
    entries[key] = stored
    return stored.entry
  }

  public func insert(_ entry: MCPCacheEntry, for key: MCPCacheKey) {
    pruneExpiredEntries()
    if entry.expiresAt > now() {
      if entries[key] == nil, entries.count >= maximumEntries,
        let leastRecentlyUsed = entries.min(by: {
          $0.value.accessOrder < $1.value.accessOrder
        })?.key
      {
        entries.removeValue(forKey: leastRecentlyUsed)
      }
      entries[key] = StoredEntry(entry: entry, accessOrder: nextAccessOrder())
    } else {
      entries.removeValue(forKey: key)
    }
  }

  public func invalidate(_ invalidation: MCPCacheInvalidation) {
    switch invalidation {
    case .all:
      entries.removeAll(keepingCapacity: true)
    case .endpoint(let endpoint):
      entries = entries.filter { $0.key.endpointIdentity != endpoint }
    case .tools:
      entries = entries.filter { $0.key.method != "tools/list" }
    case .prompts:
      entries = entries.filter { $0.key.method != "prompts/list" }
    case .resources:
      entries = entries.filter {
        $0.key.method != "resources/list" && $0.key.method != "resources/templates/list"
      }
    case .resource(let uri):
      entries = entries.filter { key, _ in
        key.method != "resources/read" || key.resourceURI != uri
      }
    }
  }

  public var count: Int {
    pruneExpiredEntries()
    return entries.count
  }

  private func nextAccessOrder() -> UInt64 {
    accessOrder &+= 1
    return accessOrder
  }

  private func pruneExpiredEntries() {
    let current = now()
    entries = entries.filter { $0.value.entry.expiresAt > current }
  }
}

func mcpCachePolicy(from result: [String: MCPJSONValue]) throws -> MCPCachePolicy? {
  try MCPCachePolicy.extract(from: MCPJSONObject(.object(result)), required: false)
}
