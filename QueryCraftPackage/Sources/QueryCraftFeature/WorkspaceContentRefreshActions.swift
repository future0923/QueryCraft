import Foundation
import Observation

struct WorkspaceContentRefreshActions: Equatable {
    let title: String
    let isStopping: Bool
    let didComplete: Bool
    let perform: @MainActor @Sendable () -> Void

    static func == (
        lhs: WorkspaceContentRefreshActions,
        rhs: WorkspaceContentRefreshActions
    ) -> Bool {
        lhs.title == rhs.title
            && lhs.isStopping == rhs.isStopping
            && lhs.didComplete == rhs.didComplete
    }
}

@MainActor
@Observable
final class WorkspaceContentRefreshRegistry {
    private(set) var overviewActions: WorkspaceContentRefreshActions?
    private var overviewOwner: UUID?

    func updateOverview(_ actions: WorkspaceContentRefreshActions, owner: UUID) {
        overviewOwner = owner
        overviewActions = actions
    }

    func removeOverview(owner: UUID) {
        guard overviewOwner == owner else { return }
        overviewActions = nil
        overviewOwner = nil
    }

    private var actionsByContentID: [
        WorkspaceContentTabID: WorkspaceContentRefreshActions
    ] = [:]

    func actions(
        for contentID: WorkspaceContentTabID?
    ) -> WorkspaceContentRefreshActions? {
        guard let contentID else { return nil }
        return actionsByContentID[contentID]
    }

    func update(
        _ actions: WorkspaceContentRefreshActions,
        for contentID: WorkspaceContentTabID
    ) {
        actionsByContentID[contentID] = actions
    }

    func remove(for contentID: WorkspaceContentTabID) {
        actionsByContentID[contentID] = nil
    }
}
