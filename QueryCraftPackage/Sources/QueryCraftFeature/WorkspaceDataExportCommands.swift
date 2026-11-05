import SwiftUI

public struct WorkspaceDataExportCommands: Commands {
    @FocusedValue(\.workspaceDataExportActions)
    private var actions

    public var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button(
                AppCopy.current.text("导出…", "Export..."),
                systemImage: "square.and.arrow.up",
                action: export
            )
            .keyboardShortcut(actions != nil ? KeyboardShortcut("e", modifiers: [.command, .shift]) : nil)
            .disabled(actions == nil)

            Button(
                AppCopy.current.text("导出中心…", "Export Center..."),
                systemImage: "arrow.down.doc",
                action: WorkspaceDataExportCenterWindowController.show
            )
        }
    }

    public init() {}

    private func export() {
        actions?.export()
    }
}
