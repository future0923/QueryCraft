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
            .keyboardShortcut(actions != nil ? KeyboardShortcut("f") : nil)
            .disabled(actions == nil)
        }
    }

    public init() {}

    private func search() {
        if let actions {
            actions.search()
        }
    }
}
