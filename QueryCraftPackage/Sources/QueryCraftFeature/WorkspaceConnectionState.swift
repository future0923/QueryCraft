enum WorkspaceConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case failed(String)
}
