enum SQLExecutionTargetAvailability: Equatable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool {
        self == .available
    }

    var unavailableReason: String? {
        if case let .unavailable(reason) = self {
            reason
        } else {
            nil
        }
    }
}
