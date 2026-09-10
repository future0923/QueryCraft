enum ConnectionTestState: Equatable {
    case idle
    case testing
    case succeeded
    case failed(String)

    var isTesting: Bool {
        self == .testing
    }
}
