import AppKit
import SwiftUI

@MainActor
final class WorkspaceWindowToolbar: NSObject, NSToolbarDelegate {
    static let toolbarIdentifier = NSToolbar.Identifier(
        "cc.debug-tools.QueryCraft.workspace.toolbar"
    )
    static let navigationGroup = NSToolbarItem.Identifier(
        "workspaceNavigationGroup"
    )
    static let primaryActions = NSToolbarItem.Identifier(
        "workspacePrimaryActions"
    )
    static let connectionIdentity = NSToolbarItem.Identifier(
        "workspaceConnectionIdentity"
    )
    static let pendingActions = NSToolbarItem.Identifier(
        "workspacePendingActions"
    )

    static let defaultItemIdentifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace,
        navigationGroup,
        .sidebarTrackingSeparator,
        primaryActions,
        .flexibleSpace,
        connectionIdentity,
        .flexibleSpace,
        pendingActions,
    ]

    static let allowedItemIdentifiers = defaultItemIdentifiers

    let managedToolbar: NSToolbar

    private let model: WorkspaceToolbarModel
    private var hostingControllers: [
        NSToolbarItem.Identifier: NSHostingController<AnyView>
    ] = [:]

    init(model: WorkspaceToolbarModel) {
        self.model = model
        managedToolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        super.init()

        managedToolbar.delegate = self
        managedToolbar.displayMode = .iconOnly
        managedToolbar.allowsUserCustomization = false
        managedToolbar.autosavesConfiguration = false
        managedToolbar.centeredItemIdentifiers = [Self.connectionIdentity]
    }

    func invalidate() {
        hostingControllers.removeAll()
        managedToolbar.delegate = nil
    }

    func toolbarDefaultItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        Self.allowedItemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.navigationGroup:
            return hostingItem(
                identifier: itemIdentifier,
                label: AppCopy.current.text("导航", "Navigation"),
                retainsController: flag,
                usesStableIntrinsicSize: true,
                content: WorkspaceToolbarNavigationControls(model: model)
            )
        case Self.primaryActions:
            return hostingItem(
                identifier: itemIdentifier,
                label: AppCopy.current.text("工作区操作", "Workspace Actions"),
                retainsController: flag,
                usesStableIntrinsicSize: true,
                content: WorkspaceToolbarPrimaryControls(model: model)
            )
        case Self.connectionIdentity:
            return hostingItem(
                identifier: itemIdentifier,
                label: AppCopy.current.text("连接状态", "Connection Status"),
                retainsController: flag,
                usesStableIntrinsicSize: false,
                content: WorkspaceToolbarConnectionIdentity(model: model)
            )
        case Self.pendingActions:
            return hostingItem(
                identifier: itemIdentifier,
                label: AppCopy.current.text("更改和详情", "Changes and Details"),
                retainsController: flag,
                usesStableIntrinsicSize: true,
                content: WorkspaceToolbarPendingControls(model: model)
            )
        default:
            return nil
        }
    }

    private func hostingItem<Content: View>(
        identifier: NSToolbarItem.Identifier,
        label: String,
        retainsController: Bool,
        usesStableIntrinsicSize: Bool,
        content: Content
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label

        let controller = NSHostingController(
            rootView: AnyView(content.focusable(false))
        )
        controller.sizingOptions = [
            .preferredContentSize,
            .intrinsicContentSize,
        ]
        if usesStableIntrinsicSize {
            let size = controller.sizeThatFits(
                in: NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            )
            controller.view.frame.size = size
            controller.view.setContentHuggingPriority(
                .required,
                for: .horizontal
            )
            controller.view.setContentCompressionResistancePriority(
                .required,
                for: .horizontal
            )
        }
        if retainsController {
            hostingControllers[identifier] = controller
        }
        item.view = controller.view
        return item
    }
}
