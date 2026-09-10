import Observation

struct WorkspaceDatabaseObjectDetailTabActions {
    let availableTabs: [WorkspaceDatabaseObjectDetailTab]
    let select: @MainActor @Sendable (
        WorkspaceDatabaseObjectDetailTab
    ) -> Void

    func canSelect(_ tab: WorkspaceDatabaseObjectDetailTab) -> Bool {
        availableTabs.contains(tab)
    }

    func shortcut(
        for tab: WorkspaceDatabaseObjectDetailTab
    ) -> WorkspaceDatabaseObjectDetailTabShortcut? {
        guard let index = availableTabs.firstIndex(of: tab) else { return nil }
        return .commandNumber(at: index)
    }

    @MainActor
    func selectIfAvailable(_ tab: WorkspaceDatabaseObjectDetailTab) {
        guard canSelect(tab) else { return }
        select(tab)
    }
}

@MainActor
@Observable
final public class WorkspaceDatabaseObjectDetailTabRegistry {
    private var actionsByContentID: [
        WorkspaceContentTabID: WorkspaceDatabaseObjectDetailTabActions
    ] = [:]
    private var pendingTabsByContentID: [
        WorkspaceContentTabID: WorkspaceDatabaseObjectDetailTab
    ] = [:]

    func request(
        _ tab: WorkspaceDatabaseObjectDetailTab,
        for selection: WorkspaceDatabaseObjectSelection
    ) {
        guard WorkspaceDatabaseObjectDetailTab.available(for: selection.kind)
            .contains(tab)
        else {
            return
        }
        let contentID = WorkspaceContentTabID.databaseObject(selection)
        if let actions = actionsByContentID[contentID] {
            actions.selectIfAvailable(tab)
        } else {
            pendingTabsByContentID[contentID] = tab
        }
    }

    func update(
        _ actions: WorkspaceDatabaseObjectDetailTabActions,
        for contentID: WorkspaceContentTabID
    ) {
        actionsByContentID[contentID] = actions
        guard let pendingTab = pendingTabsByContentID.removeValue(
            forKey: contentID
        ) else {
            return
        }
        actions.selectIfAvailable(pendingTab)
    }

    func remove(for contentID: WorkspaceContentTabID) {
        actionsByContentID[contentID] = nil
    }
}
