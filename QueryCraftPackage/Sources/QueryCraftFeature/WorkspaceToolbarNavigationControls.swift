import SwiftUI

struct WorkspaceToolbarNavigationControls: View {
    @Bindable var model: WorkspaceToolbarModel

    var body: some View {
        HStack(spacing: 0) {
            ControlGroup {
                Button(
                    sidebarToggleTitle,
                    systemImage: "sidebar.left",
                    action: model.presentation.requestSidebarToggle
                )
                .labelStyle(.iconOnly)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(sidebarToggleHelp)
                .accessibilityIdentifier("workspaceSidebarToggleButton")

                Button(
                    AppCopy.current.text("切换连接", "Switch Connection"),
                    systemImage: "network",
                    action: model.presentation.requestConnectionPicker
                )
                .labelStyle(.iconOnly)
                .help(
                    AppCopy.current.text(
                        "切换连接 (⇧⌘K)",
                        "Switch Connection (⇧⌘K)"
                    )
                )
                .accessibilityIdentifier("switchConnectionButton")

                if model.showsDatabaseSelection {
                    Button(
                        AppCopy.current.text("打开数据库", "Open Database"),
                        systemImage: "cylinder",
                        action: model.presentation.requestDatabasePicker
                    )
                    .labelStyle(.iconOnly)
                    .help(
                        AppCopy.current.text(
                            "打开数据库 (⌘K)",
                            "Open Database (⌘K)"
                        )
                    )
                    .accessibilityIdentifier("openDatabaseButton")
                }
            }
        }
        .fixedSize()
    }

    private var sidebarToggleTitle: String {
        model.presentation.showsSidebar
            ? AppCopy.current.text("隐藏侧边栏", "Hide Sidebar")
            : AppCopy.current.text("显示侧边栏", "Show Sidebar")
    }

    private var sidebarToggleHelp: String {
        model.presentation.showsSidebar
            ? AppCopy.current.text(
                "隐藏侧边栏 (⌃⌘S)",
                "Hide Sidebar (⌃⌘S)"
            )
            : AppCopy.current.text(
                "显示侧边栏 (⌃⌘S)",
                "Show Sidebar (⌃⌘S)"
            )
    }
}
