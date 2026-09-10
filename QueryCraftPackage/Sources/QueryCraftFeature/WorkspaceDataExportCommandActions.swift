import Foundation

struct WorkspaceDataExportCommandActions {
    let export: @MainActor @Sendable () -> Void
}
