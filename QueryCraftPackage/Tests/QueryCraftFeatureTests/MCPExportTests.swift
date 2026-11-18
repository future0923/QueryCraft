import Foundation
import Testing
@testable import QueryCraftFeature

struct MCPExportTests {
    static func arguments(id: UUID = UUID(), format: String = "xlsx", queries: [MCPJSONValue]? = nil) -> [String: MCPJSONValue] {
        ["connection_id": .string(id.uuidString), "database": "allowed", "format": .string(format),
         "consistency": "per_query", "idempotency_key": .string(UUID().uuidString),
         "queries": .array(queries ?? [.object(["name": "用户", "sql": "SELECT id, amount FROM users"])])]
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "mcp-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func unzip(_ file: URL, _ path: String) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", file.path, path]
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"]) { _, value in value }
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func requestRejectsUnsafePathsDuplicateSheetsAndInvalidNestedTypes() throws {
        var args = Self.arguments()
        for file in ["../secret.xlsx", "/tmp/secret.xlsx", "bad.csv", ".hidden.xlsx", "bad\n.xlsx"] {
            args["filename"] = .string(file)
            #expect(throws: MCPFailure.self) { try MCPExportRequest(arguments: args) }
        }
        args["filename"] = nil
        args["queries"] = .array([.object(["name": "Test", "sql": "SELECT 1"]), .object(["name": "test", "sql": "SELECT 2"])])
        #expect(throws: MCPFailure.self) { try MCPExportRequest(arguments: args) }
        args = Self.arguments(); args["limits"] = .object(["max_rows": "100"])
        #expect(throws: MCPFailure.self) { try MCPExportRequest(arguments: args) }
        args = Self.arguments(); args["limits"] = .object(["max_rows": 1_000_001])
        #expect(throws: MCPFailure.self) { try MCPExportRequest(arguments: args) }
        args = Self.arguments(); args["timezone"] = "Asia/Shanghai"
        #expect(throws: MCPFailure.self) { try MCPExportRequest(arguments: args) }
        args["timezone"] = "+08:00"
        #expect(try MCPExportRequest(arguments: args).timezone == "+08:00")
        args["queries"] = .array([.object(["name": "数据", "sql": "SELECT 1", "columns": .array([
            .object(["source_index": 0, "title": "ID", "type": 1])
        ])])])
        #expect(throws: MCPFailure.self) { try MCPExportRequest(arguments: args) }
    }

    @Test(arguments: ["UPDATE users SET id=1", "DELETE FROM users", "SELECT 1; SELECT 2", "SELECT LOAD_FILE('/tmp/a')", "SELECT 1 INTO OUTFILE '/tmp/a'", "SELECT * FROM users FOR UPDATE", "SELECT * FROM forbidden.users", "SELECT @secret", "SET @x=1", "CALL p()"])
    func exportForcesReadOnlyEvenOnFullAccess(sql: String) async throws {
        let profile = MCPTests().profile()
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        policy.connections[profile.id.uuidString] = MCPConnectionPolicy(databases: ["allowed"], mode: .fullAccess)
        await #expect(throws: MCPFailure.self) { try await MCPSQLAuthorization.statements(sql, profile: profile, database: "allowed", policy: policy, forceReadOnly: true) }
    }

    @Test func workbookPreservesValuesAndSupportsIndependentSheets() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let columns: [MCPJSONValue] = [
            .object(["source_index": 0, "title": "ID", "type": "integer"]),
            .object(["source_index": 1, "title": "金额", "type": "decimal"]),
            .object(["source_index": 2, "title": "日期", "type": "date", "date_format": "yyyy-mm-dd"]),
            .object(["source_index": 3, "title": "文本"])
        ]
        let request = try MCPExportRequest(arguments: Self.arguments(queries: [
            .object(["name": "用户", "sql": "SELECT 1", "columns": .array(columns), "expected_rows": 1]),
            .object(["name": "空结果", "sql": "SELECT 2", "expected_rows": 0])
        ]))
        let file = root.appending(path: "result.xlsx"), writer = try MCPExportWriter(request: request, temporaryURL: file)
        let source = (0..<4).map { WorkspaceDatabaseDataColumn(id: $0, name: "col\($0)") }
        try await writer.beginQuery(0)
        try await writer.consume(.init(columns: source, rows: [.init(id: 0, values: [.text("18446744073709551615"), .text("12345678901234567890.0010"), .text("2026-10-01"), .text("=1+2")])]))
        try await writer.endQuery(.init(columns: source, rowCount: 1))
        try await writer.beginQuery(1)
        try await writer.consume(.init(columns: [source[0]], rows: []))
        try await writer.endQuery(.init(columns: [source[0]], rowCount: 0))
        _ = try await writer.finish()
        let xml = try unzip(file, "xl/worksheets/sheet1.xml")
        #expect(xml.contains("18446744073709551615")); #expect(xml.contains("12345678901234567890.0010"))
        #expect(xml.contains("=1+2")); #expect(!xml.contains("<f>")); #expect(xml.contains("s=\"2\" t=\"n\""))
        #expect(xml.contains("state=\"frozen\"")); #expect(xml.contains("<cols>")); #expect(xml.contains("autoFilter"))
        #expect(try unzip(file, "xl/workbook.xml").contains("空结果"))
        #expect(try unzip(file, "xl/worksheets/sheet2.xml").contains("A1:A1"))
        #expect(await writer.counts == [1, 0])
    }

    @Test func csvZipHasBOMManifestAndExplicitNullEscaping() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try MCPExportRequest(arguments: Self.arguments(format: "csv", queries: [
            .object(["name": "甲", "sql": "SELECT 1"]), .object(["name": "乙", "sql": "SELECT 2"])
        ]))
        let file = root.appending(path: "result.zip"), writer = try MCPExportWriter(request: request, temporaryURL: file)
        let columns = (0..<5).map { WorkspaceDatabaseDataColumn(id: $0, name: "c\($0)") }
        for i in 0..<2 {
            try await writer.beginQuery(i)
            try await writer.consume(.init(columns: columns, rows: [.init(id: 0, values: [.null, .text(""), .text("\\N"), .text("\t=1+2"), .text("中文,\"值\"\n下一行")])]))
            try await writer.endQuery(.init(columns: columns, rowCount: 1))
        }
        _ = try await writer.finish()
        let csv = try unzip(file, "1-甲.csv")
        #expect(csv.hasPrefix("\u{feff}")); #expect(csv.contains("\"\\N\",\"\",\"\\\\N\""))
        #expect(csv.contains("\"\t\t=1+2\"")); #expect(csv.contains("\"\"值\"\""))
        #expect(try unzip(file, "manifest.json").contains("rows"))
    }

    @Test func formatLimitsFailWithoutTruncation() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var args = Self.arguments(); args["limits"] = .object(["max_rows": 1])
        let writer = try MCPExportWriter(request: MCPExportRequest(arguments: args), temporaryURL: root.appending(path: "partial"))
        let c = [WorkspaceDatabaseDataColumn(id: 0, name: "value")]
        try await writer.beginQuery(0)
        await #expect(throws: MCPFailure.self) { try await writer.consume(.init(columns: c, rows: [.init(id: 0, values: [.text("a")]), .init(id: 1, values: [.text("b")])])) }
        await writer.abort()
        #expect(MCPExportWriter.excelDate("2026-02-30", dateOnly: true) == nil)
        #expect(MCPExportWriter.excelDate("0000-00-00", dateOnly: true) == nil)
        #expect(MCPExportWriter.excelDate("2026-10-01 10:00:00.123456", dateOnly: false) == nil)
        #expect(MCPExportWriter.excelDate("2026-10-01", dateOnly: true) != nil)
    }

    @Test(.timeLimit(.minutes(1))) func runtimeExportBypassesChatLimitsAndSurvivesSessionShutdown() async throws {
        let fixture = try await fixture(rows: 1_205)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let args = Self.arguments(id: fixture.profile.id)
        let submitted = try await fixture.runtime.call("querycraft_export_query", arguments: args)
        let ownership = try ownership(submitted)
        let again = try await fixture.runtime.call("querycraft_export_query", arguments: args)
        #expect(again.objectValue?["job_id"] == submitted.objectValue?["job_id"])
        await fixture.runtime.shutdown()
        let next = MCPRuntime(directory: fixture.root, registry: fixture.registry)
        let result = try await terminal(next, ownership)
        #expect(result.objectValue?["status"] == "succeeded")
        #expect(result.objectValue?["total_rows"] == 1_205)
        let path = try #require(result.objectValue?["artifact"]?.objectValue?["local_path"]?.stringValue)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(await fixture.session.queryCalls == 1)
        var bad = ownership; bad["access_token"] = "incorrect"
        await #expect(throws: MCPFailure.self) { try await next.call("querycraft_get_export_status", arguments: bad) }
        _ = try await next.call("querycraft_delete_export", arguments: ownership)
        #expect(!FileManager.default.fileExists(atPath: path))
        await next.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func rowLimitFailurePublishesNoFile() async throws {
        let fixture = try await fixture(rows: 11)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var args = Self.arguments(id: fixture.profile.id); args["limits"] = .object(["max_rows": 10])
        let submitted = try await fixture.runtime.call("querycraft_export_query", arguments: args)
        let result = try await terminal(fixture.runtime, ownership(submitted))
        #expect(result.objectValue?["status"] == "failed"); #expect(result.objectValue?["artifact"] == nil)
        let id = try #require(UUID(uuidString: submitted.objectValue?["job_id"]?.stringValue ?? ""))
        let files = try FileManager.default.contentsOfDirectory(atPath: MCPExportStore(directory: fixture.root).job(id).path)
        #expect(!files.contains("artifact.partial")); #expect(!files.contains("QueryCraft-export.xlsx"))
        await fixture.runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func cancellationWorksAfterRevocation() async throws {
        let fixture = try await fixture(rows: 1, waits: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let submitted = try await fixture.runtime.call("querycraft_export_query", arguments: Self.arguments(id: fixture.profile.id))
        let key = try ownership(submitted)
        try MCPPolicyStore(directory: fixture.root).update { $0.enabled = false }
        _ = try await fixture.runtime.call("querycraft_cancel_export", arguments: key)
        let id = try #require(UUID(uuidString: key["job_id"]?.stringValue ?? ""))
        let store = MCPExportStore(directory: fixture.root)
        let deadline = Date().addingTimeInterval(5)
        while try store.read(id).status.active, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try !store.read(id).status.active)
        _ = try await fixture.runtime.call("querycraft_delete_export", arguments: key)
        await fixture.runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func runningCancellationStopsReaderAndRemovesPartialFile() async throws {
        let fixture = try await fixture(rows: 1, waits: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let key = try ownership(await fixture.runtime.call("querycraft_export_query", arguments: Self.arguments(id: fixture.profile.id)))
        let deadline = Date().addingTimeInterval(5)
        while await fixture.session.queryCalls == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await fixture.session.queryCalls == 1)
        _ = try await fixture.runtime.call("querycraft_cancel_export", arguments: key)
        let result = try await terminal(fixture.runtime, key)
        #expect(result.objectValue?["status"] == "cancelled")
        #expect(await fixture.session.closed)
        #expect(result.objectValue?["artifact"] == nil)
        await fixture.runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func secondSheetFailureCannotPublishFirstSheet() async throws {
        let fixture = try await fixture(rows: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let args = Self.arguments(id: fixture.profile.id, queries: [
            .object(["name": "first", "sql": "SELECT id, amount FROM users", "expected_rows": 2]),
            .object(["name": "second", "sql": "SELECT id, amount FROM users", "expected_rows": 3])
        ])
        let key = try ownership(await fixture.runtime.call("querycraft_export_query", arguments: args))
        let result = try await terminal(fixture.runtime, key)
        #expect(result.objectValue?["status"] == "failed")
        #expect(result.objectValue?["artifact"] == nil)
        #expect(result.objectValue?["complete"] == false)
        await fixture.runtime.shutdown()
    }

    @Test func lostProcessIsInterruptedAndNeverAdvertisesArtifact() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPExportStore(directory: root), request = try MCPExportRequest(arguments: Self.arguments())
        try store.prepare()
        let id = UUID(); try MCPExportStore.directory(store.job(id))
        let record = MCPExportRecord(id: id, accessToken: "test", request: request, profileDigest: "test", createdAt: Date(), expiresAt: Date().addingTimeInterval(100), status: .running, counts: [9])
        try store.write(record)
        try Data("partial".utf8).write(to: store.temporary(id))
        let recovered = try store.locked { try store.reconcile(record) }
        #expect(recovered.status == .interrupted)
        #expect(!FileManager.default.fileExists(atPath: store.temporary(id).path))
        #expect(recovered.value(store: store).objectValue?["artifact"] == nil)
    }

    @Test func ownerLeasePreventsFalseCrashRecoveryAndSymlinksAreRejected() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPExportStore(directory: root), request = try MCPExportRequest(arguments: Self.arguments())
        try store.prepare()
        let id = UUID(); try MCPExportStore.directory(store.job(id))
        let record = MCPExportRecord(id: id, accessToken: "test", request: request, profileDigest: "test", createdAt: Date(), expiresAt: Date().addingTimeInterval(100), counts: [0])
        try store.write(record)
        let acquired = try store.owner(id)
        let lease = try #require(acquired)
        #expect(try store.owner(id) == nil)
        #expect(try store.locked { try store.reconcile(record) }.status == .queued)
        withExtendedLifetime(lease) {}
        let link = root.appending(path: "unsafe.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store.job(id).appending(path: "record.json"))
        #expect(throws: MCPFailure.self) { try MCPExportLease.acquire(link) }
    }

    @Test(.timeLimit(.minutes(1))) func timeoutCannotPublishArtifact() async throws {
        let fixture = try await fixture(rows: 1, waits: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var args = Self.arguments(id: fixture.profile.id); args["limits"] = .object(["timeout_seconds": 1])
        let key = try ownership(await fixture.runtime.call("querycraft_export_query", arguments: args))
        let result = try await terminal(fixture.runtime, key)
        #expect(result.objectValue?["status"] == "failed")
        #expect(result.objectValue?["error"]?.objectValue?["code"] == "OPERATION_TIMEOUT")
        #expect(result.objectValue?["artifact"] == nil)
        await fixture.runtime.shutdown()
    }

    @Test func quotedKeywordsRemainDataAndOnlyMySQLAdvertisesExport() async throws {
        let profile = MCPTests().profile(); var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        _ = try await MCPSQLAuthorization.statements("SELECT 'FOR UPDATE @secret INTO OUTFILE' AS note", profile: profile, database: "allowed", policy: policy, forceReadOnly: true)
        for type in [DatabaseType.postgresql, .doris, .redis, .elasticsearch, .kafka, .milvus] {
            #expect(MCPToolCatalog.driverTools(type).isDisjoint(with: MCPToolCatalog.exportTools))
        }
        #expect(MCPToolCatalog.exportTools.isSubset(of: MCPToolCatalog.driverTools(.mysql)))
    }

    @Test(.timeLimit(.minutes(1))) func representativeTwoSheetExportCountsEveryRow() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let counts = [4_404, 56_945], widths = [5, 4]
        let request = try MCPExportRequest(arguments: Self.arguments(queries: [
            .object(["name": "住房宝用户", "sql": "SELECT 1", "expected_rows": 4_404]),
            .object(["name": "商机收支记录", "sql": "SELECT 2", "expected_rows": 56_945])
        ]))
        let file = root.appending(path: "october.xlsx"), writer = try MCPExportWriter(request: request, temporaryURL: file)
        for i in counts.indices {
            try await writer.beginQuery(i)
            let columns = (0..<widths[i]).map { WorkspaceDatabaseDataColumn(id: $0, name: "字段\($0)") }
            for start in stride(from: 0, to: counts[i], by: 500) {
                let rows = (start..<min(start + 500, counts[i])).map { row in
                    WorkspaceDatabaseDataRow(id: row, values: (0..<widths[i]).map { .text("\(row)-\($0)-中文") })
                }
                try await writer.consume(.init(columns: columns, rows: rows))
            }
            try await writer.endQuery(.init(columns: columns, rowCount: counts[i]))
        }
        _ = try await writer.finish()
        #expect(await writer.counts == counts)
        for i in counts.indices {
            let xml = try unzip(file, "xl/worksheets/sheet\(i + 1).xml")
            #expect(xml.components(separatedBy: "<row r=").count - 1 == counts[i] + 1)
            #expect(xml.contains("\(counts[i] - 1)-\(widths[i] - 1)-中文"))
        }
    }

    func ownership(_ result: MCPJSONValue) throws -> [String: MCPJSONValue] {
        ["job_id": try #require(result.objectValue?["job_id"]), "access_token": try #require(result.objectValue?["access_token"])]
    }
    func terminal(_ runtime: MCPRuntime, _ key: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let value = try await runtime.call("querycraft_get_export_status", arguments: key)
            if !["queued", "running", "finalizing"].contains(value.objectValue?["status"]?.stringValue ?? "") { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MCPFailure("Test job did not complete.")
    }
    private func fixture(rows: Int, waits: Bool = false) async throws -> (root: URL, runtime: MCPRuntime, profile: ConnectionProfile, registry: DatabaseDriverRegistry, session: MCPExportTestSession) {
        let root = try temporary(), profile = MCPTests().profile()
        let repository = SQLiteConnectionProfileRepository(databaseURL: root.appending(path: "QueryCraft.sqlite"))
        try await repository.insert(profile)
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true; policy.maximumRows = 1; policy.maximumResultBytes = 4_194_304
        try MCPPolicyStore(directory: root).save(policy)
        let registry = DatabaseDriverRegistry(), session = MCPExportTestSession(rowCount: rows, waits: waits)
        await registry.register(MCPExportTestDriver(session: session))
        return (root, MCPRuntime(directory: root, registry: registry), profile, registry, session)
    }
}

private struct MCPExportTestDriver: DatabaseDriver {
    let databaseType = DatabaseType.mysql
    let session: MCPExportTestSession
    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession { session }
    func testConnection(configuration: DatabaseConnectionConfiguration) async throws {}
}

private actor MCPExportTestSession: WorkspaceSession, WorkspaceQueryExportConfiguring {
    let rowCount: Int
    let waits: Bool
    var queryCalls = 0
    var closed = false
    init(rowCount: Int, waits: Bool) { self.rowCount = rowCount; self.waits = waits }
    func configureQueryExport(maximumRowBytes: Int) async throws { #expect(maximumRowBytes == 8_388_608) }
    func connect() async throws {}
    func isConnected() async -> Bool { !closed }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { throw MCPFailure("unused") }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult { throw MCPFailure("unused") }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func executeReadOnlyQuery(_ sql: String, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult { throw MCPFailure("Exporter must not start nested read-only transactions.") }
    func executeStatement(_ sql: String, kind: SQLStatementKind, database: String?, maximumRows: Int?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        guard kind == .read else { return .init(columns: [], rowCount: 0) }
        queryCalls += 1
        if waits { try await Task.sleep(for: .seconds(30)) }
        #expect(maximumRows == nil)
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "id"), .init(id: 1, name: "amount")]
        for start in stride(from: 0, to: rowCount, by: 100) {
            try Task.checkCancellation()
            let rows = (start..<min(start + 100, rowCount)).map { WorkspaceDatabaseDataRow(id: $0, values: [.text(String($0)), .text("1234567890123456789.0123")]) }
            try await onBatch(.init(columns: columns, rows: rows))
        }
        if rowCount == 0 { try await onBatch(.init(columns: columns, rows: [])) }
        return .init(columns: columns, rowCount: rowCount)
    }
    func executeStatement(_ sql: String, kind: SQLStatementKind, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        try await executeStatement(sql, kind: kind, database: database, maximumRows: nil, onBatch: onBatch)
    }
    func close() async { closed = true }
}
