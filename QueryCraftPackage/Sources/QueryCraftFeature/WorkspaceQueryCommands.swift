import SwiftUI

public struct WorkspaceQueryCommands: Commands {
    @FocusedValue(\.workspaceQueryCommandActions)
    private var actions

    public var body: some Commands {
        CommandMenu(AppCopy.current.text("查询", "Query")) {
            Button(AppCopy.current.text("保存查询", "Save Query"), action: save)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(actions?.canSave != true)

            Divider()

            Button(
                AppCopy.current.text(
                    "运行所选内容或当前语句",
                    "Run Selection or Current Statement"
                ),
                action: runSelectionOrCurrentStatement
            )
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(actions == nil)

            Button(AppCopy.current.text("全部运行", "Run All"), action: runAll)
                .keyboardShortcut(
                    .return,
                    modifiers: [.command, .shift]
                )
                .disabled(actions == nil)

            Divider()

            Button(AppCopy.current.text("停止查询", "Stop Query"), action: stop)
                .keyboardShortcut(.cancelAction)
                .disabled(actions?.isRunning != true)

            Divider()

            Button(
                AppCopy.current.text("提交事务", "Commit Transaction"),
                action: commitTransaction
            )
                .keyboardShortcut(
                    "c",
                    modifiers: .control
                )
                .disabled(
                    actions?.isRunning != false
                        || actions?.requiresSessionDisconnect == true
                        || actions?.transactionState != .inTransaction
                )

            Button(
                AppCopy.current.text("回滚事务", "Roll Back Transaction"),
                action: rollbackTransaction
            )
                .keyboardShortcut(
                    "r",
                    modifiers: .control
                )
                .disabled(
                    actions?.isRunning != false
                        || actions?.requiresSessionDisconnect == true
                        || actions?.transactionState != .inTransaction
                )

            Divider()

            Button(
                AppCopy.current.text(
                    "格式化所选内容或当前语句",
                    "Format Selection or Current Statement"
                ),
                action: formatSelectionOrCurrentStatement
            )
            .keyboardShortcut("i", modifiers: .command)
            .disabled(actions == nil)

            Button(
                AppCopy.current.text("格式化文档", "Format Document"),
                action: formatDocument
            )
                .disabled(actions == nil)
        }
    }

    public init() {}

    private func save() {
        actions?.save()
    }

    private func runSelectionOrCurrentStatement() {
        actions?.runSelectionOrCurrentStatement()
    }

    private func runAll() {
        actions?.runAll()
    }

    private func stop() {
        actions?.stop()
    }

    private func commitTransaction() {
        actions?.commitTransaction()
    }

    private func rollbackTransaction() {
        actions?.rollbackTransaction()
    }

    private func formatSelectionOrCurrentStatement() {
        actions?.formatSelectionOrCurrentStatement()
    }

    private func formatDocument() {
        actions?.formatDocument()
    }
}
