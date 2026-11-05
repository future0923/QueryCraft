import SwiftUI

public struct WorkspaceDatabaseObjectDetailTabCommands: Commands {
    @FocusedValue(\.workspaceDatabaseObjectDetailTabActions)
    private var actions

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            ForEach(
                actions?.availableTabs
                    ?? WorkspaceDatabaseObjectDetailTab.available(for: .table)
            ) { tab in
                Button(tab.title) {
                    actions?.selectIfAvailable(tab)
                }
                .keyboardShortcut(
                    actions?.shortcut(for: tab).map {
                        KeyboardShortcut(KeyEquivalent($0.character), modifiers: .command)
                    }
                )
                .disabled(actions == nil)
            }
        }
    }

    public init() {}
}
