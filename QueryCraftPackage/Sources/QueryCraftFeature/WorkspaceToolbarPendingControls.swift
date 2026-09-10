import SwiftUI

struct WorkspaceToolbarPendingControls: View {
    @Bindable var model: WorkspaceToolbarModel

    var body: some View {
        HStack(spacing: 0) {
            ControlGroup {
                Button(
                    AppCopy.current.text(
                        "放弃全部更改",
                        "Discard All Changes"
                    ),
                    systemImage: "xmark.circle",
                    action: discardPendingChanges
                )
                .labelStyle(.iconOnly)
                .disabled(!model.canDiscardPendingChanges)
                .help(model.discardPendingChangesHelp)
                .accessibilityHint(model.discardPendingChangesHelp)
                .accessibilityIdentifier("workspaceDiscardChangesButton")

                Button(
                    model.previewPendingChangesTitle,
                    systemImage: "eye",
                    action: showSQLPreview
                )
                .labelStyle(.iconOnly)
                .disabled(!model.canPreviewPendingChanges)
                .help(model.previewPendingChangesHelp)
                .accessibilityHint(model.previewPendingChangesHelp)
                .accessibilityIdentifier("workspacePreviewSQLButton")

                Button(
                    model.pendingChangesAreCommitting
                        ? AppCopy.current.text(
                            "正在提交更改…",
                            "Committing Changes..."
                        )
                        : AppCopy.current.text(
                            "提交更改",
                            "Commit Changes"
                        ),
                    systemImage: model.pendingChangesAreCommitting
                        ? "hourglass"
                        : "checkmark.circle.fill",
                    action: model.commitPendingChanges
                )
                .labelStyle(.iconOnly)
                .disabled(!model.canCommitPendingChanges)
                .help(model.commitPendingChangesHelp)
                .accessibilityHint(model.commitPendingChangesHelp)
                .accessibilityIdentifier("workspaceCommitChangesButton")

                Button(
                    inspectorTitle,
                    systemImage: "sidebar.right",
                    action: model.toggleInspector
                )
                .labelStyle(.iconOnly)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(inspectorHelp)
                .accessibilityIdentifier("workspaceInspectorToggleButton")
            }
        }
        .fixedSize()
        // ControlGroup extracts its child controls, so it is not a stable
        // presentation anchor when hosted directly inside an NSToolbarItem.
        .popover(
            isPresented: $model.showsSQLPreview,
            arrowEdge: .bottom
        ) {
            WorkspacePendingChangesPreviewView(
                preview: model.pendingChangesPreview,
                dismiss: model.closeSQLPreview
            )
        }
        .onChange(of: model.selectedContentID) {
            model.closeSQLPreview()
        }
        .onChange(of: model.hasPendingChanges) { _, hasPendingChanges in
            if !hasPendingChanges {
                model.closeSQLPreview()
            }
        }
    }

    private var inspectorTitle: String {
        model.showsInspector
            ? AppCopy.current.text("隐藏详情", "Hide Details")
            : AppCopy.current.text("显示详情", "Show Details")
    }

    private var inspectorHelp: String {
        model.showsInspector
            ? AppCopy.current.text(
                "隐藏详情 (⌥⌘I)",
                "Hide Details (⌥⌘I)"
            )
            : AppCopy.current.text(
                "显示详情 (⌥⌘I)",
                "Show Details (⌥⌘I)"
            )
    }

    private func discardPendingChanges() {
        model.discardPendingChanges()
    }

    private func showSQLPreview() {
        model.previewPendingChanges()
    }
}
