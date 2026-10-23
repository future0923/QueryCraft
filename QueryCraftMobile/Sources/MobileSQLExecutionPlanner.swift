import Foundation

protocol MobileSQLExecutionPlanning: Sendable {
    func plan(source: SQLSourceSnapshot, selection: NSRange) async throws -> SQLExecutionBatchPlan
}

struct MobileSQLExecutionPlanner: MobileSQLExecutionPlanning {
    func plan(source: SQLSourceSnapshot, selection: NSRange) async throws -> SQLExecutionBatchPlan {
        // One bounded parse per explicit run. Parser instances reject equal or
        // older revisions; isolated instances also keep rapid reruns independent.
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(source)
        try Task.checkCancellation()
        let target = try SQLExecutionTargetResolver.resolve(.selectionOrCurrentStatement,
            source: source, selectedRange: selection, parseSnapshot: snapshot)
        return try SQLExecutionBatchPreflight.makePlan(target: target, parseSnapshot: snapshot)
    }
}

enum MobileSQLExecutionError: LocalizedError {
    case multipleStatements
    case documentTooLarge
    var errorDescription: String? {
        switch self {
        case .multipleStatements: "本次请选择一条查询，或将光标放到要执行的语句中。暂不支持一次运行多条 SQL。"
        case .documentTooLarge: "SQL 文稿超过 256 KiB，请缩小文稿后执行。"
        }
    }
}
