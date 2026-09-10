import Observation

@MainActor
@Observable
final class WorkspacePendingChangesRegistry {
    var hasChanges: Bool { actionsByContentID.values.contains(where: \.hasChanges) }
    private var actionsByContentID: [
        WorkspaceContentTabID: WorkspacePendingChangesActions
    ] = [:]

    func actions(
        for contentID: WorkspaceContentTabID?
    ) -> WorkspacePendingChangesActions? {
        guard let contentID else { return nil }
        return actionsByContentID[contentID]
    }

    func update(
        _ actions: WorkspacePendingChangesActions,
        for contentID: WorkspaceContentTabID
    ) {
        actionsByContentID[contentID] = actions
    }

    func remove(for contentID: WorkspaceContentTabID) {
        actionsByContentID[contentID] = nil
    }
}
