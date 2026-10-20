import Foundation

enum TransferRunStatus: String, Codable, Sendable {
    case queued, running, cancelling, completed, partial, failed, cancelled, uncertain, interrupted
    var isActive: Bool { [.queued, .running, .cancelling].contains(self) }
    var title: String {
        switch self {
        case .queued: AppCopy.current.text("排队中", "Queued")
        case .running: AppCopy.current.text("传输中", "Running")
        case .cancelling: AppCopy.current.text("正在取消", "Cancelling")
        case .completed: AppCopy.current.text("全部成功", "Completed")
        case .partial: AppCopy.current.text("部分成功", "Partially completed")
        case .failed: AppCopy.current.text("失败", "Failed")
        case .cancelled: AppCopy.current.text("已取消", "Cancelled")
        case .uncertain: AppCopy.current.text("结果未知，请核对目标", "Outcome unknown; verify the target")
        case .interrupted: AppCopy.current.text("上次运行中断，请核对目标", "Interrupted; verify the target")
        }
    }
}

struct TransferItemProgress: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    var status = TransferRunStatus.queued
    var readRows = 0
    var committedRows = 0
    var message = ""
}

struct TransferRunRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let sourceLabel: String
    let targetLabel: String
    let createdAt: Date
    var finishedAt: Date?
    var status = TransferRunStatus.queued
    var items: [TransferItemProgress]
    var message = ""
    var backupTables: [String] = []
    var committedRows: Int { items.reduce(0) { $0 + $1.committedRows } }
}

struct DataTransferRunner: Sendable {
    typealias Authorize = @MainActor @Sendable () throws -> Void
    let catalog: DataTransferCatalog
    init(catalog: DataTransferCatalog = .init()) { self.catalog = catalog }

    func run(_ original: DataTransferPlan, authorize: @escaping Authorize,
             progress: @escaping @Sendable (TransferItemProgress) async -> Void,
             backups: @escaping @Sendable ([String]) async -> Void) async -> (TransferRunStatus, String) {
        var source: (any WorkspaceSession)?, target: (any WorkspaceSession)?
        var transaction = false, commitStarted = false, globalOverwrite = false
        var committed: Set<String> = [], failed: Set<String> = [], renamed: [String] = []
        var updates: [String: TransferItemProgress] = [:]
        var pendingOverwrite: [String: Int] = [:]
        let configuration = original.configuration
        func execute(_ sql: String, _ kind: SQLStatementKind, session: any WorkspaceSession, database: String) async throws {
            _ = try await session.executeStatement(sql, kind: kind, database: database) { _ in }
        }
        do {
            try await authorize(); try Task.checkCancellation()
            // Regenerate the exact reviewed plan. Metadata changes require a new preview.
            let current = try await DataTransferPlanner(catalog: catalog).prepare(configuration: configuration, source: original.source, target: original.target, ownership: original.ownership, id: original.id)
            guard current.sql == original.sql, current.items.count == original.items.count,
                  current.sourceServerIdentity == original.sourceServerIdentity, current.targetServerIdentity == original.targetServerIdentity,
                  current.mysqlNoBackslashEscapes == original.mysqlNoBackslashEscapes,
                  zip(current.items, original.items).allSatisfy({ $0.existed == $1.existed && $0.sourceColumns == $1.sourceColumns && $0.targetColumns == $1.targetColumns }) else {
                throw TransferFailure("源或目标结构已变化，请重新预览后执行。", "The source or target schema changed. Preview the plan again.")
            }
            guard current.missingOwners.isEmpty || current.ownership != .preserve else { throw TransferFailure("目标缺少所有者角色，请先选择所有者处理方式。", "Owner roles are missing on the target. Choose an ownership policy first.") }
            let read = try await catalog.open(current.source); source = read
            let write = try await catalog.open(current.target); target = write
            try await configure(read, connection: current.source, timeout: configuration.operationTimeoutSeconds, target: false)
            try await configure(write, connection: current.target, timeout: configuration.operationTimeoutSeconds, target: true, noBackslashEscapes: current.mysqlNoBackslashEscapes)
            try await authorize(); try Task.checkCancellation()
            for statement in current.setupStatements {
                try Task.checkCancellation(); try await authorize()
                try await execute(statement, .ddl(.create), session: write, database: current.target.endpoint.database)
            }
            if configuration.content != .structureOnly && current.source.type != .doris {
                let begin = current.source.type == .postgresql ? "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY" : "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY"
                try await execute(begin, .transaction(.begin), session: read, database: current.source.endpoint.database)
            }
            let rebuild = current.items.filter { $0.backupName != nil }
            if !rebuild.isEmpty {
                try await authorize(); try Task.checkCancellation()
                if current.target.type == .mysql {
                    let pairs = rebuild.reversed().map { item in
                        "\(TransferSQL.qualified(current.target.endpoint, item.targetName, type: .mysql)) TO \(TransferSQL.qualified(current.target.endpoint, item.backupName!, type: .mysql))"
                    }
                    try await execute("RENAME TABLE " + pairs.joined(separator: ", "), .ddl(.alter), session: write, database: current.target.endpoint.database)
                } else {
                    try await execute("BEGIN", .transaction(.begin), session: write, database: current.target.endpoint.database); transaction = true
                    for item in rebuild.reversed() {
                        do {
                            try await execute("ALTER TABLE \(TransferSQL.qualified(current.target.endpoint, item.targetName, type: .postgresql)) RENAME TO \(TransferSQL.dialect(.postgresql).identifier(item.backupName!))", .ddl(.alter), session: write, database: current.target.endpoint.database)
                        } catch WorkspaceSessionError.transactionStateUnavailable {
                            // The driver reports this after successful DDL inside an explicit
                            // transaction; our transaction ownership remains unchanged.
                        }
                    }
                    commitStarted = true
                    try await finishTransaction("COMMIT", operation: .commit, session: write, database: current.target.endpoint.database)
                    transaction = false; commitStarted = false
                }
                renamed = rebuild.compactMap(\.backupName); await backups(renamed)
            }

            // Finish all CREATE operations before any data transaction: MySQL DDL commits implicitly.
            for item in current.items {
                if item.object.kind.order > TransferObjectKind.table.order { continue }
                try Task.checkCancellation(); try await authorize()
                var update = TransferItemProgress(id: item.object.id, name: item.object.name, status: .running)
                updates[update.id] = update; await progress(update)
                do {
                    for statement in item.statements {
                        try Task.checkCancellation(); try await authorize()
                        try await execute(statement, .ddl(.create), session: write, database: current.target.endpoint.database)
                    }
                    if item.object.kind != .table || configuration.content == .structureOnly {
                        update.status = .completed
                        if item.statements.isEmpty { update.message = AppCopy.current.text("已有对象已保留；未比较结构。", "Existing object kept; its structure was not compared.") }
                        committed.insert(item.object.id)
                    }
                } catch {
                    if error is CancellationError { throw error }
                    failed.insert(item.object.id); update.status = .failed; update.message = error.localizedDescription
                }
                updates[update.id] = update; await progress(update)
            }
            let dataItems = current.items.filter { $0.object.kind == .table && configuration.content != .structureOnly && !failed.contains($0.object.id) }
            // Overwrite clears related tables and inserts all selected rows in one transaction.
            // This avoids committing a child-table DELETE before a later parent-table failure.
            globalOverwrite = configuration.strategy == .overwrite && !dataItems.isEmpty
            if globalOverwrite {
                guard failed.isEmpty else { throw TransferFailure("结构准备失败，覆盖操作未开始。", "Structure preparation failed; overwrite did not start.") }
                try await execute("BEGIN", .transaction(.begin), session: write, database: current.target.endpoint.database); transaction = true
                for item in dataItems.reversed() {
                    try Task.checkCancellation(); try await authorize()
                    try await execute("DELETE FROM \(TransferSQL.qualified(current.target.endpoint, item.targetName, type: current.target.type))", .delete(hasWhereClause: false), session: write, database: current.target.endpoint.database)
                }
            }
            let maximumBytes = try await writeLimit(write, connection: current.target)
            let nativeSession = write as? any WorkspaceNativeBulkTransferSession
            let nativeFormat = try await nativeSession?.nativeBulkTransferFormat()
            for item in dataItems {
                try Task.checkCancellation(); try await authorize()
                var update = updates[item.object.id] ?? .init(id: item.object.id, name: item.object.name)
                let nativeCounter = TransferBulkRowCounter()
                let failedNames = Set(current.items.filter { failed.contains($0.object.id) }.map { $0.object.name })
                if !Set(item.dependencies).isDisjoint(with: failedNames) {
                    update.status = .failed; update.message = AppCopy.current.text("依赖对象失败，已跳过。", "Skipped because a dependency failed.")
                    failed.insert(item.object.id); updates[update.id] = update; await progress(update); continue
                }
                do {
                    guard !item.sourceColumns.filter({ !$0.isGenerated }).isEmpty else { throw TransferFailure("没有可写入的来源字段。", "The source has no writable columns.") }
                    let observed = try await DataTransferCatalog.columns(item.object, connection: current.source, session: read)
                    guard observed == item.sourceColumns else { throw TransferFailure("来源字段在执行期间发生变化。", "Source columns changed during execution.") }
                    try await DataTransferCatalog.requireTransactionalTable(item.targetName, connection: current.target, session: write)
                    if !globalOverwrite {
                        try await execute("BEGIN", .transaction(.begin), session: write, database: current.target.endpoint.database); transaction = true
                    }
                    let columns = item.sourceColumns.filter { !$0.isGenerated }
                    let sourceKeys = item.sourceColumns.filter { $0.key == "PRI" }.map(\.name)
                    let filter = configuration.tableFilters[item.object.name] ?? ""
                    let paginationKey = try TransferSQL.paginationKey(columns: item.sourceColumns, type: current.source.type, filter: filter)
                    let keyIndex = paginationKey.flatMap { key in columns.firstIndex { $0.name == key.name } }
                    var bulkAllowed = false
                    if nativeSession != nil, nativeFormat != nil {
                        bulkAllowed = try await permitsNativeBulk(item, connection: current.target, strategy: configuration.strategy, session: write)
                    }
                    var staging: TransferBulkStaging?
                    if bulkAllowed && configuration.strategy == .upsert {
                        let candidate = try TransferBulkStaging(item: item, target: current.target, columns: columns)
                        if try await prepareNativeStaging(candidate, session: write, database: current.target.endpoint.database) { staging = candidate }
                        else { bulkAllowed = false }
                    }
                    if bulkAllowed, let nativeSession, let nativeFormat {
                        let encoder = try TransferBulkEncoder(columns: columns + (staging.map { [$0.ordinal] } ?? []),
                                                              targetColumns: item.targetColumns + (staging.map { [$0.ordinal] } ?? []),
                                                              sourceType: current.source.type, targetType: current.target.type,
                                                              endpoint: staging?.endpoint ?? current.target.endpoint, name: staging?.name ?? item.targetName, format: nativeFormat)
                        update.message = AppCopy.current.text(current.target.type == .postgresql ? "原生 COPY 流式写入" : "原生 LOAD DATA 流式写入",
                                                              current.target.type == .postgresql ? "Native streaming COPY" : "Native streaming LOAD DATA")
                        await progress(update)
                        let initial = update
                        update.readRows = try await transferNative(encoder: encoder, writer: nativeSession, source: read,
                                                                  item: item, plan: current, columns: columns, filter: filter,
                                                                  sourceKeys: sourceKeys, paginationKey: paginationKey,
                                                                  keyIndex: keyIndex, counter: nativeCounter, staging: staging, authorize: authorize) { count in
                            var next = initial; next.readRows = count; await progress(next)
                        }
                        if let staging {
                            update.message += AppCopy.current.text("；正在合并暂存数据", "; merging staged data")
                            await progress(update)
                            for offset in stride(from: 0, to: update.readRows, by: configuration.batchSize) {
                                try Task.checkCancellation(); try await authorize()
                                try await execute(staging.merge(offset: offset, count: min(configuration.batchSize, update.readRows - offset)), .insert,
                                                  session: write, database: current.target.endpoint.database)
                            }
                            do { try await execute(staging.drop, .ddl(.drop), session: write, database: current.target.endpoint.database) }
                            catch WorkspaceSessionError.transactionStateUnavailable { }
                            update.message = initial.message + AppCopy.current.text("；暂存数据已合并", "; staged data merged")
                        }
                    } else {
                    let insertEncoder = try TransferSQL.InsertEncoder(columns: columns, targetColumns: item.targetColumns,
                                                                     sourceType: current.source.type, targetType: current.target.type,
                                                                     endpoint: current.target.endpoint, name: item.targetName,
                                                                     strategy: configuration.strategy, keys: item.primaryKey)
                    if current.target.type == .mysql, let nativeSource = read as? any WorkspaceNativeRowSourceSession {
                        update.message = AppCopy.current.text("流式读取，批量 INSERT 写入", "Streamed reads; batched INSERT")
                        let initial = update; await progress(update)
                        update.readRows = try await transferStreamedInserts(source: nativeSource, writer: write, encoder: insertEncoder,
                                                                           item: item, plan: current, columns: columns, filter: filter,
                                                                           sourceKeys: sourceKeys, maximumBytes: maximumBytes,
                                                                           counter: nativeCounter, authorize: authorize) { count in
                            var next = initial; next.readRows = count; await progress(next)
                        }
                    } else {
                    var after: String?
                    var offset = 0
                    while true {
                        try Task.checkCancellation(); try await authorize()
                        let sql = try TransferSQL.select(object: item.object, columns: columns, endpoint: current.source.endpoint, type: current.source.type, filter: filter, order: sourceKeys, offset: offset, limit: configuration.batchSize, paginationKey: paginationKey, after: after)
                        let page = try await DataTransferCatalog.query(sql, session: read, database: current.source.endpoint.database)
                        guard page.columns.map(\.name) == columns.map(\.name) else { throw TransferFailure("过滤查询必须返回全部可写字段，并保持原始字段名。", "The filter query must return all writable fields with their original names.") }
                        if page.rows.isEmpty { break }
                        var start = 0
                        while start < page.rows.count {
                            try Task.checkCancellation(); try await authorize()
                            var length = page.rows.count - start, statement = ""
                            while true {
                                statement = try insertEncoder.statement(rows: page.rows[start..<(start + length)])
                                if statement.utf8.count <= maximumBytes { break }
                                guard length > 1 else { throw TransferFailure("单行数据超过目标数据库包大小上限。", "One row exceeds the target database packet limit.") }
                                length = max(1, length / 2)
                            }
                            try await execute(statement, .insert, session: write, database: current.target.endpoint.database)
                            start += length
                        }
                        if let keyIndex, let last = page.rows.last {
                            guard case let .text(value) = last.values[keyIndex] else {
                                throw TransferFailure("来源主键值为空或不完整。", "The source primary key is null or incomplete.")
                            }
                            after = value
                        }
                        offset += page.rows.count; update.readRows = offset
                        updates[update.id] = update; await progress(update)
                        if page.rows.count < configuration.batchSize { break }
                    }
                    }
                    }
                    try await advanceIdentity(item, connection: current.target, session: write)
                    try Task.checkCancellation(); try await authorize()
                    if globalOverwrite { pendingOverwrite[item.object.id] = update.readRows }
                    else {
                        commitStarted = true
                        try await finishTransaction("COMMIT", operation: .commit, session: write, database: current.target.endpoint.database)
                        transaction = false; commitStarted = false
                        update.status = .completed; update.committedRows = update.readRows; committed.insert(item.object.id)
                    }
                } catch {
                    let error: any Error = Task.isCancelled ? CancellationError() : error
                    update.readRows = max(update.readRows, await nativeCounter.value)
                    updates[update.id] = update
                    if commitStarted { throw error }
                    if globalOverwrite { throw error }
                    if transaction {
                        try await finishTransaction("ROLLBACK", operation: .rollback, session: write, database: current.target.endpoint.database); transaction = false
                    }
                    if error is CancellationError { throw error }
                    update.status = .failed; update.message = error.localizedDescription
                    failed.insert(item.object.id)
                }
                updates[update.id] = update; await progress(update)
            }
            if globalOverwrite {
                try Task.checkCancellation(); try await authorize(); commitStarted = true
                try await finishTransaction("COMMIT", operation: .commit, session: write, database: current.target.endpoint.database)
                transaction = false; commitStarted = false
                for (id, count) in pendingOverwrite {
                    var update = updates[id]!
                    update.status = .completed; update.committedRows = count
                    updates[id] = update; committed.insert(id); await progress(update)
                }
            }
            for item in current.items where !failed.contains(item.object.id) {
                do {
                    for key in item.foreignKeys {
                        try Task.checkCancellation(); try await authorize()
                        try await execute(key.sql, .ddl(.alter), session: write, database: current.target.endpoint.database)
                    }
                } catch {
                    if error is CancellationError { throw error }
                    failed.insert(item.object.id)
                    var update = updates[item.object.id]!
                    update.status = .failed; update.message = error.localizedDescription
                    updates[update.id] = update; await progress(update)
                }
            }
            // Install views, materialized views, triggers and events after historical
            // data is written. Newly copied triggers must not fire on that data, and
            // materialized views must see the completed target contents.
            for item in current.items where item.object.kind.order > TransferObjectKind.table.order {
                try Task.checkCancellation(); try await authorize()
                var update = TransferItemProgress(id: item.object.id, name: item.object.name, status: .running)
                await progress(update)
                let failedNames = Set(current.items.filter { failed.contains($0.object.id) }.map { $0.object.name })
                do {
                    guard Set(item.dependencies).isDisjoint(with: failedNames) else { throw TransferFailure("依赖对象失败，已跳过。", "Skipped because a dependency failed.") }
                    for statement in item.statements {
                        try Task.checkCancellation(); try await authorize()
                        try await execute(statement, .ddl(.create), session: write, database: current.target.endpoint.database)
                    }
                    update.status = .completed; committed.insert(item.object.id)
                    if item.statements.isEmpty { update.message = AppCopy.current.text("已有对象已保留；未比较结构。", "Existing object kept; its structure was not compared.") }
                } catch {
                    if error is CancellationError { throw error }
                    update.status = .failed; update.message = error.localizedDescription; failed.insert(item.object.id)
                }
                updates[update.id] = update; await progress(update)
            }
            for sql in current.ownershipStatements {
                try Task.checkCancellation(); try await authorize()
                try await execute(sql, .ddl(.alter), session: write, database: current.target.endpoint.database)
            }
            // Never remove original backups if any table, constraint or object failed.
            if failed.isEmpty {
                for item in current.items.reversed() where item.backupName != nil {
                    try Task.checkCancellation(); try await authorize()
                    try await execute("DROP TABLE \(TransferSQL.qualified(current.target.endpoint, item.backupName!, type: current.target.type))", .ddl(.drop), session: write, database: current.target.endpoint.database)
                    renamed.removeAll { $0 == item.backupName }; await backups(renamed)
                }
            }
            await read.close(); await write.close()
            return (failed.isEmpty ? .completed : committed.isEmpty ? .failed : .partial,
                    failed.isEmpty ? AppCopy.current.text("所选对象已完成传输。", "All selected objects were transferred.") : AppCopy.current.text("部分对象失败，请检查逐项结果和保留的备份。", "Some objects failed. Review item results and retained backups."))
        } catch {
            let error: any Error = Task.isCancelled ? CancellationError() : error
            var rollbackConfirmed = !transaction
            if let target, transaction && !commitStarted {
                do { try await finishTransaction("ROLLBACK", operation: .rollback, session: target, database: original.target.endpoint.database); rollbackConfirmed = true }
                catch { rollbackConfirmed = false }
            }
            let uncertain = commitStarted || !rollbackConfirmed
            for item in original.items where !committed.contains(item.object.id) && !failed.contains(item.object.id) {
                var update = updates[item.object.id] ?? .init(id: item.object.id, name: item.object.name)
                update.status = uncertain ? .uncertain : error is CancellationError ? .cancelled : .failed
                update.committedRows = 0; update.message = error.localizedDescription
                await progress(update)
            }
            await source?.close(); await target?.close()
            let message = uncertain
                ? AppCopy.current.text("提交或回滚结果未知。请核对目标数据，不要直接重试。", "Commit or rollback outcome is unknown. Verify target data before retrying.")
                : error is CancellationError
                    ? AppCopy.current.text("已取消；当前事务已回滚，之前提交的数据和已创建的结构仍保留。", "Cancelled. The current transaction was rolled back; earlier committed data and created structures remain.")
                    : error.localizedDescription
            return (uncertain ? .uncertain : error is CancellationError ? .cancelled : committed.isEmpty ? .failed : .partial, message)
        }
    }

    private func permitsNativeBulk(_ item: TransferPlanItem, connection: TransferConnection,
                                   strategy: TransferStrategy, session: any WorkspaceSession) async throws -> Bool {
        guard connection.type == .postgresql else { return connection.type == .mysql }
        // COPY does not support RLS and does not execute INSERT rules. Statement
        // triggers also observe a different batch boundary, so retain INSERT there.
        let relation = try TransferSQL.string(TransferSQL.qualified(connection.endpoint, item.targetName, type: .postgresql), type: .postgresql)
        let result = try await DataTransferCatalog.query("SELECT (NOT c.relrowsecurity AND NOT EXISTS (SELECT 1 FROM pg_rewrite r WHERE r.ev_class=c.oid) AND NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal AND (t.tgtype::int & 1)=0))::text AS allowed FROM pg_class c WHERE c.oid=\(relation)::regclass", session: session, database: connection.endpoint.database)
        guard let row = result.rows.first else { return false }
        return ["true", "t"].contains(result.text(row, "allowed") ?? "")
    }

    private enum BulkResult: Sendable { case source(Int), target(Int) }

    private func prepareNativeStaging(_ staging: TransferBulkStaging, session: any WorkspaceSession, database: String) async throws -> Bool {
        let point = "qc_bulk_" + UUID().uuidString.prefix(8).lowercased()
        func checkpoint(_ sql: String) async throws {
            _ = try await session.executeStatement(sql, kind: .transaction(.savepoint), database: database) { _ in }
        }
        try await checkpoint("SAVEPOINT " + point)
        do {
            for sql in [staging.create, staging.createIndex].compactMap({ $0 }) {
                do { _ = try await session.executeStatement(sql, kind: .ddl(.create), database: database) { _ in } }
                catch WorkspaceSessionError.transactionStateUnavailable { }
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // TEMP/SELECT privileges or proxy restrictions may disallow staging.
            // No destination data has been written. Restore the transaction before
            // starting ordinary INSERT; PostgreSQL errors otherwise leave it aborted.
            try await checkpoint("ROLLBACK TO SAVEPOINT " + point)
            try await checkpoint("RELEASE SAVEPOINT " + point)
            return false
        }
        try await checkpoint("RELEASE SAVEPOINT " + point)
        return true
    }

    private func transferStreamedInserts(source: any WorkspaceNativeRowSourceSession, writer: any WorkspaceSession,
                                         encoder: TransferSQL.InsertEncoder, item: TransferPlanItem, plan: DataTransferPlan,
                                         columns: [WorkspaceDatabaseColumn], filter: String, sourceKeys: [String], maximumBytes: Int,
                                         counter: TransferBulkRowCounter, authorize: @escaping Authorize,
                                         progress: @escaping @Sendable (Int) async -> Void) async throws -> Int {
        let sql = try TransferSQL.select(object: item.object, columns: columns, endpoint: plan.source.endpoint,
                                         type: plan.source.type, filter: filter, order: sourceKeys, offset: 0, limit: nil, preserveOrder: true)
        return try await source.streamTransferRows(sql: sql, batchSize: plan.configuration.batchSize) { batch in
            guard batch.columns.map(\.name) == columns.map(\.name) else {
                throw TransferFailure("来源字段在执行期间发生变化。", "Source columns changed during execution.")
            }
            var start = 0
            while start < batch.rows.count {
                try Task.checkCancellation(); try await authorize()
                var length = batch.rows.count - start, statement = ""
                while true {
                    statement = try encoder.statement(rows: batch.rows[start..<(start + length)])
                    if statement.utf8.count <= maximumBytes { break }
                    guard length > 1 else { throw TransferFailure("单行数据超过目标数据库包大小上限。", "One row exceeds the target database packet limit.") }
                    length = max(1, length / 2)
                }
                _ = try await writer.executeStatement(statement, kind: .insert, database: plan.target.endpoint.database) { _ in }
                start += length
            }
            let (count, report) = await counter.add(batch.rows.count)
            if report { await progress(count) }
        }
    }

    private func transferNative(encoder: TransferBulkEncoder, writer: any WorkspaceNativeBulkTransferSession,
                                source: any WorkspaceSession, item: TransferPlanItem, plan: DataTransferPlan,
                                columns: [WorkspaceDatabaseColumn], filter: String, sourceKeys: [String],
                                paginationKey: WorkspaceDatabaseColumn?, keyIndex: Int?, counter: TransferBulkRowCounter, staging: TransferBulkStaging?,
                                authorize: @escaping Authorize,
                                progress: @escaping @Sendable (Int) async -> Void) async throws -> Int {
        let stream = WorkspaceNativeBulkStream()
        let targetByName = Dictionary(uniqueKeysWithValues: item.targetColumns.map { ($0.name, $0) })
        // A full SELECT can change a column's result type while retaining its name.
        // It must pass through the cell encoders (notably bytea validation) rather
        // than relaying arbitrary text into the destination's binary/text types.
        let readsOriginalColumns = try TransferSQL.tokens(filter).first?.value.uppercased() != "SELECT"
        let directCopy = staging == nil && readsOriginalColumns && plan.source.type == .postgresql && plan.target.type == .postgresql
            && columns.allSatisfy { targetByName[$0.name]?.type == $0.type }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: BulkResult.self) { group in
                group.addTask {
                    do {
                        if directCopy, let nativeSource = source as? any WorkspaceNativeCopySourceSession {
                            try Task.checkCancellation(); try await authorize()
                            let select = try TransferSQL.select(object: item.object, columns: columns, endpoint: plan.source.endpoint,
                                                                type: plan.source.type, filter: filter, order: [], offset: 0, limit: nil)
                            let rows = try await nativeSource.executeNativeCopyOut(sql: "COPY (\(select)) TO STDOUT WITH (FORMAT text, ENCODING 'UTF8')", stream: stream) { count in
                                if await counter.report(count) { await progress(count) }
                            }
                            stream.finish(); return .source(rows)
                        }
                        if let nativeSource = source as? any WorkspaceNativeRowSourceSession {
                            try Task.checkCancellation(); try await authorize()
                            let select = try TransferSQL.select(object: item.object, columns: columns, endpoint: plan.source.endpoint,
                                                                type: plan.source.type, filter: filter, order: sourceKeys, offset: 0, limit: nil,
                                                                preserveOrder: staging != nil)
                            let rows = try await nativeSource.streamTransferRows(sql: select, batchSize: plan.configuration.batchSize) { batch in
                                try Task.checkCancellation(); try await authorize()
                                guard batch.columns.map(\.name) == columns.map(\.name) else {
                                    throw TransferFailure("来源字段在执行期间发生变化。", "Source columns changed during execution.")
                                }
                                let offset = await counter.value
                                let rows = staging == nil ? batch.rows : batch.rows.enumerated().map { index, row in
                                    WorkspaceDatabaseDataRow(id: row.id, values: row.values + [.text(String(offset + index + 1))])
                                }
                                try await encoder.send(rows: rows, to: stream)
                                let (count, report) = await counter.add(batch.rows.count)
                                if report { await progress(count) }
                            }
                            stream.finish(); return .source(rows)
                        }
                        var offset = 0, after: String?
                        while true {
                            try Task.checkCancellation(); try await authorize()
                            let sql = try TransferSQL.select(object: item.object, columns: columns, endpoint: plan.source.endpoint,
                                                             type: plan.source.type, filter: filter, order: sourceKeys, offset: offset,
                                                             limit: plan.configuration.batchSize, paginationKey: paginationKey, after: after)
                            let page = try await DataTransferCatalog.query(sql, session: source, database: plan.source.endpoint.database)
                            guard page.columns.map(\.name) == columns.map(\.name) else {
                                throw TransferFailure("过滤查询必须返回全部可写字段，并保持原始字段名。", "The filter query must return all writable fields with their original names.")
                            }
                            if page.rows.isEmpty { break }
                            if let keyIndex, let last = page.rows.last {
                                guard case let .text(value) = last.values[keyIndex] else {
                                    throw TransferFailure("来源主键值为空或不完整。", "The source primary key is null or incomplete.")
                                }
                                after = value
                            }
                            let rows = staging == nil ? page.rows : page.rows.enumerated().map { index, row in
                                WorkspaceDatabaseDataRow(id: row.id, values: row.values + [.text(String(offset + index + 1))])
                            }
                            try await encoder.send(rows: rows, to: stream)
                            offset += page.rows.count
                            if await counter.report(offset) { await progress(offset) }
                            if page.rows.count < plan.configuration.batchSize { break }
                        }
                        stream.finish()
                        return .source(offset)
                    } catch { stream.fail(error); throw error }
                }
                group.addTask {
                    do { return .target(try await writer.executeNativeBulkTransfer(sql: encoder.sql, token: encoder.token, stream: stream)) }
                    catch { stream.fail(error); throw error }
                }
                var read = 0, written = 0
                do {
                    for try await result in group {
                        switch result { case .source(let count): read = count; case .target(let count): written = count }
                    }
                    try Task.checkCancellation()
                    guard read == written else {
                        throw TransferFailure("原生导入行数不匹配（读取 \(read)，写入 \(written)），已中止提交。", "Native load row count mismatch (read \(read), written \(written)); commit aborted.")
                    }
                    return read
                } catch { stream.fail(error); group.cancelAll(); throw error }
            }
        } onCancel: { stream.fail(CancellationError()) }
    }

    private func finishTransaction(_ sql: String, operation: SQLStatementKind.TransactionOperation,
                                   session: any WorkspaceSession, database: String) async throws {
        // Task is intentionally independent: cancellation must not interrupt COMMIT/ROLLBACK.
        _ = try await Task {
            try await session.executeStatement(sql, kind: .transaction(operation), database: database) { _ in }
        }.value
    }

    private func configure(_ session: any WorkspaceSession, connection: TransferConnection, timeout: Int?, target: Bool, noBackslashEscapes: Bool? = nil) async throws {
        var statements: [String] = []
        if connection.type == .postgresql {
            statements += ["SET DateStyle = 'ISO, YMD'", "SET IntervalStyle = 'postgres'", "SET bytea_output = 'hex'"]
        }
        if let timeout {
            if connection.type == .postgresql { statements.append("SET statement_timeout = \(timeout * 1000)") }
            if connection.type == .mysql {
                statements.append("SET SESSION max_execution_time = \(timeout * 1000)")
                statements.append("SET SESSION innodb_lock_wait_timeout = \(timeout == 0 ? 1073741824 : timeout)")
            }
        }
        if target && connection.type == .mysql {
            let result = try await DataTransferCatalog.query("SELECT @@SESSION.sql_mode AS mode", session: session, database: connection.endpoint.database)
            guard let row = result.rows.first, let mode = result.text(row, "mode") else { throw TransferFailure("无法读取目标 SQL 模式。", "Cannot read the target SQL mode.") }
            var modes = Set(mode.uppercased().components(separatedBy: ",").filter { !$0.isEmpty })
            modes.insert("STRICT_ALL_TABLES")
            modes.insert("NO_AUTO_VALUE_ON_ZERO")
            if let noBackslashEscapes {
                if noBackslashEscapes { modes.insert("NO_BACKSLASH_ESCAPES") } else { modes.remove("NO_BACKSLASH_ESCAPES") }
            }
            statements.append("SET SESSION sql_mode = '\(modes.sorted().joined(separator: ","))'")
        }
        for sql in statements {
            do { _ = try await session.executeStatement(sql, kind: .control, database: connection.endpoint.database) { _ in } }
            catch WorkspaceSessionError.transactionStateUnavailable {
                // Legacy session state inference may reject an already applied SET.
                // Configuration is verified below for MySQL strict mode.
            }
        }
        if target && connection.type == .mysql {
            let modes = try await DataTransferCatalog.query("SELECT @@SESSION.sql_mode AS mode", session: session, database: connection.endpoint.database)
            guard let row = modes.rows.first, modes.text(row, "mode")?.uppercased().contains("STRICT_ALL_TABLES") == true else {
                throw TransferFailure("无法确认 MySQL 严格模式。", "Cannot verify MySQL strict mode.")
            }
            if let noBackslashEscapes {
                guard modes.text(row, "mode")?.uppercased().components(separatedBy: ",").contains("NO_BACKSLASH_ESCAPES") == noBackslashEscapes else { throw TransferFailure("目标 SQL 转义模式与规划不一致。", "The target SQL escaping mode differs from the reviewed plan.") }
            }
        }
    }

    private func writeLimit(_ session: any WorkspaceSession, connection: TransferConnection) async throws -> Int {
        guard connection.type == .mysql else { return 16 * 1024 * 1024 }
        let result = try await DataTransferCatalog.query("SELECT @@max_allowed_packet AS packet", session: session, database: connection.endpoint.database)
        guard let row = result.rows.first, let text = result.text(row, "packet"), let value = Int(text), value > 4096 else {
            throw TransferFailure("无法确认目标 max_allowed_packet。", "Cannot verify target max_allowed_packet.")
        }
        return min(90 * 1024 * 1024, value - 4096)
    }

    private func advanceIdentity(_ item: TransferPlanItem, connection: TransferConnection, session: any WorkspaceSession) async throws {
        guard connection.type == .postgresql else { return }
        let table = TransferSQL.qualified(connection.endpoint, item.targetName, type: .postgresql)
        for column in item.targetColumns where column.extra.contains("IDENTITY") || column.defaultValue?.hasPrefix("nextval(") == true {
            // Do not move an existing sequence backwards, including after an Upsert.
            let tableLiteral = try TransferSQL.string(table, type: .postgresql), columnLiteral = try TransferSQL.string(column.name, type: .postgresql)
            let result = try await DataTransferCatalog.query("SELECT pg_get_serial_sequence(\(tableLiteral),\(columnLiteral)) AS name", session: session, database: connection.endpoint.database)
            guard let row = result.rows.first, let name = result.text(row, "name") else { continue }
            let sequenceLiteral = try TransferSQL.string(name, type: .postgresql)
            let sql = "SELECT setval(\(sequenceLiteral)::regclass, GREATEST((SELECT COALESCE(MAX(\(TransferSQL.dialect(.postgresql).identifier(column.name))),1) FROM \(table)), (SELECT COALESCE(last_value,1) FROM pg_sequences WHERE schemaname=\(try TransferSQL.string(connection.endpoint.namespace, type: .postgresql)) AND sequencename=(SELECT relname FROM pg_class WHERE oid=\(sequenceLiteral)::regclass))), true)"
            _ = try await session.executeStatement(sql, kind: .insert, database: connection.endpoint.database) { _ in }
        }
    }
}

private actor TransferBulkRowCounter {
    private(set) var value = 0
    private var lastReport: ContinuousClock.Instant?
    func report(_ value: Int) -> Bool {
        self.value = value
        let now = ContinuousClock.now
        if let lastReport, lastReport.duration(to: now) < .milliseconds(100) { return false }
        lastReport = now; return true
    }
    func add(_ count: Int) -> (Int, Bool) {
        let next = value + count; return (next, report(next))
    }
}
