import SwiftUI

public struct WorkspaceQueryCommands: Commands {
    @FocusedValue(\.workspaceQueryCommandActions)
    private var actions

    public var body: some Commands {
        CommandMenu(AppCopy.current.text("查询", "Query")) {
            Button(AppCopy.current.text("保存查询", "Save Query"), action: save)
                .keyboardShortcut(actions?.canSave == true ? KeyboardShortcut("s") : nil)
                .disabled(actions?.canSave != true)

            Divider()

            Button(
                AppCopy.current.text(
                    "运行所选内容或当前语句",
                    "Run Selection or Current Statement"
                ),
                action: runSelectionOrCurrentStatement
            )
            .keyboardShortcut(actions != nil ? KeyboardShortcut(.return) : nil)
            .disabled(actions == nil)

            Button(AppCopy.current.text("全部运行", "Run All"), action: runAll)
                .keyboardShortcut(actions != nil
                    ? KeyboardShortcut(.return, modifiers: [.command, .shift]) : nil)
                .disabled(actions == nil)

            Divider()

            Button(AppCopy.current.text("停止查询", "Stop Query"), action: stop)
                .keyboardShortcut(actions?.isRunning == true ? .cancelAction : nil)
                .disabled(actions?.isRunning != true)

            Divider()

            Button(
                AppCopy.current.text("提交事务", "Commit Transaction"),
                action: commitTransaction
            )
                .keyboardShortcut(canEndTransaction ? KeyboardShortcut("c", modifiers: .control) : nil)
                .disabled(!canEndTransaction)

            Button(
                AppCopy.current.text("回滚事务", "Roll Back Transaction"),
                action: rollbackTransaction
            )
                .keyboardShortcut(canEndTransaction ? KeyboardShortcut("r", modifiers: .control) : nil)
                .disabled(!canEndTransaction)

            Divider()

            Button(
                AppCopy.current.text(
                    "格式化所选内容或当前语句",
                    "Format Selection or Current Statement"
                ),
                action: formatSelectionOrCurrentStatement
            )
            .keyboardShortcut(actions != nil ? KeyboardShortcut("i") : nil)
            .disabled(actions == nil)

            Button(
                AppCopy.current.text("格式化文档", "Format Document"),
                action: formatDocument
            )
                .disabled(actions == nil)
        }
    }

    public init() {}

    private var canEndTransaction: Bool {
        actions?.isRunning == false
            && actions?.requiresSessionDisconnect != true
            && actions?.transactionState == .inTransaction
    }

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
