import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceTableDataExportTests {
    @Test("Preparation connects to the captured database, not the active connection database")
    func capturesDatabaseAndPreferences() async throws {
        let original = makeTarget(type: .postgresql, rowCount: 1)
        let factory = RecordingExportSessionFactory(wrapped: original.sessionFactory)
        let target = WorkspaceTableDataExportTarget(sessionFactory: factory,
            configuration: original.configuration, selection: original.selection)
        var preferences = WorkspaceDataExportPreferences()
        preferences.sqlInsertBatchSize = 237
        let request = try await target.makeRequest(format: .sql, preferences: preferences)
        preferences.sqlInsertBatchSize = 500
        #expect(await factory.database == "target_db")
        #expect(request.options.sqlInsertBatchSize == 237)
        #expect(request.options.sqlTableIdentifierParts == ["events.with.dot"])
        await request.source.finish()
    }

    @Test("Lossy binary transport values are rejected while empty tables and NULL remain exportable")
    func rejectsLossyBinary() throws {
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "payload", type: "blob")]
        #expect(throws: WorkspaceDataExportError.self) {
            try WorkspaceTableDataExportRowSource.validateCompleteValues(
                [.init(id: 0, values: [.text("decoded bytes")])], columns: columns, databaseType: .mysql
            )
        }
        try WorkspaceTableDataExportRowSource.validateCompleteValues(
            [.init(id: 0, values: [.null])], columns: columns, databaseType: .mysql
        )
        try WorkspaceTableDataExportRowSource.validateCompleteValues([], columns: columns, databaseType: .mysql)
        try WorkspaceTableDataExportRowSource.validateCompleteValues(
            [.init(id: 0, values: [.text("\\x0102")])],
            columns: [.init(id: 0, name: "payload", type: "bytea")], databaseType: .postgresql
        )
    }

    @Test("Direct exports retain their source and all rows across fetch batches",
          arguments: [DatabaseType.mysql, .postgresql, .doris])
    func exportsCapturedTable(type: DatabaseType) async throws {
        let target = makeTarget(type: type, rowCount: 5_003)
        var preferences = WorkspaceDataExportPreferences()
        preferences.sqlInsertBatchSize = 1_000
        preferences.sqlIncludesDatabaseName = true
        preferences.sqlWrapsInTransaction = true
        let request = try await target.makeRequest(format: .sql, preferences: preferences)
        #expect(request.options.scope == .allTableRows)
        #expect(request.columns.map(\.name) == ["id.with.dot", "value"])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "export.sql")
        let count = try await WorkspaceDataExporter().export(request, to: file)
        let sql = try String(contentsOf: file, encoding: .utf8)
        #expect(count == 5_003)
        #expect(sql.components(separatedBy: "INSERT INTO").count - 1 == 6)
        #expect(sql.contains("'5002'"))
        if type == .postgresql {
            #expect(sql.contains("\"audit\".\"events.with.dot\" (\"id.with.dot\", \"value\")"))
            #expect(sql.contains("OVERRIDING SYSTEM VALUE"))
        } else {
            #expect(sql.contains("`target_db`.`events.with.dot` (`id.with.dot`, `value`)"))
        }
        #expect(sql.contains("COMMIT;") == (type != .doris))
        #expect(sql.contains("computed") == false)
    }

    @Test("Empty tables export without requiring a loaded data view", arguments: WorkspaceDataExportFormat.allCases)
    func exportsEmptyTable(format: WorkspaceDataExportFormat) async throws {
        let request = try await makeTarget(type: .mysql, rowCount: 0).makeRequest(
            format: format, preferences: WorkspaceDataExportPreferences()
        )
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "empty.\(format.fileExtension)")
        #expect(try await WorkspaceDataExporter().export(request, to: file) == 0)
        let data = try Data(contentsOf: file)
        switch format {
        case .json:
            let rows = try #require(JSONSerialization.jsonObject(with: data) as? [Any])
            #expect(rows.isEmpty)
        case .csv:
            #expect(String(decoding: data, as: UTF8.self).contains("id.with.dot"))
        case .sql:
            #expect(String(decoding: data, as: UTF8.self).contains("INSERT INTO") == false)
        case .xlsx:
            #expect(data.starts(with: [0x50, 0x4b]))
        }
    }

    @Test("Custom batch sizes include the exact boundary and the final partial batch",
          arguments: [1, 200, 1_000, 2_000])
    func customBatches(size: Int) async throws {
        var preferences = WorkspaceDataExportPreferences()
        preferences.sqlInsertBatchSize = size
        let request = try await makeTarget(type: .mysql, rowCount: 2_500).makeRequest(
            format: .sql, preferences: preferences
        )
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "batches.sql")
        #expect(try await WorkspaceDataExporter().export(request, to: file) == 2_500)
        let sql = try String(contentsOf: file, encoding: .utf8)
        #expect(sql.components(separatedBy: "INSERT INTO").count - 1 == (2_500 + size - 1) / size)
    }

    @Test("SQL literals preserve backslashes and reject incomplete binary previews")
    func literalEncoding() throws {
        #expect(try WorkspaceSQLExportDialect.mysql.literal(.text("a\\b")) == "CONVERT(X'615C62' USING utf8mb4)")
        #expect(try WorkspaceSQLExportDialect.postgresql.literal(.text("a\\b'c")) == "E'a\\\\b''c'")
        #expect(throws: WorkspaceDataExportError.self) {
            try WorkspaceSQLExportDialect.mysql.literal(.binary(byteCount: 100, preview: [1]))
        }
        #expect(WorkspaceSQLExportDialect(databaseType: .redis) == nil)
        #expect(WorkspaceSQLExportDialect(databaseType: .elasticsearch) == nil)
        #expect(WorkspaceSQLExportDialect(databaseType: .kafka) == nil)
    }

    @Test("Byte limits split statements independently from row limits")
    func boundsStatementBytes() async throws {
        let original = try await makeTarget(type: .mysql, rowCount: 5).makeRequest(
            format: .sql, preferences: WorkspaceDataExportPreferences()
        )
        var options = original.options
        options.sqlMaximumStatementBytes = 125
        let request = WorkspaceDataExportRequest(columns: original.columns, options: options,
            estimatedRowCount: nil, worksheetName: original.worksheetName, source: original.source)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "bounded.sql")
        #expect(try await WorkspaceDataExporter().export(request, to: file) == 5)
        let sql = try String(contentsOf: file, encoding: .utf8)
        let statements = sql.components(separatedBy: ";\n").filter { !$0.isEmpty }
        #expect(statements.count > 1)
        #expect(statements.allSatisfy { $0.utf8.count + 2 <= 125 })
    }

    private func makeTarget(type: DatabaseType, rowCount: Int) -> WorkspaceTableDataExportTarget {
        let selection = WorkspaceDatabaseObjectSelection(databaseName: "target_db",
            objectName: type == .postgresql ? "audit.events.with.dot" : "events.with.dot", kind: .table)
        let origin = WorkspaceDatabaseDataColumn.Origin(databaseName: "target_db", schemaName: "audit",
            tableName: "events.with.dot", columnName: "id.with.dot")
        let page = WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "id.with.dot", type: "bigint", origin: origin),
                WorkspaceDatabaseDataColumn(id: 1, name: "value", type: "text"),
                WorkspaceDatabaseDataColumn(id: 2, name: "computed", type: "bigint"),
            ],
            rows: (0..<rowCount).map { .init(id: $0, values: [.text(String($0)), .text("O'Reilly"), .text("42")]) },
            offset: 0, limit: max(1, rowCount), hasNextPage: false
        )
        let details = WorkspaceDatabaseObjectDetails(columns: [
            column("id.with.dot", extra: type == .postgresql ? "IDENTITY" : "auto_increment"),
            column("value"), column("computed", extra: "STORED GENERATED"),
        ], ddl: "")
        let factory = InMemoryWorkspaceSessionFactory(databases: ["target_db"],
            objectsByDatabase: ["target_db": [selection.object]], detailsByObject: [selection: details],
            dataByObject: [selection: page])
        return WorkspaceTableDataExportTarget(sessionFactory: factory,
            configuration: DatabaseConnectionConfiguration(databaseType: type, host: "localhost", port: 3306,
                username: "test", password: nil, database: "another_db", tlsMode: .disabled), selection: selection)
    }

    private func column(_ name: String, extra: String = "") -> WorkspaceDatabaseColumn {
        .init(name: name, type: "text", collation: nil, isNullable: true, key: "",
              defaultValue: nil, extra: extra, comment: "")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "TableExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor RecordingExportSessionFactory: WorkspaceSessionFactory {
    let wrapped: any WorkspaceSessionFactory
    private(set) var database: String?

    init(wrapped: any WorkspaceSessionFactory) { self.wrapped = wrapped }

    func makeSession(configuration: DatabaseConnectionConfiguration) async -> any WorkspaceSession {
        database = configuration.database
        return await wrapped.makeSession(configuration: configuration)
    }
}
