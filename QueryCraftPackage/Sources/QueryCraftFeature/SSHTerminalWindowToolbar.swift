import AppKit
import SwiftUI

@MainActor
final class SSHTerminalWindowToolbar: NSObject, NSToolbarDelegate {
    static let toolbarIdentifier = NSToolbar.Identifier(
        "cc.debug-tools.QueryCraft.ssh.toolbar"
    )
    static let navigationGroup = NSToolbarItem.Identifier(
        "sshNavigationGroup"
    )
    static let primaryActions = NSToolbarItem.Identifier(
        "sshPrimaryActions"
    )
    static let connectionIdentity = NSToolbarItem.Identifier(
        "sshConnectionIdentity"
    )
    static let pendingActions = NSToolbarItem.Identifier(
        "sshDetailsActions"
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

    private let model: SSHTerminalWorkspace
    private var hostingControllers: [
        NSToolbarItem.Identifier: NSHostingController<AnyView>
    ] = [:]

    init(model: SSHTerminalWorkspace) {
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
                content: SSHTerminalNavigationControls(model: model)
            )
        case Self.primaryActions:
            return hostingItem(
                identifier: itemIdentifier,
                label: AppCopy.current.text("终端操作", "Terminal Actions"),
                retainsController: flag,
                usesStableIntrinsicSize: true,
                content: SSHTerminalPrimaryControls(model: model)
            )
        case Self.connectionIdentity:
            return hostingItem(
                identifier: itemIdentifier,
                label: AppCopy.current.text("连接状态", "Connection Status"),
                retainsController: flag,
                usesStableIntrinsicSize: false,
                content: SSHTerminalToolbarIdentity(model: model)
            )
        case Self.pendingActions:
            return hostingItem(
                identifier: itemIdentifier,
                label: AppCopy.current.text("连接和详情", "Connection and Details"),
                retainsController: flag,
                usesStableIntrinsicSize: true,
                content: SSHTerminalDetailsControls(model: model)
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

private struct SSHTerminalNavigationControls: View {
    @Bindable var model: SSHTerminalWorkspace
    var body: some View {
        ControlGroup {
            Button(AppCopy.current.text("服务器侧栏", "Server Sidebar"), systemImage: "sidebar.left", action: model.toggleSidebar)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(AppCopy.current.text("显示或隐藏服务器 (⌃⌘S)", "Show or hide servers (⌃⌘S)"))
                .accessibilityIdentifier("sshSidebarToggle")
            Button(AppCopy.current.text("切换连接", "Switch Connection"), systemImage: "network", action: WelcomeWindowPresentation.show)
                .help(AppCopy.current.text("切换连接 (⇧⌘K)", "Switch Connection (⇧⌘K)"))
        }.labelStyle(.iconOnly).fixedSize()
    }
}

private struct SSHTerminalPrimaryControls: View {
    @Bindable var model: SSHTerminalWorkspace
    var body: some View {
        ControlGroup {
            Button(AppCopy.current.text("新终端", "New Terminal"), systemImage: "plus.square") {
                if let profile = model.inspectedProfile { model.connect(profile) }
            }.disabled(model.inspectedProfile == nil || model.sessions.count >= 12)
                .help(AppCopy.current.text("在新页签中连接服务器", "Connect in a new tab"))
            Button(AppCopy.current.text("断开连接", "Disconnect"), systemImage: "stop.circle") { model.current?.disconnect() }
                .disabled(model.current?.isActive != true).help(AppCopy.current.text("断开当前终端", "Disconnect current terminal"))
            Button(AppCopy.current.text("重新连接", "Reconnect"), systemImage: "arrow.clockwise") {
                if let session = model.current { model.reconnect(session) }
            }.disabled(model.current == nil || model.current?.isActive == true)
                .help(AppCopy.current.text("重新连接当前终端", "Reconnect current terminal"))
        }.labelStyle(.iconOnly).fixedSize()
    }
}

private struct SSHTerminalToolbarIdentity: View {
    @Bindable var model: SSHTerminalWorkspace
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.inspectedProfile?.name ?? AppCopy.current.text("SSH 终端", "SSH Terminal")).font(.headline).lineLimit(1)
                if let profile = model.inspectedProfile {
                    Text(profile.username + "@" + profile.host + ":" + String(profile.port)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if let session = model.current {
                Circle().fill(session.state == .connected ? Color.green : Color.secondary).frame(width: 6, height: 6).accessibilityLabel(session.status)
            }
        }.frame(maxWidth: 300)
    }
}

private struct SSHTerminalDetailsControls: View {
    @Bindable var model: SSHTerminalWorkspace
    var body: some View {
        ControlGroup {
            Button(AppCopy.current.text("编辑连接", "Edit Connection"), systemImage: "slider.horizontal.3") {
                if let profile = model.inspectedProfile { model.editServer(profile) }
            }.disabled(!model.accounts.profiles.contains { $0.id == model.inspectedProfile?.id })
                .help(AppCopy.current.text("编辑连接", "Edit connection"))
            Button(AppCopy.current.text("脚本与连接信息", "Scripts and Connection Info"), systemImage: "sidebar.right", action: model.toggleInspector)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(AppCopy.current.text("显示或隐藏详情 (⌥⌘I)", "Show or hide details (⌥⌘I)"))
                .accessibilityIdentifier("sshInspectorToggle")
        }.labelStyle(.iconOnly).fixedSize()
    }
}
