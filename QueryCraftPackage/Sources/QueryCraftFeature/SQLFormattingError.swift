import Foundation

enum SQLFormattingError: LocalizedError, Equatable {
    case editorUnavailable
    case invalidSelection
    case sourceChanged
    case textCompositionActive
    case emptyDocument
    case parserUnavailable
    case noSQLInTarget
    case ambiguousSyntax
    case unsupportedStatement

    init(_ targetError: SQLExecutionTargetError) {
        switch targetError {
        case .editorUnavailable:
            self = .editorUnavailable
        case .invalidSelection:
            self = .invalidSelection
        case .sourceChanged, .currentStatementPending:
            self = .sourceChanged
        case .textCompositionActive:
            self = .textCompositionActive
        case .emptyDocument, .noExecutableStatement:
            self = .emptyDocument
        case .parserUnavailable:
            self = .parserUnavailable
        case .unreliableCurrentStatement:
            self = .ambiguousSyntax
        }
    }

    var errorDescription: String? {
        switch self {
        case .editorUnavailable:
            AppCopy.current.text("SQL 编辑器尚未就绪。", "The SQL editor is not ready yet.")
        case .invalidSelection:
            AppCopy.current.text("所选 SQL 已失效。", "The SQL selection is no longer valid.")
        case .sourceChanged:
            AppCopy.current.text(
                "格式化完成前 SQL 已发生变化，请重新格式化。",
                "The SQL changed before formatting finished. Format it again."
            )
        case .textCompositionActive:
            AppCopy.current.text(
                "请先完成文字输入，再格式化 SQL。",
                "Finish text composition before formatting SQL."
            )
        case .emptyDocument:
            AppCopy.current.text("请输入要格式化的 SQL 语句。", "Enter a SQL statement to format.")
        case .parserUnavailable:
            AppCopy.current.text(
                "SQL 解析不可用，无法继续格式化。",
                "SQL parsing is unavailable, so formatting cannot continue."
            )
        case .noSQLInTarget:
            AppCopy.current.text(
                "格式化目标中未找到 SQL 语法。",
                "No SQL syntax was found in the formatting target."
            )
        case .ambiguousSyntax:
            AppCopy.current.text(
                "所选 SQL 不完整或不受支持，因此未进行格式化。",
                "The selected SQL is incomplete or unsupported, so it was not formatted."
            )
        case .unsupportedStatement:
            AppCopy.current.text(
                "此语句不包含格式化工具支持的查询形式。",
                "This statement does not contain a query form supported by the formatter."
            )
        }
    }
}
