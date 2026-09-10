enum WorkspaceDataStopReason: Sendable {
    case userStopped
    case leftDataTab
    case selectionChanged

    var preservesPartialPage: Bool {
        switch self {
        case .userStopped, .leftDataTab:
            true
        case .selectionChanged:
            false
        }
    }
}
