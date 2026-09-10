public enum ConnectionTLSMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case disabled
    case required
    case verifyCA
    case verifyIdentity

    public var id: Self { self }
}
