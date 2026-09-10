import AppKit
import SwiftUI

@MainActor
final class WorkspaceRetainedContentHostController: NSViewController {
    private var contentControllers: [
        WorkspaceContentTabID: NSViewController
    ] = [:]
    private var contentRevision: Int?
    private(set) var selectedContentID: WorkspaceContentTabID?
    private(set) var contentReconciliationCount = 0
    private var retiredControllers: [NSViewController] = []
    private var retiredControllerReleaseTask: Task<Void, Never>?

    var contentControllerCount: Int {
        contentControllers.count
    }

    func contentController(
        for contentID: WorkspaceContentTabID
    ) -> NSViewController? {
        contentControllers[contentID]
    }

    override func loadView() {
        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view = containerView

    }

    func update(
        model: WorkspaceModel,
        items: [WorkspaceContentTabItem],
        contentRevision updatedContentRevision: Int,
        selectedContentID: WorkspaceContentTabID?,
        contentRefreshRegistry: WorkspaceContentRefreshRegistry,
        pendingChangesRegistry: WorkspacePendingChangesRegistry,
        inspectorRegistry: WorkspaceInspectorRegistry,
        objectDetailTabRegistry: WorkspaceDatabaseObjectDetailTabRegistry,
        redisKeyActionRegistry: WorkspaceRedisKeyActionRegistry
    ) {
        loadViewIfNeeded()
        if contentRevision != updatedContentRevision {
            contentReconciliationCount += 1
            contentRevision = updatedContentRevision
            let updatedContentItemIDs = items.map(\.id)
            removeClosedTabs(keeping: Set(updatedContentItemIDs))

            for item in items
                where contentControllers[item.id] == nil
            {
                let hostingController: NSViewController
                switch item {
                case let .query(queryItem):
                    hostingController = NSHostingController(
                        rootView: WorkspaceQueryDocumentContainer(
                            model: model,
                            document: queryItem.document,
                            editorContext: queryItem.editorContext,
                            pendingChangesRegistry: pendingChangesRegistry,
                            inspectorRegistry: inspectorRegistry
                        )
                    )
                case let .databaseObject(selection):
                    hostingController = NSHostingController(
                        rootView: WorkspaceDatabaseObjectDetailView(
                            selection: selection,
                            model: model,
                            contentRefreshRegistry: contentRefreshRegistry,
                            pendingChangesRegistry: pendingChangesRegistry,
                            inspectorRegistry: inspectorRegistry,
                            objectDetailTabRegistry: objectDetailTabRegistry
                        )
                    )
                case let .newTable(draft):
                    hostingController = NSHostingController(
                        rootView: WorkspaceNewTableDetailView(
                            draft: draft,
                            model: model,
                            pendingChangesRegistry: pendingChangesRegistry,
                            inspectorRegistry: inspectorRegistry
                        )
                    )
                case let .redisKey(reference):
                    hostingController = NSHostingController(
                        rootView: WorkspaceRedisKeyDetailView(
                            reference: reference,
                            model: model,
                            contentRefreshRegistry: contentRefreshRegistry,
                            pendingChangesRegistry: pendingChangesRegistry,
                            inspectorRegistry: inspectorRegistry,
                            redisKeyActionRegistry: redisKeyActionRegistry
                        )
                    )
                case let .redisCommand(document):
                    hostingController = NSHostingController(
                        rootView: WorkspaceRedisCommandDocumentView(
                            document: document,
                            workspace: model
                        )
                    )
                case let .elasticsearchRequest(document):
                    hostingController = NSHostingController(
                        rootView: WorkspaceElasticsearchRequestDocumentView(
                            document: document
                        )
                    )
                }
                install(hostingController, for: item.id)
            }
        }

        show(selectedContentID)
    }

    private func install(
        _ controller: NSViewController,
        for contentID: WorkspaceContentTabID
    ) {
        addChild(controller)
        let contentView = controller.view
        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.autoresizingMask = [.width, .height]
        contentView.frame = view.bounds
        contentControllers[contentID] = controller
    }

    private func show(_ contentID: WorkspaceContentTabID?) {
        guard selectedContentID != contentID else { return }
        let outgoing = selectedContentID.flatMap { contentControllers[$0] }
        let incoming = contentID.flatMap { contentControllers[$0] }
        let firstResponderWasInsideOutgoing = outgoing.flatMap { controller in
            guard let responder = view.window?.firstResponder as? NSView else {
                return false
            }
            return responder === controller.view
                || responder.isDescendant(of: controller.view)
        } ?? false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            outgoing?.view.removeFromSuperview()
            if let incoming {
                incoming.view.frame = view.bounds
                incoming.view.setAccessibilityHidden(false)
                view.addSubview(
                    incoming.view,
                    positioned: .above,
                    relativeTo: nil
                )
            }
        }
        selectedContentID = incoming == nil ? nil : contentID
        if firstResponderWasInsideOutgoing, let incoming {
            view.window?.makeFirstResponder(incoming.view)
        }
    }

    private func removeClosedTabs(
        keeping contentIDs: Set<WorkspaceContentTabID>
    ) {
        let removedContentIDs = contentControllers.keys.filter {
            !contentIDs.contains($0)
        }
        for contentID in removedContentIDs {
            guard let controller = contentControllers.removeValue(
                forKey: contentID
            ) else { continue }
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            retiredControllers.append(controller)
            if selectedContentID == contentID { selectedContentID = nil }
        }
        scheduleRetiredControllerRelease()
    }

    private func scheduleRetiredControllerRelease() {
        guard !retiredControllers.isEmpty else { return }
        retiredControllerReleaseTask?.cancel()
        retiredControllerReleaseTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.retiredControllers.removeAll()
            self?.retiredControllerReleaseTask = nil
        }
    }
}

typealias WorkspaceContentTabHostController =
    WorkspaceRetainedContentHostController
