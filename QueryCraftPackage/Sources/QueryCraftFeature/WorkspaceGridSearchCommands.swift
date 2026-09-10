import AppKit
import SwiftUI

public struct WorkspaceGridSearchCommands: Commands {
    @FocusedValue(\.workspaceGridSearchActions)
    private var actions

    public var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(
                AppCopy.current.text("在结果中查找…", "Find in Results..."),
                systemImage: "magnifyingglass",
                action: search
            )
            .keyboardShortcut("f", modifiers: .command)
        }
    }

    public init() {}

    private func search() {
        if let tableView = WorkspaceDirectDrawTableView.visibleSearchTarget(
            in: NSApp.keyWindow
        ) {
            tableView.findInData(nil)
            return
        }
        if let actions {
            actions.search()
            return
        }
        NSApp.sendAction(
            #selector(WorkspaceDirectDrawTableView.findInData(_:)),
            to: nil,
            from: nil
        )
    }
}
