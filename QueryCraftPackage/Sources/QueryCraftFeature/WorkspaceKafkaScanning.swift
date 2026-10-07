import Foundation

public struct WorkspaceKafkaScanRequest: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable { case key, value, keyOrValue }
    public enum Match: String, CaseIterable, Sendable { case contains, exact }

    public let field: Field
    public let match: Match
    public let text: String
    public let caseSensitive: Bool
    public let maximumMessages: Int

    public init(field: Field = .value, match: Match = .contains, text: String,
                caseSensitive: Bool = false, maximumMessages: Int = 10_000) {
        self.field = field
        self.match = match
        self.text = text
        self.caseSensitive = caseSensitive
        self.maximumMessages = maximumMessages
    }

    public var isValid: Bool { !text.isEmpty && (1...100_000).contains(maximumMessages) }

    /// Matches the same UTF-8 / base64 representation shown in the message grid.
    /// A tombstone is absent, not the literal text "NULL" or an empty string.
    public func matches(key: String?, value: String?) -> Bool {
        switch field {
        case .key: matches(key)
        case .value: matches(value)
        case .keyOrValue: matches(key) || matches(value)
        }
    }

    private func matches(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        let options: String.CompareOptions = caseSensitive ? [.literal] : [.caseInsensitive, .literal]
        switch match {
        case .contains: return candidate.range(of: text, options: options) != nil
        case .exact: return candidate.compare(text, options: options) == .orderedSame
        }
    }
}

public struct WorkspaceKafkaScanProgress: Equatable, Sendable {
    public enum Status: Sendable { case scanning, reachedEnd, messageLimit, timeLimit, byteLimit, cancelled, failed }
    public let scanned: Int
    public let matched: Int
    public let status: Status
    public let error: String?

    public init(scanned: Int = 0, matched: Int = 0, status: Status = .scanning, error: String? = nil) {
        self.scanned = scanned
        self.matched = matched
        self.status = status
        self.error = error
    }
}

/// Optional capability, preserving the existing reading and session plugin interfaces.
public protocol WorkspaceKafkaScanning: WorkspaceSession {
    func prepareScanning(topic: String, request: WorkspaceKafkaScanRequest,
                         onProgress: @escaping @Sendable (WorkspaceKafkaScanProgress) async -> Void) async throws
}
