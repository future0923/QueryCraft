import AppKit
import SwiftUI

@MainActor
final public class WorkspaceDatabaseObjectDetailTabHostCoordinator {
    private var hosts: [
        WorkspaceDatabaseObjectDetailTab:
            NSHostingView<WorkspaceDatabaseObjectDetailTabRoot>
    ] = [:]
    private var roots: [
        WorkspaceDatabaseObjectDetailTab: WorkspaceDatabaseObjectDetailTabRoot
    ] = [:]

    func install(
        root: WorkspaceDatabaseObjectDetailTabRoot,
        in tabView: NSTabView
    ) {
        guard hosts[root.tab] == nil else { return }

        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]

        let item = NSTabViewItem(identifier: root.tab.rawValue)
        item.label = root.tab.rawValue
        item.view = hostingView
        tabView.addTabViewItem(item)

        hosts[root.tab] = hostingView
        roots[root.tab] = root
    }

    func update(root: WorkspaceDatabaseObjectDetailTabRoot) {
        guard
            roots[root.tab] != root,
            let hostingView = hosts[root.tab]
        else {
            return
        }

        roots[root.tab] = root
        hostingView.rootView = root
    }

    func select(
        _ tab: WorkspaceDatabaseObjectDetailTab,
        in tabView: NSTabView
    ) {
        guard
            (tabView.selectedTabViewItem?.identifier as? String) != tab.rawValue
        else {
            return
        }
        tabView.selectTabViewItem(withIdentifier: tab.rawValue)
    }
}
