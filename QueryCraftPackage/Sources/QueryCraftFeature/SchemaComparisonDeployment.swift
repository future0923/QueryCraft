import Foundation
import Observation

@MainActor @Observable
final class SchemaComparisonDeployment {
    enum Phase { case idle, checking, running, succeeded, failed, cancelled }
    struct Record: Identifiable, Sendable {
        let id: Int
        let sql: String
        let startedAt: Date
        var finishedAt: Date?
        var error: String?
        var succeeded: Bool { finishedAt != nil && error == nil }
    }
    private(set) var phase = Phase.idle
    private(set) var records: [Record] = []
    private(set) var errorMessage: String?
    private(set) var total = 0
    private(set) var isStopping = false
    private(set) var isRollback = false
    private(set) var postDeploymentSnapshot: SchemaComparisonSnapshot?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let sessionFactory: any WorkspaceSessionFactory
    init(sessionFactory: any WorkspaceSessionFactory) { self.sessionFactory = sessionFactory }
    var isBusy: Bool { phase == .checking || phase == .running }
    var completed: Int { records.filter(\.succeeded).count }

    func start(statements: [String], sourceConfiguration: DatabaseConnectionConfiguration,
               targetConfiguration: DatabaseConnectionConfiguration, originalSource: SchemaComparisonSnapshot,
               originalTarget: SchemaComparisonSnapshot, options: SchemaComparisonOptions, rollback: Bool = false, selection: [SchemaComparisonDifference] = []) {
        guard !isBusy, !statements.isEmpty else { return }
        let expectedTarget = rollback ? postDeploymentSnapshot : originalTarget
        guard let expectedTarget else { return }
        phase = .checking; records = []; errorMessage = nil; total = statements.count; isStopping = false; isRollback = rollback
        task = Task { [weak self] in
            guard let self else { return }
            let loader = SchemaComparisonCatalogLoader(sessionFactory: sessionFactory, options: options)
            do {
                // Re-read immediately before execution. A stale reviewed plan is
                // rejected rather than silently regenerated into different SQL.
                async let currentTarget = loader.load(configuration: targetConfiguration) { _ in }
                let targetSnapshot = try await currentTarget
                guard Self.agrees(expectedTarget, targetSnapshot) else {
                    throw SchemaEngineFailure(AppCopy.current.text("目标结构已改变。请返回重新比较并审核新的 SQL。", "The target schema has changed. Recompare and review a new SQL plan."))
                }
                if !rollback {
                    let currentSource = try await loader.load(configuration: sourceConfiguration) { _ in }
                    guard Self.agrees(originalSource, currentSource) else {
                        throw SchemaEngineFailure(AppCopy.current.text("源结构已改变。请返回重新比较并审核新的 SQL。", "The source schema has changed. Recompare and review a new SQL plan."))
                    }
                }
                try Task.checkCancellation()
                let session = await sessionFactory.makeSession(configuration: targetConfiguration)
                do {
                    let connecting = Task { try await session.connect() }
                    try await connecting.value
                    try Task.checkCancellation()
                    phase = .running
                    for (index, sql) in statements.enumerated() {
                        try Task.checkCancellation()
                        records.append(.init(id: index, sql: sql, startedAt: .now))
                        do {
                            try await Self.execute(sql, session: session, database: targetConfiguration.database)
                            records[index].finishedAt = .now
                        } catch {
                            records[index].finishedAt = .now
                            records[index].error = error.localizedDescription
                            throw error
                        }
                    }
                    await session.close()
                } catch {
                    // Restore FK validation on the same owned connection even
                    // after cancellation/failure; close never returns it to an
                    // unrelated workspace session with checks disabled.
                    let cleanup = Task {
                        if statements.contains(where: { $0.uppercased().contains("FOREIGN_KEY_CHECKS = 0") }) {
                            try? await Self.execute("SET FOREIGN_KEY_CHECKS = 1", session: session, database: targetConfiguration.database)
                        }
                        await session.close()
                    }
                    await cleanup.value
                    throw error
                }
                // Success includes a successful fresh catalog read. This is also
                // the precondition for running the separately reviewed rollback.
                let rereading = Task { try await loader.load(configuration: targetConfiguration) { _ in } }
                postDeploymentSnapshot = try await rereading.value
                if let actual = postDeploymentSnapshot {
                    let verification = try await SchemaComparisonNativeEngine().analyze(source: rollback ? originalTarget : originalSource, target: actual, options: options, forVerification: true)
                    let pending = verification.differences.filter { $0.status != .equal }
                    let ids = Set(selection.map(\.id))
                    let atomicTables = Set(selection.filter { ["table", "view", "function"].contains($0.object) && $0.attributes.allSatisfy { $0.key != "name" } }.map(\.groupKey))
                    let unresolved = rollback ? pending : pending.filter { ids.contains($0.id) || atomicTables.contains($0.groupKey) }
                    if !unresolved.isEmpty {
                        throw SchemaEngineFailure(AppCopy.current.text("SQL 已执行，但回读仍有未满足的结构变更：", "SQL ran, but schema verification found unresolved changes: ") + unresolved.map { $0.table + "." + $0.displayName }.joined(separator: ", "))
                    }
                }
                phase = .succeeded
            } catch {
                phase = error is CancellationError ? .cancelled : .failed
                errorMessage = error is CancellationError
                    ? AppCopy.current.text("已停止。已完成的 MySQL DDL 已提交，请查看执行记录并重新比较。", "Stopped. Completed MySQL DDL has committed. Inspect the log and compare again.")
                    : error.localizedDescription
            }
            isStopping = false; task = nil
        }
    }
    nonisolated private static func execute(_ sql: String, session: any WorkspaceSession, database: String?) async throws {
        let tokens = try SchemaComparisonDDL.tokens(sql)
        let keywords = tokens.map(\.keyword)
        if keywords == ["SET", "FOREIGN_KEY_CHECKS", "=", "0"] || keywords == ["SET", "FOREIGN_KEY_CHECKS", "=", "1"] {
            // This exact session-only toggle performs no database write and is
            // legal inside MySQL's server-enforced read-only transaction. API 5
            // drivers cannot infer transaction state for arbitrary .control SQL.
            _ = try await session.executeReadOnlyQuery(sql, database: database) { _ in }
            return
        }
        let operation: SQLStatementKind.DDLOperation
        switch keywords.first {
        case "CREATE": operation = .create
        case "ALTER", "RENAME": operation = .alter
        case "DROP": operation = .drop
        default: throw SchemaEngineFailure(AppCopy.current.text("计划包含无法识别的结构变更语句。", "The plan contains an unrecognized schema statement."))
        }
        _ = try await session.executeStatement(sql, kind: .ddl(operation), database: database) { _ in }
    }

    func stop() { guard isBusy else { return }; isStopping = true; task?.cancel() }
    func wait() async { await task?.value }
    nonisolated static func agrees(_ expected: SchemaComparisonSnapshot, _ actual: SchemaComparisonSnapshot) -> Bool {
        guard expected.serverID == actual.serverID, expected.database == actual.database,
              expected.sqlMode == actual.sqlMode, expected.lowerCaseTableNames == actual.lowerCaseTableNames else { return false }
        func normalized(_ metadata: SchemaEngineJSON?) -> SchemaEngineJSON? {
            guard var metadata else { return nil }
            metadata["details"] = .array(metadata["details"].array.map { detail in
                var detail = detail
                if let definition = try? SchemaComparisonDDL(detail["ddl"].string) {
                    var tokens = SchemaComparisonDDL.canonical(definition.suffix)
                    if let i = tokens.firstIndex(of: "AUTO_INCREMENT"), i + 2 < tokens.count, tokens[i+1] == "=" { tokens.removeSubrange(i...i+2) }
                    detail["ddl"] = .string(definition.clauses.map(\.sql).joined(separator: ",") + tokens.joined(separator: " "))
                }
                return detail
            })
            return metadata
        }
        return normalized(expected.engineMetadata) == normalized(actual.engineMetadata)
    }
}
