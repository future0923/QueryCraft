import SwiftUI

public struct WorkspacePendingChangesCommands: Commands {
    @FocusedValue(\.workspacePendingChangesActions)
    private var actions

    public var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button(
                AppCopy.current.text("提交更改", "Commit Changes"),
                systemImage: "checkmark.circle.fill",
                action: commit
            )
            .keyboardShortcut("s", modifiers: .command)
            .disabled(
                actions?.canPreview != true
                    || actions?.canCommit != true
                    || actions?.isCommitting == true
            )

            Button(
                AppCopy.current.text("预览 SQL", "Preview SQL"),
                systemImage: "eye",
                action: preview
            )
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(actions?.canPreview != true)

            Button(
                AppCopy.current.text("放弃全部更改", "Discard All Changes"),
                systemImage: "xmark.circle",
                action: discard
            )
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(actions?.hasChanges != true || actions?.isCommitting == true)
        }
    }

    public init() {}

    private func commit() {
        actions?.commit()
    }

    private func preview() {
        actions?.preview()
    }

    private func discard() {
        actions?.discard()
    }
}
