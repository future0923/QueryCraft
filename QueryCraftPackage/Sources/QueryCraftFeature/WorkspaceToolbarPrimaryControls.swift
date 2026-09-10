import SwiftUI

struct WorkspaceToolbarPrimaryControls: View {
    @Bindable var model: WorkspaceToolbarModel

    var body: some View {
        HStack(spacing: 0) {
            ControlGroup {
                Button(
                    newDocumentTitle,
                    systemImage: "plus",
                    action: model.createQueryDocument
                )
                .labelStyle(.iconOnly)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.canCreateQuery)
                .help(newDocumentTitle)
                .accessibilityIdentifier("newQueryButton")

                Button(
                    model.refreshActionTitle,
                    systemImage: model.refreshActionSystemImage,
                    action: model.performRefreshAction
                )
                .labelStyle(.iconOnly)
                .foregroundStyle(refreshActionForegroundStyle)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshActionDisabled)
                .help(model.refreshActionTitle)
                .accessibilityIdentifier("workspaceRefreshButton")

                Button(
                    safetyLockTitle,
                    systemImage: model.model.safetyLock.isEnabled
                        ? "lock.fill"
                        : "lock.open",
                    action: model.toggleSafetyLock
                )
                .labelStyle(.iconOnly)
                .help(safetyLockHelp)
                .accessibilityIdentifier("workspaceSafetyLockButton")
            }
        }
        .fixedSize()
    }

    private var newDocumentTitle: String {
        model.model.databaseType == .redis
            ? AppCopy.current.text("新建 Command", "New Command")
            : AppCopy.current.newQuery
    }

    private var refreshActionForegroundStyle: Color {
        if model.refreshActionIsStopping {
            return .red
        }
        return model.refreshActionDidComplete ? .green : .primary
    }

    private var safetyLockTitle: String {
        model.model.safetyLock.isEnabled
            ? AppCopy.current.text("安全锁已启用", "Safety Lock Enabled")
            : AppCopy.current.text("安全锁已停用", "Safety Lock Disabled")
    }

    private var safetyLockHelp: String {
        model.model.safetyLock.isEnabled
            ? AppCopy.current.text(
                "安全锁已启用 - 已阻止更改",
                "Safety Lock Enabled - Changes Blocked"
            )
            : AppCopy.current.text(
                "安全锁已停用 - 允许更改",
                "Safety Lock Disabled - Changes Allowed"
            )
    }
}
