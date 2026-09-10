import SwiftUI

struct WorkspaceRedisKeyOutlineView: NSViewRepresentable {
    let nodes: [RedisKeyTreeNode]
    let revision: Int
    let expandsAllItems: Bool
    @Binding var selection: RedisKeyReference?
    let openKey: @MainActor (RedisKeyReference) -> Void
    let renameKey: @MainActor (RedisKeyReference) -> Void
    let copyKeyName: @MainActor (RedisKeyReference) -> Void
    let deleteKey: @MainActor (RedisKeyReference) -> Void
    let automaticallyResolvesKeyTypes: Bool
    let typeResolutionBatchSize: Int
    let resolveKeyTypes: @MainActor ([RedisKeyReference]) -> Void

    func makeCoordinator() -> WorkspaceRedisKeyOutlineCoordinator {
        WorkspaceRedisKeyOutlineCoordinator(
            nodes: nodes,
            revision: revision,
            expandsAllItems: expandsAllItems,
            selection: $selection,
            openKey: openKey,
            renameKey: renameKey,
            copyKeyName: copyKeyName,
            deleteKey: deleteKey,
            automaticallyResolvesKeyTypes: automaticallyResolvesKeyTypes,
            typeResolutionBatchSize: typeResolutionBatchSize,
            resolveKeyTypes: resolveKeyTypes
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        context.coordinator.update(
            nodes: nodes,
            revision: revision,
            expandsAllItems: expandsAllItems,
            selection: $selection,
            openKey: openKey,
            renameKey: renameKey,
            copyKeyName: copyKeyName,
            deleteKey: deleteKey,
            automaticallyResolvesKeyTypes: automaticallyResolvesKeyTypes,
            typeResolutionBatchSize: typeResolutionBatchSize,
            resolveKeyTypes: resolveKeyTypes
        )
    }
}
