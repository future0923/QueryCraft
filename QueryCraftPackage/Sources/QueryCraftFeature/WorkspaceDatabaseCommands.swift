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
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button(
                AppCopy.current.text("打开数据库…", "Open Database..."),
                systemImage: "cylinder"
            ) {
                actions?.openDatabasePicker()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(actions?.canOpenDatabasePicker != true)

            Button(
                AppCopy.current.text("刷新工作区", "Refresh Workspace"),
                systemImage: "arrow.clockwise"
            ) {
                actions?.refreshWorkspace()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }
    }

    public init() {}
}
