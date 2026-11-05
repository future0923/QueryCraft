import SwiftUI

public struct WorkspaceDatabaseCommands: Commands {
    @FocusedValue(\.workspaceDatabaseActions)
    private var actions

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(
                AppCopy.current.text("切换连接…", "Switch Connection..."),
                systemImage: "network"
            ) {
                actions?.openConnectionPicker()
            }
            .keyboardShortcut(actions != nil ? KeyboardShortcut("k", modifiers: [.command, .shift]) : nil)
            .disabled(actions == nil)

            Button(
                AppCopy.current.text("打开数据库…", "Open Database..."),
                systemImage: "cylinder"
            ) {
                actions?.openDatabasePicker()
            }
            .keyboardShortcut(actions?.canOpenDatabasePicker == true ? KeyboardShortcut("k") : nil)
            .disabled(actions?.canOpenDatabasePicker != true)

            Button(
                AppCopy.current.text("刷新工作区", "Refresh Workspace"),
                systemImage: "arrow.clockwise"
            ) {
                actions?.refreshWorkspace()
            }
            .keyboardShortcut(actions != nil ? KeyboardShortcut("r", modifiers: [.command, .shift]) : nil)
            .disabled(actions == nil)
        }
    }

    public init() {}
}
