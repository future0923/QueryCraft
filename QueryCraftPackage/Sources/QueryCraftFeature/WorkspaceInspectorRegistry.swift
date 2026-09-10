import Observation

@MainActor
@Observable
final class WorkspaceInspectorRegistry {
    private var contextsByContentID: [WorkspaceContentTabID: WorkspaceInspectorContext] = [:]

    func context(
        for contentID: WorkspaceContentTabID?
    ) -> WorkspaceInspectorContext? {
        guard let contentID else { return nil }
        return contextsByContentID[contentID]
    }

    func update(
        _ context: WorkspaceInspectorContext,
        for contentID: WorkspaceContentTabID
    ) {
        contextsByContentID[contentID] = context
    }

    func remove(for contentID: WorkspaceContentTabID) {
        contextsByContentID[contentID] = nil
    }
}
