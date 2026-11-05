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
            .keyboardShortcut(canCommit ? KeyboardShortcut("s") : nil)
            .disabled(!canCommit)

            Button(
                AppCopy.current.text("预览 SQL", "Preview SQL"),
                systemImage: "eye",
                action: preview
            )
            .keyboardShortcut(actions?.canPreview == true
                ? KeyboardShortcut("p", modifiers: [.command, .shift]) : nil)
            .disabled(actions?.canPreview != true)

            Button(
                AppCopy.current.text("放弃全部更改", "Discard All Changes"),
                systemImage: "xmark.circle",
                action: discard
            )
            .keyboardShortcut(canDiscard ? KeyboardShortcut(.delete, modifiers: [.command, .shift]) : nil)
            .disabled(!canDiscard)
        }
    }

    public init() {}

    private var canCommit: Bool {
        actions?.canPreview == true && actions?.canCommit == true && actions?.isCommitting != true
    }

    private var canDiscard: Bool {
        actions?.hasChanges == true && actions?.isCommitting != true
    }

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
