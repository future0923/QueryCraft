import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceMainSplitViewTests {
    @Test
    func manuallyCollapsedInspectorStaysClosedOnContentRefresh() {
        let controller = makeController()
        let inspector = controller.splitViewItems[2]
        update(controller, showsInspector: true)
        inspector.isCollapsed = true

        update(controller, showsInspector: true)

        #expect(inspector.isCollapsed)
    }

    @Test
    func draggingInspectorClosedUpdatesVisibilityState() {
        let controller = makeController()
        var changes: [Bool] = []
        controller.onInspectorVisibilityChange = { changes.append($0) }
        update(controller, showsInspector: true)

        controller.splitViewItems[2].isCollapsed = true
        controller.splitView.layoutSubtreeIfNeeded()

        #expect(changes == [false])
    }

    @Test
    func inspectorRestoresWidthAfterBeingClosedAndReopened() {
        let controller = makeController()
        let inspector = controller.splitViewItems[2]
        controller.splitView.setPosition(800, ofDividerAt: 1)
        controller.splitView.layoutSubtreeIfNeeded()
        let previousWidth = inspector.viewController.view.frame.width
        #expect(previousWidth > 240)

        update(controller, showsInspector: false)
        update(controller, showsInspector: true)
        controller.splitView.layoutSubtreeIfNeeded()

        #expect(abs(inspector.viewController.view.frame.width - previousWidth) < 2)
    }

    @Test
    func nextWindowUsesLastDraggedInspectorWidth() {
        let key = "QueryCraftWorkspaceInspectorLastWidth"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let first = makeController()
        update(first, showsInspector: true)
        first.splitView.setPosition(800, ofDividerAt: 1)
        first.splitView.layoutSubtreeIfNeeded()
        let draggedWidth = first.splitViewItems[2].viewController.view.frame.width
        #expect(draggedWidth > 240)

        let next = makeController(showsInspector: false)
        update(next, showsInspector: false)
        #expect(next.splitViewItems[2].isCollapsed)
        update(next, showsInspector: true)
        next.splitView.layoutSubtreeIfNeeded()

        #expect(abs(next.splitViewItems[2].viewController.view.frame.width - draggedWidth) < 2)
    }

    private func makeController(
        showsInspector: Bool = true
    ) -> WorkspaceMainSplitViewController {
        let controller = WorkspaceMainSplitViewController(
            sidebar: AnyView(Color.clear),
            detail: AnyView(Color.clear),
            inspector: AnyView(Color.clear),
            showsSidebar: true,
            showsInspector: showsInspector,
            sidebarMinimumWidth: 180,
            sidebarMaximumWidth: 600,
            detailMinimumWidth: 520,
            inspectorMinimumWidth: 240
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_400, height: 700)
        controller.splitView.autosaveName = nil
        controller.splitView.layoutSubtreeIfNeeded()
        return controller
    }

    private func update(
        _ controller: WorkspaceMainSplitViewController,
        showsInspector: Bool
    ) {
        controller.update(
            sidebar: AnyView(Color.clear),
            detail: AnyView(Color.clear),
            inspector: AnyView(Color.clear),
            showsSidebar: true,
            showsInspector: showsInspector,
            sidebarMinimumWidth: 180,
            sidebarMaximumWidth: 600,
            detailMinimumWidth: 520,
            inspectorMinimumWidth: 240
        )
    }
}
