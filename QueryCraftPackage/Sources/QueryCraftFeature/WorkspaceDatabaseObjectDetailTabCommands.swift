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
                    KeyEquivalent(
                        actions?.shortcut(for: tab)?.character
                            ?? tab.shortcutCharacter
                    ),
                    modifiers: .command
                )
                .disabled(actions == nil)
            }
        }
    }

    public init() {}
}
