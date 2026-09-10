import SwiftUI

struct WorkspaceQueryEditorActionBar: View {
    private static let runControlWidth: CGFloat = 152
    private static let formatControlWidth: CGFloat = 120
    private static let rowLimitControlWidth: CGFloat = 128
    private static let databaseControlMinimumWidth: CGFloat = 120
    private static let databaseControlMaximumWidth: CGFloat = 260
    private static let schemaControlMinimumWidth: CGFloat = 88
    private static let schemaControlMaximumWidth: CGFloat = 220

    let selectionOrCurrentStatementAvailability: SQLExecutionTargetAvailability
    let runAllAvailability: SQLExecutionTargetAvailability
    let isRunning: Bool
    @Binding var resultRowLimit: QueryResultRowLimit
    let transactionState: WorkspaceQueryTransactionState
    let requiresDisconnect: Bool
    let databaseType: DatabaseType
    let databases: [String]
    let selectedDatabase: String?
    let schemas: [String]
    let selectedSchema: String?
    let isLoadingSchemas: Bool
    let canChangeExecutionContext: Bool
    let selectDatabase: @MainActor (String?) -> Void
    let selectSchema: @MainActor (String?) -> Void
    let runSelectionOrCurrentStatement: @MainActor @Sendable () -> Void
    let runAll: @MainActor @Sendable () -> Void
    let stop: @MainActor @Sendable () -> Void
    let formatSelectionOrCurrentStatement: @MainActor @Sendable () -> Void
    let formatDocument: @MainActor @Sendable () -> Void
    let commitTransaction: @MainActor @Sendable () -> Void
    let rollbackTransaction: @MainActor @Sendable () -> Void
    let disconnectSession: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 6) {
            WorkspaceQuerySplitMenuControl(
                title: isRunning
                    ? AppCopy.current.text("停止  Esc", "Stop  Esc")
                    : AppCopy.current.text("运行当前语句  ⌘↵", "Run Current  ⌘↵"),
                width: Self.runControlWidth,
                isPrimaryEnabled: isRunning || hasSQL,
                isMenuEnabled: !isRunning && hasSQL,
                help: isRunning
                    ? AppCopy.current.text("停止查询", "Stop Query")
                    : runHelp,
                accessibilityIdentifier: isRunning
                    ? "stopQueryButton"
                    : "runQueryButton",
                menuItems: runMenuItems,
                primaryAction: isRunning ? stop : runSelectionOrCurrentStatement
            )
            .frame(width: Self.runControlWidth)

            WorkspaceQuerySplitMenuControl(
                title: AppCopy.current.text("格式化  ⌘I", "Format  ⌘I"),
                width: Self.formatControlWidth,
                isPrimaryEnabled: !isRunning && hasSQL,
                isMenuEnabled: !isRunning && hasSQL,
                help: AppCopy.current.text(
                    "格式化所选内容或当前语句",
                    "Format Selection or Current Statement"
                ),
                accessibilityIdentifier: "formatQueryButton",
                menuItems: formatMenuItems,
                primaryAction: formatSelectionOrCurrentStatement
            )
            .frame(width: Self.formatControlWidth)

            WorkspaceQueryRowLimitMenuControl(
                selection: $resultRowLimit,
                width: Self.rowLimitControlWidth,
                isEnabled: !isRunning
            )
            .frame(width: Self.rowLimitControlWidth)
            .help(
                AppCopy.current.text(
                    "当前查询页的结果行数上限",
                    "Result row limit for this query tab"
                )
            )

            if showsTransactionControls {
                Divider()
                    .frame(height: 18)

                WorkspaceQueryTransactionControls(
                    state: transactionState,
                    isRunning: isRunning,
                    requiresDisconnect: requiresDisconnect,
                    commit: commitTransaction,
                    rollback: rollbackTransaction,
                    disconnect: disconnectSession
                )
            }

            Spacer(minLength: 0)

            executionContextControls
        }
        .controlSize(.regular)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("queryEditorActionBar")
    }

    private var hasSQL: Bool {
        runAllAvailability.isAvailable
            || selectionOrCurrentStatementAvailability.isAvailable
    }

    private var showsTransactionControls: Bool {
        requiresDisconnect || transactionState == .inTransaction
    }

    private var executionContextControls: some View {
        HStack(spacing: 6) {
            WorkspaceQueryContextMenuControl(
                options: databaseOptions,
                selection: selectedDatabase,
                width: databaseControlWidth,
                isEnabled: canChangeExecutionContext,
                help: AppCopy.current.text(
                    "当前查询数据库",
                    "Query Database"
                ),
                accessibilityLabel: AppCopy.current.text(
                    "数据库",
                    "Database"
                ),
                accessibilityIdentifier: "queryDatabasePicker",
                select: selectDatabase
            )
            .frame(width: databaseControlWidth)

            if databaseType == .postgresql {
                WorkspaceQueryContextMenuControl(
                    options: schemaOptions,
                    selection: selectedSchema,
                    width: schemaControlWidth,
                    isEnabled: canChangeExecutionContext
                        && !isLoadingSchemas
                        && !schemas.isEmpty,
                    help: AppCopy.current.text(
                        "当前查询 Schema",
                        "Query Schema"
                    ),
                    accessibilityLabel: "Schema",
                    accessibilityIdentifier: "querySchemaPicker",
                    select: selectSchema
                )
                .frame(width: schemaControlWidth)
            }
        }
    }

    private var databaseControlWidth: CGFloat {
        WorkspaceQueryContextMenuControl.preferredWidth(
            for: databaseOptions,
            minimum: Self.databaseControlMinimumWidth,
            maximum: Self.databaseControlMaximumWidth
        )
    }

    private var schemaControlWidth: CGFloat {
        WorkspaceQueryContextMenuControl.preferredWidth(
            for: schemaOptions,
            minimum: Self.schemaControlMinimumWidth,
            maximum: Self.schemaControlMaximumWidth
        )
    }

    private var databaseOptions: [WorkspaceQueryContextMenuOption] {
        var options = [
            WorkspaceQueryContextMenuOption(
                value: nil,
                title: AppCopy.current.text("无数据库", "No Database")
            ),
        ]
        if let selectedDatabase,
           !databases.contains(selectedDatabase)
        {
            options.append(
                WorkspaceQueryContextMenuOption(
                    value: selectedDatabase,
                    title: AppCopy.current.text(
                        "\(selectedDatabase)（不可用）",
                        "\(selectedDatabase) (Unavailable)"
                    )
                )
            )
        }
        options.append(
            contentsOf: databases.map {
                WorkspaceQueryContextMenuOption(value: $0, title: $0)
            }
        )
        return options
    }

    private var schemaOptions: [WorkspaceQueryContextMenuOption] {
        if isLoadingSchemas {
            return [
                WorkspaceQueryContextMenuOption(
                    value: nil,
                    title: AppCopy.current.text("正在加载…", "Loading...")
                ),
            ]
        }
        if schemas.isEmpty {
            return [
                WorkspaceQueryContextMenuOption(
                    value: nil,
                    title: AppCopy.current.text(
                        "无可用 Schema",
                        "No Schema"
                    )
                ),
            ]
        }
        return schemas.map {
            WorkspaceQueryContextMenuOption(value: $0, title: $0)
        }
    }

    private var runHelp: String {
        selectionOrCurrentStatementAvailability.unavailableReason
            ?? AppCopy.current.text(
                "运行所选内容或当前语句",
                "Run Selection or Current Statement"
            )
    }

    private var runMenuItems: [WorkspaceQuerySplitMenuItem] {
        [
            WorkspaceQuerySplitMenuItem(
                title: AppCopy.current.text("全部运行", "Run All"),
                keyEquivalent: "\r",
                keyEquivalentModifierMask: [.command, .shift],
                isEnabled: runAllAvailability.isAvailable,
                action: runAll
            ),
        ]
    }

    private var formatMenuItems: [WorkspaceQuerySplitMenuItem] {
        [
            WorkspaceQuerySplitMenuItem(
                title: AppCopy.current.text("格式化文档", "Format Document"),
                keyEquivalent: "",
                keyEquivalentModifierMask: [],
                isEnabled: !isRunning,
                action: formatDocument
            ),
        ]
    }
}
