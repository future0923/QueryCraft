struct WorkspaceStatementResult: Equatable, Sendable, Identifiable {
    let statement: SQLExecutionStatement
    var state: WorkspaceQueryExecutionState
    var elapsedSeconds: Double
    var maximumResultRows: Int? = nil

    var id: Int { statement.index }

    var hasRowResult: Bool { state.page?.columns.isEmpty == false }

    var statusMessage: String {
        switch state {
        case .idle: AppCopy.current.text("等待执行", "Pending")
        case .running: AppCopy.current.text("正在执行…", "Executing...")
        case .completed: "OK"
        case .stopped: AppCopy.current.text("已停止", "Stopped")
        case let .failed(message, _): message
        case let .skipped(reason): reason
        }
    }

    var rowCountMessage: String? {
        guard let page = state.page else { return nil }
        if hasRowResult {
            return AppCopy.current.text(
                "返回 \(page.rowCount) 行", "Returned \(page.rowCount) rows"
            )
        }
        guard case .completed = state else { return nil }
        return AppCopy.current.text(
            "影响 \(page.rowCount) 行", "Affected \(page.rowCount) rows"
        )
    }

    var didExecute: Bool {
        switch state {
        case .idle, .skipped: false
        case .running, .completed, .failed, .stopped: true
        }
    }
}
