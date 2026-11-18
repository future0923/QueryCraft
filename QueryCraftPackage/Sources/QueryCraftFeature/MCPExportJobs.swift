import Foundation
import CryptoKit

/// Service-wide task ownership survives protocol-session teardown. On process termination,
/// kernel leases release and the next access marks unfinished records interrupted.
actor MCPExportJobs {
    static let shared = MCPExportJobs()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var stores: [String: MCPExportStore] = [:]
    private var maintenance: Task<Void, Never>?

    func submit(_ request: MCPExportRequest, profile: ConnectionProfile, directory: URL,
                credentials: any CredentialStore, registry: DatabaseDriverRegistry) throws -> MCPJSONValue {
        guard try JSONEncoder().encode(request).count <= 1_500_000 else {
            throw MCPFailure("Encoded export request exceeds the private job-record budget.", code: .resultTooLarge)
        }
        let store = MCPExportStore(directory: directory)
        try store.cleanup()
        let result: (MCPExportRecord, MCPExportLease?) = try store.locked {
            let records = try store.records()
            if let previous = records.first(where: { $0.request.idempotencyKey == request.idempotencyKey }) {
                guard previous.request == request, previous.profileDigest == (try MCPExportRequest.digest(profile)) else {
                    throw MCPFailure("idempotency_key was already used with a different request or connection.")
                }
                return (try store.reconcile(previous), nil)
            }
            let reservedBytes = records.reduce(0) { $0 + ($1.status.active ? $1.request.limits.fileBytes : ($1.fileBytes ?? 0)) }
            guard records.count < 200, records.filter({ $0.status.active }).count < 20,
                  request.limits.fileBytes <= 2_147_483_648 - reservedBytes else {
                throw MCPFailure("Export queue/storage capacity reached. Delete finished exports or wait for expiry.", code: .capacity)
            }
            let id = UUID(); try MCPExportStore.directory(store.job(id))
            var stored = false
            defer { if !stored { try? FileManager.default.removeItem(at: store.job(id)) } }
            guard let owner = try store.owner(id) else { throw MCPFailure("Cannot own export task.") }
            let record = MCPExportRecord(id: id, accessToken: UUID().uuidString + UUID().uuidString, request: request,
                profileDigest: try MCPExportRequest.digest(profile), createdAt: Date(), expiresAt: Date().addingTimeInterval(86_400),
                counts: Array(repeating: 0, count: request.queries.count))
            try store.write(record)
            stored = true
            return (record, owner)
        }
        if let owner = result.1 {
            let key = store.job(result.0.id).path
            let worker = MCPExportWorker(record: result.0, profile: profile, directory: directory, credentials: credentials, registry: registry)
            tasks[key] = Task(priority: .utility) {
                await worker.run()
                withExtendedLifetime(owner) {}
                self.finished(key)
            }
        }
        stores[store.root.path] = store
        if maintenance == nil {
            maintenance = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await self?.cleanStores()
                }
            }
        }
        return result.0.value(store: store, includeToken: true)
    }
    func maintain(directory: URL) {
        let store = MCPExportStore(directory: directory)
        guard FileManager.default.fileExists(atPath: store.root.path) else { return }
        try? store.cleanup()
    }
    private func finished(_ key: String) { tasks[key] = nil }
    private func cleanStores() { for store in stores.values { try? store.cleanup() } }

    func control(_ tool: String, args: [String: MCPJSONValue], directory: URL,
                 authorize: @Sendable (MCPExportRecord) async throws -> Void) async throws -> MCPJSONValue {
        let store = MCPExportStore(directory: directory)
        guard let id = UUID(uuidString: try args.requiredString("job_id")) else { throw MCPFailure("Invalid job_id.") }
        let token = try args.requiredString("access_token")
        func owned() throws -> MCPExportRecord {
            guard let record = try? store.read(id), record.accessToken == token else { throw MCPFailure("Export not found or access_token is invalid.", code: .accessDenied) }
            return record
        }
        let record = try store.locked { try store.reconcile(owned()) }
        if tool == "get_export_status" { try await authorize(record) }
        return try store.locked {
            var latest = try store.reconcile(owned())
            if tool == "delete_export" {
                guard !latest.status.active else { throw MCPFailure("Cancel the export and wait for a terminal state before deleting it.", code: .sessionBusy) }
                try FileManager.default.removeItem(at: store.job(id))
                return .object(["job_id": .string(id.uuidString), "status": "deleted"])
            }
            if tool == "cancel_export", latest.status.active { latest.cancelRequested = true; try store.write(latest) }
            if latest.expiresAt < Date(), !latest.status.active { throw MCPFailure("Export expired. Submit a new task; it uses a new snapshot.", code: .sessionUnavailable) }
            if tool == "get_export_status", latest.status == .succeeded {
                let values = try store.artifact(latest).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == latest.fileBytes else {
                    throw MCPFailure("Completed export artifact is missing or changed.", code: .resultTooLarge)
                }
            }
            return latest.value(store: store, includeArtifact: tool == "get_export_status")
        }
    }
}

private struct MCPExportWorker: Sendable {
    let record: MCPExportRecord
    let profile: ConnectionProfile
    let directory: URL
    let credentials: any CredentialStore
    let registry: DatabaseDriverRegistry
    var store: MCPExportStore { MCPExportStore(directory: directory) }

    func run() async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await execute() }
                group.addTask { try await watch() }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch {
            try? FileManager.default.removeItem(at: store.temporary(record.id))
            let failure: MCPFailure
            if let exportError = error as? WorkspaceDataExportError {
                switch exportError {
                case .fileTooLarge: failure = MCPFailure("Export exceeded a file, row-byte or spreadsheet-cell limit. No artifact was published.", code: .resultTooLarge)
                default: failure = MCPFailure(exportError.localizedDescription, code: .driverFailure)
                }
            } else { failure = MCPFailure.normalized(error) }
            _ = try? store.update(record.id) { state in
                // Publication is the commit point. Late cancellation must not turn a completed file into failure.
                guard state.status != .succeeded else { return }
                state.status = state.cancelRequested || error is CancellationError ? .cancelled : .failed
                state.errorCode = failure.code.rawValue; state.errorMessage = failure.message
                state.completedAt = Date()
                try? FileManager.default.removeItem(at: store.artifact(state))
                try? FileManager.default.removeItem(at: store.job(state.id).appending(path: "manifest.json"))
            }
        }
    }

    private func checkAuthorization() async throws -> MCPPolicy {
        let policy = try MCPPolicyStore(directory: directory).load()
        try policy.authorize(tool: "export_query", profile: profile, database: record.request.database)
        let repository = SQLiteConnectionProfileRepository(databaseURL: directory.appending(path: "QueryCraft.sqlite"))
        guard try await repository.fetch(id: profile.id) == profile else { throw MCPFailure("Export connection changed or was removed.", code: .accessDenied) }
        return policy
    }

    private func watch() async throws {
        let initial = try await checkAuthorization()
        while true {
            try Task.checkCancellation()
            let latest = try store.read(record.id)
            if latest.status == .succeeded { return }
            if latest.cancelRequested { throw CancellationError() }
            guard Date().timeIntervalSince(record.createdAt) < Double(record.request.limits.timeoutSeconds) else {
                throw MCPFailure("Export task timed out; no incomplete file is published.", code: .timeout)
            }
            let policy = try await checkAuthorization()
            guard policy == initial else { throw MCPFailure("MCP policy changed during export. Submit again under the current policy.", code: .accessDenied) }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func acquireCapacity() async throws -> [MCPExportLease] {
        while true {
            try Task.checkCancellation()
            let policy = try await checkAuthorization()
            if let connection = try MCPExportLease.acquire(store.root.appending(path: "connection-\(profile.id.uuidString).lock")) {
                for slot in 0..<min(2, policy.maximumSessions) {
                    if let lease = try MCPExportLease.acquire(store.root.appending(path: "slot-\(slot).lock")) { return [connection, lease] }
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func execute() async throws {
        let capacity = try await acquireCapacity()
        defer { withExtendedLifetime(capacity) {} }
        let runtime = MCPRuntime(directory: directory, credentials: credentials, registry: registry)
        let session = try await runtime.connect(profile, database: record.request.database, mode: .readOnly)
        guard let configurable = session as? any WorkspaceQueryExportConfiguring else {
            await session.close()
            throw MCPFailure("Update the MySQL driver: bounded query export is unavailable in this installed driver.", code: .unsupported)
        }
        var writer: MCPExportWriter?
        do {
            try await configurable.configureQueryExport(maximumRowBytes: MCPExportLimits.rowBytes)
            let activeWriter = try MCPExportWriter(request: record.request, temporaryURL: store.temporary(record.id))
            writer = activeWriter
            _ = try store.update(record.id) { $0.status = .running }
            try await statement("SET SESSION SQL_SELECT_LIMIT = 18446744073709551615", kind: .control, session: session)
            try await statement("SET SESSION time_zone = '\(record.request.timezone)'", kind: .control, session: session)
            if record.request.consistency == .singleSnapshot {
                try await statement("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", kind: .control, session: session)
                try await statement("START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY", kind: .transaction(.begin), session: session)
                try await validateSnapshot(session)
            }
            for (index, query) in record.request.queries.enumerated() {
                try Task.checkCancellation()
                let policy = try await checkAuthorization()
                _ = try await MCPSQLAuthorization.statements(query.sql, profile: profile, database: record.request.database, policy: policy, forceReadOnly: true)
                if record.request.consistency == .perQuery { try await statement("START TRANSACTION READ ONLY", kind: .transaction(.begin), session: session) }
                _ = try store.update(record.id) { $0.queryIndex = index }
                try await activeWriter.beginQuery(index)
                let result = try await timed(seconds: policy.effectiveQueryTimeoutSeconds) {
                    try await session.executeStatement(query.sql, kind: .read, database: record.request.database, maximumRows: nil) { batch in
                        try await activeWriter.consume(batch)
                        let counts = await activeWriter.counts
                        _ = try store.update(record.id) { $0.counts = counts }
                    }
                }
                try await activeWriter.endQuery(result)
                if record.request.consistency == .perQuery { try await statement("ROLLBACK", kind: .transaction(.rollback), session: session) }
            }
            if record.request.consistency == .singleSnapshot { try await statement("ROLLBACK", kind: .transaction(.rollback), session: session) }
            await session.close()
            _ = try store.update(record.id) { $0.status = .finalizing }
            let manifest = try await activeWriter.finish()
            let textFallbackCells = await activeWriter.textFallbackCells
            let summary = try hashFile(store.temporary(record.id))
            _ = try await checkAuthorization()
            try Task.checkCancellation()
            _ = try store.update(record.id) { state in
                guard !state.cancelRequested else { throw CancellationError() }
                let destination = store.artifact(state)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw MCPFailure("Export destination already exists; overwrite is forbidden.") }
                let manifestURL = store.job(state.id).appending(path: "manifest.json")
                try manifest.write(to: manifestURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
                try FileManager.default.moveItem(at: store.temporary(state.id), to: destination)
                state.fileBytes = summary.0; state.sha256 = summary.1; state.textFallbackCells = textFallbackCells
                state.status = .succeeded; state.completedAt = Date()
                state.expiresAt = Date().addingTimeInterval(86_400)
            }
        } catch {
            await writer?.abort()
            await session.close() // Discarding a dedicated connection rolls back any remaining transaction.
            throw error
        }
    }

    private func statement(_ sql: String, kind: SQLStatementKind, session: any WorkspaceSession) async throws {
        _ = try await timed(seconds: 30) {
            try await session.executeStatement(sql, kind: kind, database: nil, onBatch: { _ in })
        }
    }

    /// Pin metadata locks before validating InnoDB. Views/CTEs or unresolvable relations fail
    /// closed in snapshot mode; callers can explicitly choose per_query for those queries.
    private func validateSnapshot(_ session: any WorkspaceSession) async throws {
        var checked: Set<String> = []
        let policy = try await checkAuthorization()
        for query in record.request.queries {
            let parser = try SQLStructuralParser()
            _ = try await parser.parse(.init(revision: .init(1), text: query.sql))
            let tree = try await parser.authorizationTree(revision: .init(1))
            guard tree.descendants(named: "keyword_with").isEmpty else {
                throw MCPFailure("single_snapshot currently requires verifiable base tables; use per_query explicitly for CTEs.", code: .unsupported)
            }
            let scope = MCPSQLScope(source: query.sql as NSString, profile: profile, database: record.request.database, policy: policy)
            for relation in tree.descendants(named: "relation") {
                guard let reference = relation.children.first(where: { $0.type == "object_reference" }) else { continue }
                let parts = scope.identifiers(reference)
                guard let table = parts.last else { throw MCPFailure("Cannot verify snapshot table.", code: .unsupported) }
                let database = parts.count == 2 ? parts[0] : record.request.database
                let identity = database + "\0" + table
                if !checked.insert(identity).inserted { continue }
                func identifier(_ value: String) -> String { "`" + value.replacingOccurrences(of: "`", with: "``") + "`" }
                func literal(_ value: String) -> String { "CONVERT(0x" + value.utf8.map { String(format: "%02x", $0) }.joined() + " USING utf8mb4)" }
                let probe = "SELECT ENGINE, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(literal(database)) AND TABLE_NAME = \(literal(table))"
                let buffer = MCPExportEngineProbe()
                _ = try await timed(seconds: 30) { try await session.executeStatement(probe, kind: .read, database: nil, onBatch: { try await buffer.consume($0) }) }
                guard await buffer.isInnoDB else { throw MCPFailure("single_snapshot supports InnoDB base tables only; table engine/view could not be verified.", code: .unsupported) }
                try await statement("SELECT 1 FROM \(identifier(database)).\(identifier(table)) LIMIT 0", kind: .read, session: session)
                let pinned = MCPExportEngineProbe()
                _ = try await timed(seconds: 30) { try await session.executeStatement(probe, kind: .read, database: nil, onBatch: { try await pinned.consume($0) }) }
                guard await pinned.isInnoDB else { throw MCPFailure("Snapshot table changed during validation.", code: .unsupported) }
            }
        }
    }

    private func timed<T: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds > 0 else { return try await operation() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw MCPFailure("Export database operation timed out.", code: .timeout) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func hashFile(_ url: URL) throws -> (Int, String) {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256(), bytes = 0
        while let data = try input.read(upToCount: 256 * 1_024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data); bytes += data.count
            guard bytes <= record.request.limits.fileBytes else { throw WorkspaceDataExportError.fileTooLarge }
        }
        return (bytes, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

private actor MCPExportEngineProbe {
    var rows: [WorkspaceDatabaseDataRow] = []
    var isInnoDB: Bool { rows.count == 1 && rows[0].value(at: 0) == .text("InnoDB") && rows[0].value(at: 1) == .text("BASE TABLE") }
    func consume(_ batch: WorkspaceDatabaseDataBatch) throws {
        guard rows.count + batch.rows.count <= 1 else { throw MCPFailure("Ambiguous table engine.") }
        rows += batch.rows
    }
}
