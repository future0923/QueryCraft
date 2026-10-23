import Foundation

protocol MobileSQLExecutionPlanning: Sendable {
    func plan(source: SQLSourceSnapshot, selection: NSRange) async throws -> SQLExecutionBatchPlan
    func planDocument(source: SQLSourceSnapshot) async throws -> SQLExecutionBatchPlan
}

extension MobileSQLExecutionPlanning {
    func planDocument(source: SQLSourceSnapshot) async throws -> SQLExecutionBatchPlan {
        try await MobileSQLExecutionPlanner().plan(source: source, selection: .init(location: 0, length: 0), request: .all)
    }
}

struct MobileSQLExecutionPlanner: MobileSQLExecutionPlanning {
    func plan(source: SQLSourceSnapshot, selection: NSRange) async throws -> SQLExecutionBatchPlan {
        try await plan(source: source, selection: selection, request: .selectionOrCurrentStatement)
    }
    func plan(source: SQLSourceSnapshot, selection: NSRange, request: SQLExecutionTargetRequest) async throws -> SQLExecutionBatchPlan {
        // One bounded parse per explicit run. Parser instances reject equal or
        // older revisions; isolated instances also keep rapid reruns independent.
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(source)
        try Task.checkCancellation()
        let target = try SQLExecutionTargetResolver.resolve(request,
            source: source, selectedRange: selection, parseSnapshot: snapshot)
        return try SQLExecutionBatchPreflight.makePlan(target: target, parseSnapshot: snapshot)
    }
}

enum MobileSQLExecutionError: LocalizedError {
    case documentTooLarge
    var errorDescription: String? {
        switch self {
        case .documentTooLarge: "SQL 文稿超过 256 KiB，请缩小文稿后执行。"
        }
    }
}
