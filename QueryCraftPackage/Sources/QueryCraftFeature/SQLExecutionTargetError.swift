import Foundation

enum SQLExecutionTargetError: LocalizedError, Equatable {
    case editorUnavailable
    case invalidSelection
    case sourceChanged
    case textCompositionActive
    case emptyDocument
    case currentStatementPending
    case parserUnavailable
    case noExecutableStatement
    case unreliableCurrentStatement

    var errorDescription: String? {
        switch self {
        case .editorUnavailable:
            AppCopy.current.text("SQL 编辑器尚未就绪。", "The SQL editor is not ready yet.")
        case .invalidSelection:
            AppCopy.current.text("所选 SQL 已失效。", "The SQL selection is no longer valid.")
        case .sourceChanged:
            AppCopy.current.text(
                "确定当前语句前 SQL 已发生变化，请重新运行。",
                "The SQL changed before the current statement was resolved. Run it again."
            )
        case .textCompositionActive:
            AppCopy.current.text(
                "请先完成文字输入，再运行查询。",
                "Finish text composition before running the query."
            )
        case .emptyDocument:
            AppCopy.current.text("请输入要运行的 SQL 语句。", "Enter a SQL statement to run.")
        case .currentStatementPending:
            AppCopy.current.text(
                "仍在分析当前语句。",
                "The current statement is still being analyzed."
            )
        case .parserUnavailable:
            AppCopy.current.text(
                "SQL 解析不可用，无法确定当前语句。",
                "SQL parsing is unavailable, so the current statement cannot be determined."
            )
        case .noExecutableStatement:
            AppCopy.current.text(
                "光标位置未找到可执行语句。",
                "No executable statement was found at the cursor."
            )
        case .unreliableCurrentStatement:
            AppCopy.current.text(
                "无法可靠确定当前执行范围，请选择要运行的 SQL。",
                "The current execution range cannot be determined reliably. Select the SQL you want to run."
            )
        }
    }
}
