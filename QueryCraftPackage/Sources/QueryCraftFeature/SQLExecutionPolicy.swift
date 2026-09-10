enum SQLExecutionPolicy: Equatable, Sendable {
    case readOnly
    case writesAllowed

    var allowsWrites: Bool {
        self == .writesAllowed
    }
}
