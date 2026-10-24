import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

struct WorkspaceDataImportSchema: Equatable, Sendable {
    let columns: [WorkspaceDatabaseColumn]
    let tableParts: [String]
    let supportsRollback: Bool

    var writableColumns: [WorkspaceDatabaseColumn] { columns.filter { !$0.isGenerated } }

    func automaticMapping(_ source: [String]) -> [String?] {
        source.map { name in
            if writableColumns.contains(where: { $0.name == name }) { return name }
            let matches = writableColumns.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return matches.count == 1 ? matches[0].name : nil
        }
    }
}

struct WorkspaceDataImportPlan: Sendable {
    let file: WorkspaceDataImportFile
    let schema: WorkspaceDataImportSchema
    let mapping: [String?]
    let batchSize: Int
    let dialect: WorkspaceSQLExportDialect

    var mappedColumns: [(Int, WorkspaceDatabaseColumn)] {
        mapping.enumerated().compactMap { index, name in
            guard let column = schema.columns.first(where: { $0.name == name }) else { return nil }
            return (index, column)
        }
    }

    func validate(checkRows: Bool = true) throws {
        guard file.rowCount > 0 else { throw invalid("没有可导入的数据行。", "There are no rows to import.") }
        guard (1...10_000).contains(batchSize) else { throw invalid("每批行数须为 1～10000。", "Batch size must be between 1 and 10000.") }
        guard mapping.count == file.columns.count else { throw invalid("字段映射已失效，请重新加载。", "Column mapping is stale. Reload the preview.") }
        let names = mapping.compactMap { $0 }
        guard !names.isEmpty, Set(names).count == names.count else { throw invalid("至少映射一个字段，且目标字段不能重复。", "Map at least one column, without duplicate target columns.") }
        for name in names {
            guard schema.writableColumns.contains(where: { $0.name == name }) else { throw invalid("字段 \(name) 不可写入。", "Column \(name) is not writable.") }
        }
        for column in schema.writableColumns where !names.contains(column.name) {
            let automatic = column.extra.lowercased().contains("auto_increment") || column.extra.uppercased().contains("IDENTITY")
            guard column.isNullable || column.defaultValue != nil || automatic else {
                throw invalid("必填字段 \(column.name) 尚未映射，且没有默认值。", "Required column \(column.name) is unmapped and has no default.")
            }
        }
        if checkRows {
            let mapped = mappedColumns
            for start in stride(from: 0, to: file.rowCount, by: 512) {
                try Task.checkCancellation()
                let rows = try file.readRows(in: start..<min(start + 512, file.rowCount))
                for (index, row) in rows.enumerated() {
                    for (source, column) in mapped where !column.isNullable && row[source] == nil {
                        throw invalid("数据第 \(start + index + 1) 行的 \(column.name) 不允许 NULL。", "Data row \(start + index + 1): \(column.name) does not allow NULL.")
                    }
                }
            }
        }
        guard schema.supportsRollback else {
            throw invalid("目标表不支持已验证的事务回滚。当前导入支持 PostgreSQL 和 MySQL InnoDB 表。", "Transactional rollback is unavailable. Import supports PostgreSQL and MySQL InnoDB tables.")
        }
    }

    var prefix: String {
        let table = schema.tableParts.map(dialect.identifier).joined(separator: ".")
        let columns = mappedColumns.map { dialect.identifier($0.1.name) }.joined(separator: ", ")
        let identity = dialect == .postgresql && mappedColumns.contains(where: { $0.1.extra.uppercased().contains("IDENTITY") }) ? " OVERRIDING SYSTEM VALUE" : ""
        return "INSERT INTO \(table) (\(columns))\(identity) VALUES\n"
    }

    func statement(from start: Int, maximumBytes: Int? = nil) throws -> (sql: String, count: Int) {
        var sql = prefix, bytes = sql.utf8.count, count = 0
        let mapped = mappedColumns
        let rows = try file.readRows(in: start..<min(file.rowCount, start + batchSize))
        for (offset, row) in rows.enumerated() {
            let index = start + offset
            try Task.checkCancellation()
            let values = try mapped.map { column in
                var value = row[column.0]
                let type = column.1.type.lowercased()
                if dialect == .mysql, type == "bool" || type == "boolean" || type.hasPrefix("tinyint(1)") {
                    if value?.lowercased() == "true" { value = "1" }
                    if value?.lowercased() == "false" { value = "0" }
                }
                return try dialect.literal(value.map(WorkspaceDatabaseDataCell.text) ?? .null)
            }.joined(separator: ", ")
            let tuple = "(\(values))"
            let needed = tuple.utf8.count + (count == 0 ? 0 : 2)
            if let maximumBytes, bytes + needed + 1 > maximumBytes {
                guard count > 0 else { throw invalid("数据第 \(index + 1) 行超过语句大小上限。", "Data row \(index + 1) exceeds the statement size limit.") }
                break
            }
            if count > 0 { sql += ",\n" }
            sql += tuple; bytes += needed; count += 1
        }
        return (sql + ";", count)
    }

    private func invalid(_ zh: String, _ en: String) -> WorkspaceDataImportError { .invalid(zh, en) }
}

#if !os(iOS)
struct WorkspaceDataImportTarget: Sendable {
    let sessionFactory: any WorkspaceSessionFactory
    let configuration: DatabaseConnectionConfiguration
    let selection: WorkspaceDatabaseObjectSelection

    var dialect: WorkspaceSQLExportDialect { configuration.databaseType == .postgresql ? .postgresql : .mysql }
    static func supports(_ type: DatabaseType) -> Bool { type == .mysql || type == .postgresql }

    func schema(using session: any WorkspaceSession) async throws -> WorkspaceDataImportSchema {
        guard Self.supports(configuration.databaseType), selection.kind == .table,
              session.resolvedCapabilities.supportsDataEditing, session.resolvedCapabilities.supportsTransactions else {
            throw WorkspaceDataImportError.invalid("此驱动不支持表数据导入。", "This driver does not support table imports.")
        }
        var parts = [selection.databaseName, selection.objectName]
        if configuration.databaseType == .postgresql {
            _ = try await session.fetchObjects(in: selection.databaseName)
            let page = try await session.fetchDataPage(for: selection.object, in: selection.databaseName, offset: 0, limit: 1, sort: .none) { _ in }
            guard let origin = page.columns.compactMap(\.origin).first,
                  let schemaName = origin.schemaName, !schemaName.isEmpty else {
                throw WorkspaceDataImportError.invalid("无法确认目标表的 Schema，请重新连接后重试。", "Cannot resolve the target schema. Reconnect and try again.")
            }
            parts = [schemaName, origin.tableName]
        }
        let details = try await session.fetchDetails(for: selection.object, in: selection.databaseName)
        let rollback = configuration.databaseType == .postgresql || details.tableInformation?.engine?.caseInsensitiveCompare("InnoDB") == .orderedSame
        return WorkspaceDataImportSchema(columns: details.columns, tableParts: parts, supportsRollback: rollback)
    }

    func loadSchema() async throws -> WorkspaceDataImportSchema {
        let session = await sessionFactory.makeSession(configuration: configuration.selecting(database: selection.databaseName))
        do {
            try await session.connect()
            let result = try await schema(using: session)
            try Task.checkCancellation()
            await session.close()
            return result
        } catch { await session.close(); throw error }
    }
}

#endif

struct WorkspaceDataImportOutcome: Sendable {
    enum Status: Equatable, Sendable { case completed, cancelled, failed, uncertain }
    let status: Status
    let committedRows: Int?
    let message: String
}

actor WorkspaceDataImporter {
    typealias Authorize = @MainActor @Sendable () throws -> Void

    #if !os(iOS)
    func run(target: WorkspaceDataImportTarget, plan: WorkspaceDataImportPlan,
             authorize: @escaping Authorize, progress: @escaping @Sendable (Int) async -> Void) async -> WorkspaceDataImportOutcome {
        do { try plan.validate(); try await authorize(); try Task.checkCancellation() }
        catch {
            return .init(status: error is CancellationError ? .cancelled : .failed, committedRows: 0,
                         message: error.localizedDescription + "\n" + AppCopy.current.text("未提交数据。", "No data was committed."))
        }
        let session = await target.sessionFactory.makeSession(configuration: target.configuration.selecting(database: target.selection.databaseName))
        return await run(connection: WorkspaceSessionImportConnection(target: target, session: session), plan: plan, authorize: authorize, progress: progress)
    }
    #endif

    func run(connection: any WorkspaceDataImportConnection, plan: WorkspaceDataImportPlan,
             authorize: @escaping Authorize,
             progress: @escaping @Sendable (Int) async -> Void) async -> WorkspaceDataImportOutcome {
        var didConnect = false
        var transactionStarted = false, commitStarted = false
        do {
            try plan.validate()
            try await authorize()
            try Task.checkCancellation()
            didConnect = true
            try await connection.connect()
            let current = try await connection.schema()
            guard current == plan.schema else { throw WorkspaceDataImportError.invalid("目标表结构已变化，请重新加载预览。", "Target schema changed. Reload the preview.") }
            try await authorize()
            try Task.checkCancellation()
            try await connection.prepare()
            _ = try await connection.execute("START TRANSACTION", kind: .transaction(.begin))
            transactionStarted = true
            var completed = 0
            while completed < plan.file.rowCount {
                try Task.checkCancellation()
                try await authorize()
                let batch = try plan.statement(from: completed)
                let rows = try await connection.execute(batch.sql, kind: .insert)
                guard rows == batch.count else {
                    throw WorkspaceDataImportError.invalid("实际写入行数与预期不符，已停止导入。", "The affected row count differs from the import batch. Import stopped.")
                }
                completed += batch.count
                await progress(completed)
            }
            try Task.checkCancellation()
            try await authorize()
            commitStarted = true
            // Commit/rollback must finish even if the UI requests cancellation while awaiting them.
            _ = try await Task {
                try await connection.execute("COMMIT", kind: .transaction(.commit))
            }.value
            await connection.close()
            return .init(status: .completed, committedRows: completed, message: AppCopy.current.text("已导入 \(completed) 行。", "Imported \(completed) rows."))
        } catch {
            var rollbackConfirmed = !transactionStarted
            if didConnect {
                if transactionStarted && !commitStarted {
                    rollbackConfirmed = await Task {
                        do {
                            _ = try await connection.execute("ROLLBACK", kind: .transaction(.rollback))
                            return true
                        } catch { return false }
                    }.value
                }
                await connection.close()
            }
            if commitStarted || !rollbackConfirmed {
                return .init(status: .uncertain, committedRows: nil, message: AppCopy.current.text("无法确认事务结果，请核对目标表后再决定是否重试。", "The transaction outcome is unknown. Check the target table before retrying.") + "\n" + error.localizedDescription)
            }
            let cancelled = error is CancellationError
            return .init(status: cancelled ? .cancelled : .failed, committedRows: 0,
                message: (cancelled ? AppCopy.current.text("已取消，未提交数据。", "Cancelled. No data was committed.") : error.localizedDescription + "\n" + AppCopy.current.text("未提交数据。", "No data was committed.")))
        }
    }
}

private actor ImportSQLModeCheck {
    private(set) var isStrict = false
    func receive(_ batch: WorkspaceDatabaseDataBatch) {
        guard let row = batch.rows.first, case let .text(value) = row.value(at: 0) else { return }
        isStrict = value.uppercased().split(separator: ",").contains("STRICT_ALL_TABLES")
    }
}


protocol WorkspaceDataImportConnection: Sendable {
    func connect() async throws
    func schema() async throws -> WorkspaceDataImportSchema
    func prepare() async throws
    func execute(_ sql: String, kind: SQLStatementKind) async throws -> Int
    func close() async
}
#if !os(iOS)
private struct WorkspaceSessionImportConnection: WorkspaceDataImportConnection {
    let target: WorkspaceDataImportTarget
    let session: any WorkspaceSession
    func connect() async throws { try await session.connect() }
    func schema() async throws -> WorkspaceDataImportSchema { try await target.schema(using: session) }
    func execute(_ sql: String, kind: SQLStatementKind) async throws -> Int {
        try await session.executeStatement(sql, kind: kind, database: target.selection.databaseName) { _ in }.rowCount
    }
    func close() async { await session.close() }
    func prepare() async throws {
            if target.configuration.databaseType == .mysql {
                do {
                    _ = try await session.executeStatement("SET SESSION sql_mode = CONCAT_WS(',', @@SESSION.sql_mode, 'STRICT_ALL_TABLES')", kind: .control, database: target.selection.databaseName) { _ in }
                } catch WorkspaceSessionError.transactionStateUnavailable {
                    // Older drivers execute SET successfully but cannot infer its transaction
                    // state. Verify the actual mode before beginning our own transaction.
                }
                let mode = ImportSQLModeCheck()
                _ = try await session.executeStatement("SELECT @@SESSION.sql_mode", kind: .read, database: target.selection.databaseName) { await mode.receive($0) }
                guard await mode.isStrict else {
                    throw WorkspaceDataImportError.invalid("无法确认 MySQL 严格模式，已停止导入。", "Cannot verify MySQL strict mode. Import stopped.")
                }
            }
    }
}
#endif
