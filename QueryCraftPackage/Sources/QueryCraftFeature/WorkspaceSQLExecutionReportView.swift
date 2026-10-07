import SwiftUI

enum WorkspaceSQLResultSection: Equatable {
    case messages
    case summary
    case statement
}

struct WorkspaceSQLExecutionMessagesView: View {
    let results: [WorkspaceStatementResult]
    let databaseType: DatabaseType

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: result.statement.sql)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if result.didExecute,
                               result.statement.kind == .read || result.hasRowResult,
                               let limit = result.maximumResultRows {
                                Text(verbatim: "> \(resultLimitMessage(limit, for: result))")
                                    .foregroundStyle(.secondary)
                            }
                            Text(verbatim: "> \(result.statusMessage)")
                                .foregroundStyle(result.state.reportColor)
                            if let rowCount = result.rowCountMessage {
                                Text(verbatim: "> \(rowCount)")
                                    .foregroundStyle(.secondary)
                            }
                            if result.didExecute {
                                Text(
                                    "> \(AppCopy.current.text("耗时", "Time")): \(result.elapsedSeconds, format: .number.precision(.fractionLength(3))) s"
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                        .id(result.id)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
            }
            .onChange(of: results, initial: true) { _, updatedResults in
                // Follow execution progress, never a pending or skipped statement.
                if let latest = updatedResults.last(where: \.didExecute) {
                    proxy.scrollTo(latest.id, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("queryExecutionMessages")
    }

    private func resultLimitMessage(_ limit: Int, for result: WorkspaceStatementResult) -> String {
        if databaseType == .mysql, result.statement.kind == .read {
            return AppCopy.current.text(
                "本次结果上限：\(limit) 行（会话设置 SQL_SELECT_LIMIT = \(limit)，SELECT 原文不变）",
                "Result limit for this run: \(limit) rows (session SQL_SELECT_LIMIT = \(limit); SELECT text unchanged)"
            )
        }
        return AppCopy.current.text(
            "本次结果上限：\(limit) 行", "Result limit for this run: \(limit) rows"
        )
    }
}

struct WorkspaceSQLExecutionSummaryView: View {
    let results: [WorkspaceStatementResult]

    var body: some View {
        Table(results) {
            TableColumn(AppCopy.current.text("SQL 语句", "Query")) { result in
                WorkspaceExecutedSQLControl(sql: result.statement.sql)
            }
            .width(min: 180, ideal: 420)
            TableColumn(AppCopy.current.text("消息", "Message")) { result in
                Text(verbatim: result.statusMessage)
                    .foregroundStyle(result.state.reportColor)
                    .lineLimit(1)
                    .help(result.statusMessage)
            }
            .width(min: 100, ideal: 180)
            TableColumn(AppCopy.current.text("耗时", "Time")) { result in
                if result.didExecute {
                    Text(
                        "\(result.elapsedSeconds, format: .number.precision(.fractionLength(3))) s"
                    )
                    .monospacedDigit()
                } else {
                    Text("—")
                }
            }
            .width(min: 80, ideal: 100)
            TableColumn(AppCopy.current.text("行数", "Rows")) { result in
                Text(verbatim: result.rowCountMessage ?? "—")
                    .monospacedDigit()
            }
            .width(min: 110, ideal: 140)
        }
        .accessibilityIdentifier("queryExecutionSummary")
    }
}

private extension WorkspaceQueryExecutionState {
    var reportColor: Color {
        switch self {
        case .failed: .red
        case .stopped: .orange
        case .idle, .running, .skipped: .secondary
        case .completed: .primary
        }
    }
}
