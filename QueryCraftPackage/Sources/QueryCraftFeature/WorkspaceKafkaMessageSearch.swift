import Foundation
import CoreFoundation

public enum WorkspaceKafkaReadIsolation: String, CaseIterable, Sendable {
    case readUncommitted = "read_uncommitted", readCommitted = "read_committed"
}

/// Optional capability: configure before connect; older plugins can still load.
public protocol WorkspaceKafkaReadIsolationConfiguring: WorkspaceSession {
    func configureReadIsolation(_ isolation: WorkspaceKafkaReadIsolation) async throws
}

/// Exact, case-sensitive matching on the full key and/or top-level JSON eventId.
/// Both predicates must match when both are supplied. Tombstones cannot match an eventId.
public struct WorkspaceKafkaMessageFilter: Equatable, Sendable {
    public let key: String?
    public let eventID: String?
    public let maximumMessages: Int

    public init(key: String? = nil, eventID: String? = nil, maximumMessages: Int = 10_000) {
        self.key = key; self.eventID = eventID; self.maximumMessages = maximumMessages
    }

    public var isValid: Bool {
        (key != nil || eventID != nil) && (1...100_000).contains(maximumMessages)
            && (key?.utf8.count ?? 0) <= 65_536 && (eventID?.utf8.count ?? 0) <= 65_536
    }

    public func matches(key candidateKey: String?, value: String?) -> Bool {
        if let key, candidateKey != key { return false }
        guard let eventID else { return true }
        guard let value, let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidate = object["eventId"] else { return false }
        if let text = candidate as? String { return text == eventID }
        if let number = candidate as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue == eventID
        }
        return false
    }
}

/// Optional search capability; scans use the existing read position and isolation.
public protocol WorkspaceKafkaMessageSearching: WorkspaceSession {
    func prepareMessageSearch(topic: String, filter: WorkspaceKafkaMessageFilter) async throws -> WorkspaceKafkaScanProgress
}
