import Observation

struct WorkspaceRedisKeyActions {
    let presentRename: @MainActor @Sendable () -> Void
}

@MainActor
@Observable
final class WorkspaceRedisKeyActionRegistry {
    private var actionsByContentID: [
        WorkspaceContentTabID: WorkspaceRedisKeyActions
    ] = [:]
    private var pendingRenameContentIDs: Set<WorkspaceContentTabID> = []

    func requestRename(for reference: RedisKeyReference) {
        let contentID = WorkspaceContentTabID.redisKey(reference)
        if let actions = actionsByContentID[contentID] {
            actions.presentRename()
        } else {
            pendingRenameContentIDs.insert(contentID)
        }
    }

    func update(
        _ actions: WorkspaceRedisKeyActions,
        for contentID: WorkspaceContentTabID
    ) {
        actionsByContentID[contentID] = actions
        guard pendingRenameContentIDs.remove(contentID) != nil else { return }
        actions.presentRename()
    }

    func remove(for contentID: WorkspaceContentTabID) {
        actionsByContentID[contentID] = nil
    }
}
