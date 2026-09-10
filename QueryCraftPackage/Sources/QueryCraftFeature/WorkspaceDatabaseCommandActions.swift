struct WorkspaceDatabaseCommandActions {
    let openConnectionPicker: @MainActor @Sendable () -> Void
    let canOpenDatabasePicker: Bool
    let openDatabasePicker: @MainActor @Sendable () -> Void
    let refreshWorkspace: @MainActor @Sendable () -> Void
}
