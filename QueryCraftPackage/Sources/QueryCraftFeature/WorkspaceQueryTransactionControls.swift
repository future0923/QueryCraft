import SwiftUI

struct WorkspaceQueryTransactionControls: View {
    let state: WorkspaceQueryTransactionState
    let isRunning: Bool
    let requiresDisconnect: Bool
    let commit: @MainActor @Sendable () -> Void
    let rollback: @MainActor @Sendable () -> Void
    let disconnect: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(title)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(statusColor)
            }
                .lineLimit(1)
                .help(helpText)
                .accessibilityIdentifier("queryTransactionState")

            if requiresDisconnect {
                Button(AppCopy.current.text("断开连接", "Disconnect"), action: disconnect)
                .foregroundStyle(.red)
                .help(
                    AppCopy.current.text(
                        "取消失败后断开会话",
                        "Disconnect Session After Failed Cancellation"
                    )
                )
            } else {
                Button(AppCopy.current.text("提交  ⌃C", "Commit  ⌃C"), action: commit)
                    .disabled(isRunning)
                    .help(AppCopy.current.text("提交事务", "Commit Transaction"))

                Button(
                    AppCopy.current.text("回滚  ⌃R", "Rollback  ⌃R"),
                    action: rollback
                )
                    .disabled(isRunning)
                    .help(AppCopy.current.text("回滚事务", "Roll Back Transaction"))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var title: String {
        switch state {
        case .disconnected:
            AppCopy.current.text("会话已断开", "Session Disconnected")
        case .autoCommit:
            AppCopy.current.text("自动提交", "Auto-commit")
        case .inTransaction:
            AppCopy.current.text("事务进行中", "In Transaction")
        }
    }

    private var systemImage: String {
        switch state {
        case .disconnected: "exclamationmark.circle.fill"
        case .autoCommit: "checkmark.circle.fill"
        case .inTransaction: "circle.inset.filled"
        }
    }

    private var statusColor: Color {
        switch state {
        case .disconnected: .secondary
        case .autoCommit: .green
        case .inTransaction: .orange
        }
    }

    private var helpText: String {
        switch state {
        case .disconnected:
            AppCopy.current.text(
                "此查询文档没有数据库会话。",
                "The Query Document has no database session."
            )
        case .autoCommit:
            AppCopy.current.text(
                "每条语句独立提交。",
                "Statements commit independently."
            )
        case .inTransaction:
            AppCopy.current.text(
                "此查询文档有一个活动事务。",
                "This Query Document has an active transaction."
            )
        }
    }
}
