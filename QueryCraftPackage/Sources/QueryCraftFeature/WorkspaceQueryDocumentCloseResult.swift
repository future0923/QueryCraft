import Foundation

enum WorkspaceQueryDocumentCloseResult: Equatable, Sendable {
    case closed
    case needsUnsavedChangesDecision
    case failed(message: String)
}

enum WorkspaceQueryDocumentError: LocalizedError, Equatable {
    case cancellationRequiresDisconnect
    case executionInProgress
    case rollbackDidNotEndTransaction
    case saveInProgress

    var errorDescription: String? {
        switch self {
        case .cancellationRequiresDisconnect:
            AppCopy.current.text(
                "无法取消上一个查询。请先断开此会话，再运行其他语句。",
                "The previous query could not be cancelled. Disconnect this session before running another statement."
            )
        case .executionInProgress:
            AppCopy.current.text(
                "请先停止正在运行的查询，再关闭此查询文档。",
                "Stop the active query before closing this Query Document."
            )
        case .rollbackDidNotEndTransaction:
            AppCopy.current.text(
                "执行 ROLLBACK 后，服务器仍报告存在活动事务。",
                "The server still reports an active transaction after ROLLBACK."
            )
        case .saveInProgress:
            AppCopy.current.text(
                "请等待此查询文档保存完成后再关闭。",
                "Wait for this Query Document to finish saving before closing it."
            )
        }
    }
}
