import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_TRANSFER_MYSQL_PORT"] != nil))
@MainActor struct MobileTransferIntegrationTests {
    nonisolated static let pairs: [(DatabaseType, DatabaseType)] = [(.mysql, .mysql), (.mysql, .postgresql), (.postgresql, .mysql), (.postgresql, .postgresql), (.doris, .mysql), (.doris, .postgresql)]
    static func connection(_ type: DatabaseType, target: String? = nil) throws -> TransferConnection {
        let env = ProcessInfo.processInfo.environment
        let port = try #require(env[type == .mysql ? "PROOF_TRANSFER_MYSQL_PORT" : type == .postgresql ? "PROOF_POSTGRES_PORT" : "PROOF_DORIS_PORT"].flatMap(Int.init))
        let database = type == .mysql ? target ?? "qc_workspace_source" : type == .postgresql ? "querycraft_ios_pg" : "querycraft_ios_drivers"
        let schema = type == .postgresql ? target ?? "workspace_source" : ""
        return .init(endpoint: .init(profileID: UUID(), database: database, schema: schema), configuration: .init(databaseType: type,
            host: MobileFixtureEndpoint.host, port: port, username: type == .postgresql ? "postgres" : "root",
            password: type == .mysql ? "qc-workspace-mysql" : type == .postgresql ? "querycraft-proof-pg" : nil,
            database: database, tlsMode: .disabled))
    }
    static func execute(_ sql: String, connection: TransferConnection, kind: SQLStatementKind = .control) async throws -> TransferQueryResult {
        let session = try await DataTransferCatalog().open(connection)
        do {
            if kind == .read {
                let result = try await DataTransferCatalog.query(sql, session: session, database: connection.endpoint.database)
                await session.close(); return result
            }
            _ = try await session.executeStatement(sql, kind: kind, database: connection.endpoint.database) { _ in }
            await session.close(); return .init(columns: [], rows: [])
        } catch { await session.close(); throw error }
    }
    private func withTarget(_ type: DatabaseType, body: (TransferConnection) async throws -> Void) async throws {
        let name = "qc_mobile_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let maintenance = try Self.connection(type), target = try Self.connection(type, target: name)
        let keyword = type == .mysql ? "DATABASE" : "SCHEMA", quoted = TransferSQL.dialect(type).identifier(name)
        _ = try await Self.execute("CREATE \(keyword) \(quoted)", connection: maintenance, kind: .ddl(.create))
        do {
            try await body(target)
            _ = try await Self.execute("DROP \(keyword) \(quoted)" + (type == .postgresql ? " CASCADE" : ""), connection: maintenance, kind: .ddl(.drop))
        } catch {
            _ = try? await Self.execute("DROP \(keyword) \(quoted)" + (type == .postgresql ? " CASCADE" : ""), connection: maintenance, kind: .ddl(.drop))
            throw error
        }
    }
    private func plan(source: TransferConnection, target: TransferConnection, strategy: TransferStrategy = .append) async throws -> DataTransferPlan {
        let catalog = DataTransferCatalog(), objects = try await catalog.objects(source)
        let object = try #require(objects.first { $0.kind == .table && $0.name == "sample" })
        var configuration = DataTransferConfiguration()
        configuration.source = source.endpoint; configuration.target = target.endpoint; configuration.objects = [object]
        configuration.strategy = strategy; configuration.batchSize = 500
        return try await DataTransferPlanner(catalog: catalog).prepare(configuration: configuration, source: source, target: target)
    }
    @Test(arguments: pairs)
    func realNativeTransfersPreserveWholeValuesNullEmptyBinaryAndLargeKeys(pair: (DatabaseType, DatabaseType)) async throws {
        let (sourceType, targetType) = pair, source = try Self.connection(sourceType)
        try await withTarget(targetType) { target in
            let plan = try await self.plan(source: source, target: target), progress = MobileTransferProgressProbe()
            let outcome = await DataTransferRunner().run(plan, authorize: {}, progress: { await progress.append($0) }, backups: { _ in })
            #expect(outcome.0 == .completed, "\(outcome.1)")
            let table = TransferSQL.qualified(target.endpoint, "sample", type: targetType)
            let counts = try await Self.execute("SELECT COUNT(*) AS n FROM " + table, connection: target, kind: .read)
            #expect(counts.text(try #require(counts.rows.first), "n") == (sourceType == .doris ? "2" : "1001"))
            if sourceType != .doris {
                let quote = TransferSQL.dialect(targetType).identifier
                let hex = targetType == .postgresql ? "encode(\(quote("raw")),'hex')" : "LOWER(HEX(\(quote("raw"))))"
                let sql = "SELECT \(quote("id")) AS exact_id,CHAR_LENGTH(\(quote("value"))) AS chars,\(hex) AS bytes,\(quote("missing")) AS absent,\(quote("empty")) AS empty_value FROM \(table) ORDER BY \(quote("id")) LIMIT 1"
                let data = try await Self.execute(sql, connection: target, kind: .read), row = try #require(data.rows.first)
                #expect(data.text(row, "exact_id") == "9007199254740993")
                #expect(data.text(row, "chars") == "2000"); #expect(data.text(row, "bytes") == "00ff8027")
                #expect(data.text(row, "absent") == nil); #expect(data.text(row, "empty_value") == "")
            }
            #expect(await progress.values.contains { $0.message.contains(targetType == .postgresql ? "COPY" : "LOAD DATA") })
        }
    }
    @Test(arguments: [DatabaseType.mysql, .postgresql])
    func nativeUpsertAndOverwriteUseOriginalStrategies(type: DatabaseType) async throws {
        let source = try Self.connection(type)
        try await withTarget(type) { target in
            let initial = try await self.plan(source: source, target: target)
            #expect(await DataTransferRunner().run(initial, authorize: {}, progress: { _ in }, backups: { _ in }).0 == .completed)
            let table = TransferSQL.qualified(target.endpoint, "sample", type: type), value = TransferSQL.dialect(type).identifier("value")
            _ = try await Self.execute("UPDATE \(table) SET \(value)='changed'", connection: target, kind: .update(hasWhereClause: false))
            let upsert = try await self.plan(source: source, target: target, strategy: .upsert)
            let upsertResult = await DataTransferRunner().run(upsert, authorize: {}, progress: { _ in }, backups: { _ in })
            #expect(upsertResult.0 == .completed, "\(upsertResult.1)")
            let lengths = try await Self.execute("SELECT MIN(CHAR_LENGTH(\(value))) AS n FROM \(table)", connection: target, kind: .read)
            #expect(lengths.text(try #require(lengths.rows.first), "n") == "2000")
            let overwrite = try await self.plan(source: source, target: target, strategy: .overwrite)
            let result = await DataTransferRunner().run(overwrite, authorize: {}, progress: { _ in }, backups: { _ in })
            #expect(result.0 == .completed, "\(result.1)")
            let counts = try await Self.execute("SELECT COUNT(*) AS n FROM \(table)", connection: target, kind: .read)
            #expect(counts.text(try #require(counts.rows.first), "n") == "1001")
        }
    }
    @Test func actualOverwriteCancellationRollsBackWithoutReplaying() async throws {
        let source = try Self.connection(.postgresql)
        try await withTarget(.postgresql) { target in
            let initial = try await self.plan(source: source, target: target)
            #expect(await DataTransferRunner().run(initial, authorize: {}, progress: { _ in }, backups: { _ in }).0 == .completed)
            let table = TransferSQL.qualified(target.endpoint, "sample", type: .postgresql)
            _ = try await Self.execute("UPDATE \(table) SET value='before cancellation'", connection: target, kind: .update(hasWhereClause: false))
            let plan = try await self.plan(source: source, target: target, strategy: .overwrite), gate = MobileTransferCancellationProbe()
            let task = Task { await DataTransferRunner().run(plan, authorize: {}, progress: { item in if item.readRows > 0 { await gate.hold() } }, backups: { _ in }) }
            await gate.waitUntilHeld(); task.cancel(); await gate.release()
            let result = await task.value
            #expect(result.0 == .cancelled, "\(result.1)")
            let rows = try await Self.execute("SELECT COUNT(*) AS n FROM \(table) WHERE value='before cancellation'", connection: target, kind: .read)
            #expect(rows.text(try #require(rows.rows.first), "n") == "1001")
        }
    }
}

private actor MobileTransferProgressProbe {
    var values: [TransferItemProgress] = []
    func append(_ item: TransferItemProgress) { values.append(item) }
}
private actor MobileTransferCancellationProbe {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func hold() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            held.append(continuation); waiters.forEach { $0.resume() }; waiters = []
        }
    }
    func waitUntilHeld() async { if held.isEmpty { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; held.forEach { $0.resume() }; held = [] }
}
