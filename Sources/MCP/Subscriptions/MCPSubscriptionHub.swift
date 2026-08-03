import Foundation

enum MCPSubscriptionHubMessage: Sendable {
  case notification(MCPWireNotification)
  case close
  case cancel(reason: String?)
}

struct MCPSubscriptionHubHandle: Sendable, Hashable {
  let value = UUID()
}

struct MCPSubscriptionHubOpen: Sendable {
  let handle: MCPSubscriptionHubHandle
  let stream: AsyncThrowingStream<MCPSubscriptionHubMessage, Error>
}

actor MCPSubscriptionHub {
  private struct Entry: Sendable {
    let requestID: MCPRequestID
    let filter: MCPSubscriptionFilter
    let continuation: AsyncThrowingStream<MCPSubscriptionHubMessage, Error>.Continuation
  }

  private var entries: [MCPSubscriptionHubHandle: Entry] = [:]
  private let bufferLimit: Int

  init(bufferLimit: Int) {
    self.bufferLimit = bufferLimit
  }

  func open(
    id: MCPRequestID,
    filter: MCPSubscriptionFilter
  ) -> MCPSubscriptionHubOpen {
    let handle = MCPSubscriptionHubHandle()
    let pair = AsyncThrowingStream<MCPSubscriptionHubMessage, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(bufferLimit))
    entries[handle] = Entry(
      requestID: id,
      filter: filter,
      continuation: pair.continuation
    )
    return MCPSubscriptionHubOpen(handle: handle, stream: pair.stream)
  }

  func remove(handle: MCPSubscriptionHubHandle) {
    entries.removeValue(forKey: handle)?.continuation.finish()
  }

  private func close(handle: MCPSubscriptionHubHandle) {
    guard let entry = entries.removeValue(forKey: handle) else { return }
    switch entry.continuation.yield(.close) {
    case .enqueued:
      entry.continuation.finish()
    case .dropped:
      entry.continuation.finish(
        throwing: MCPClientError.protocolViolation("subscription close buffer overflow"))
    case .terminated:
      break
    @unknown default:
      entry.continuation.finish(
        throwing: MCPClientError.protocolViolation("unknown subscription buffer state"))
    }
  }

  func cancel(handle: MCPSubscriptionHubHandle, reason: String?) {
    guard let entry = entries.removeValue(forKey: handle) else { return }
    switch entry.continuation.yield(.cancel(reason: reason)) {
    case .enqueued:
      entry.continuation.finish()
    case .dropped:
      entry.continuation.finish(
        throwing: MCPClientError.protocolViolation("subscription cancellation buffer overflow"))
    case .terminated:
      break
    @unknown default:
      entry.continuation.finish(
        throwing: MCPClientError.protocolViolation("unknown subscription buffer state"))
    }
  }

  func cancelAll(reason: String?) {
    let handles = Array(entries.keys)
    for handle in handles { cancel(handle: handle, reason: reason) }
  }

  func closeAll() {
    let values = Array(entries.values)
    entries.removeAll(keepingCapacity: true)
    for entry in values {
      switch entry.continuation.yield(.close) {
      case .enqueued:
        entry.continuation.finish()
      case .dropped:
        entry.continuation.finish(
          throwing: MCPClientError.protocolViolation("subscription close buffer overflow"))
      case .terminated:
        break
      @unknown default:
        entry.continuation.finish(
          throwing: MCPClientError.protocolViolation("unknown subscription buffer state"))
      }
    }
  }

  func publish(method: String, params: [String: MCPJSONValue]) async throws {
    guard let descriptor = MCPMethodRegistry.standard.descriptor(for: method),
      descriptor.direction == .serverToClientNotification
    else {
      throw MCPRegistryError.unsupportedMethod(method)
    }

    let incomingMetadata = try params["_meta"].map(MCPNotificationMetadata.init(json:))
    let extensions = incomingMetadata?.extensions ?? [:]
    var failedHandles: [MCPSubscriptionHubHandle] = []
    for (handle, entry) in entries
    where Self.accepts(method: method, params: params, filter: entry.filter) {
      var payload = params
      let metadata = try MCPNotificationMetadata(
        subscriptionID: entry.requestID,
        extensions: extensions
      )
      payload["_meta"] = metadata.json
      let notification = try MCPWireNotification(method: method, params: payload)
      switch entry.continuation.yield(.notification(notification)) {
      case .enqueued:
        break
      case .dropped:
        entry.continuation.finish(
          throwing: MCPClientError.protocolViolation("subscription notification buffer overflow"))
        failedHandles.append(handle)
      case .terminated:
        failedHandles.append(handle)
      @unknown default:
        entry.continuation.finish(
          throwing: MCPClientError.protocolViolation("unknown subscription buffer state"))
        failedHandles.append(handle)
      }
    }
    for handle in failedHandles {
      entries.removeValue(forKey: handle)
    }
  }

  private static func accepts(
    method: String,
    params: [String: MCPJSONValue],
    filter: MCPSubscriptionFilter
  ) -> Bool {
    switch method {
    case "notifications/tools/list_changed":
      return filter.toolsListChanged
    case "notifications/prompts/list_changed":
      return filter.promptsListChanged
    case "notifications/resources/list_changed":
      return filter.resourcesListChanged
    case "notifications/resources/updated":
      guard case .string(let uri)? = params["uri"] else { return false }
      return filter.resourceSubscriptions.contains(uri)
    default:
      return false
    }
  }
}
