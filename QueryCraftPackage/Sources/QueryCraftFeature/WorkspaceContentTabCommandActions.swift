struct WorkspaceContentTabCommandActions {
    let canCreateQuery: Bool
    let hasContentTabs: Bool
    let createDocumentTitle: String
    let createQuery: @MainActor @Sendable () -> Void
    let closeSelected: @MainActor @Sendable () -> Void
    let selectAtIndex: @MainActor @Sendable (Int) -> Void
    let selectRelative: @MainActor @Sendable (Int) -> Void
}
