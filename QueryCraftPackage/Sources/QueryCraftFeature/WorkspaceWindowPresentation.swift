import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceWindowPresentation {
    private(set) var context: WorkspaceDatabaseContext
    private(set) var retainedContexts: [WorkspaceDatabaseContext]
    private(set) var databaseContexts: [WorkspaceDatabaseContextDescriptor]
    private(set) var selectedDatabaseContextID: UUID
    private(set) var showsSidebar = true
    private(set) var showsInspector = true
    private(set) var sidebarToggleRequestID = 0
    private(set) var connectionPickerRequestID = 0
    private(set) var databasePickerRequestID = 0

    init(
        context: WorkspaceDatabaseContext,
        retainedContexts: [WorkspaceDatabaseContext],
        databaseContexts: [WorkspaceDatabaseContextDescriptor],
        selectedDatabaseContextID: UUID
    ) {
        self.context = context
        self.retainedContexts = retainedContexts
        self.databaseContexts = databaseContexts
        self.selectedDatabaseContextID = selectedDatabaseContextID
    }

    func activate(
        _ context: WorkspaceDatabaseContext,
        retainedContexts: [WorkspaceDatabaseContext],
        databaseContexts: [WorkspaceDatabaseContextDescriptor],
        selectedDatabaseContextID: UUID
    ) {
        self.context = context
        self.retainedContexts = retainedContexts
        self.databaseContexts = databaseContexts
        self.selectedDatabaseContextID = selectedDatabaseContextID
    }

    func setSidebarVisible(_ isVisible: Bool) {
        showsSidebar = isVisible
    }

    func setInspectorVisible(_ isVisible: Bool) {
        showsInspector = isVisible
    }

    func requestSidebarToggle() {
        sidebarToggleRequestID &+= 1
    }

    func requestConnectionPicker() {
        connectionPickerRequestID &+= 1
    }

    func requestDatabasePicker() {
        databasePickerRequestID &+= 1
    }
}
