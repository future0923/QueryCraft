import AppKit
import Foundation
@testable import QueryCraftFeature

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private actor Rows {
    var values: [[WorkspaceDatabaseDataCell]] = []
    func append(_ batch: WorkspaceDatabaseDataBatch) { values += batch.rows.map(\.values) }
}

@main struct DataTransferDockerCheck {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let type = DatabaseType(rawValue: env["CHECK_DRIVER"]!)!
        let bundle = Bundle(path: env["CHECK_BUNDLE"]!)!
        try bundle.loadAndReturnError()
        guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else { throw CheckFailure(description: "Missing driver entry") }
        try await entry.init().activate()
        if env["CHECK_LOAD_ONLY"] == "1" {
            print("PASS \(type.rawValue): packaged driver loaded and activated")
            return
        }
        let database = env["CHECK_DATABASE"]!, namespace = env["CHECK_NAMESPACE"]!
        let config = DatabaseConnectionConfiguration(databaseType: type, host: "127.0.0.1", port: Int(env["CHECK_PORT"]!)!, username: env["CHECK_USER"]!, password: env["CHECK_PASSWORD"], database: database, tlsMode: .disabled)
        let session = try await DatabaseDriverRegistry.shared.makeSession(configuration: config)
        try await session.connect()
        do {
            try await verify(session, configuration: config, namespace: namespace)
            await session.close()
        } catch { await session.close(); throw error }
    }
    static func verify(_ session: any WorkspaceSession, configuration config: DatabaseConnectionConfiguration, namespace: String) async throws {
        let type = config.databaseType, isPG = type == .postgresql
        let database = config.database!
        let dialect = WorkspaceSQLExportDialect(databaseType: type)!
        let factory = DefaultWorkspaceSessionFactory()
        func selection(_ name: String) -> WorkspaceDatabaseObjectSelection {
            .init(databaseName: database, objectName: isPG ? "\(namespace).\(name)" : name, kind: .table)
        }
        func qualified(_ name: String) -> String { [namespace, name].map(dialect.identifier).joined(separator: ".") }
        func sql(_ text: String, _ kind: SQLStatementKind = .control) async throws {
            _ = try await session.executeStatement(text, kind: kind, database: database) { _ in }
        }
        func fetch(_ name: String) async throws -> [[WorkspaceDatabaseDataCell]] {
            let rows = Rows()
            _ = try await session.executeStatement("SELECT * FROM \(qualified(name)) ORDER BY id", kind: .read, database: database) { await rows.append($0) }
            return await rows.values
        }
        let expected = try await fetch("source.with.dot")
        try check(expected.count == 5_003, "Seed count")
        let directory = FileManager.default.temporaryDirectory.appending(path: "QueryCraftTransfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["CHECK_KEEP_EXPORTS"] != "1" { try? FileManager.default.removeItem(at: directory) } }
        print("Exports: \(directory.path)")
        for format in WorkspaceDataExportFormat.allCases {
            if let requested = ProcessInfo.processInfo.environment["CHECK_FORMAT"], requested != format.rawValue { continue }
            var preferences = WorkspaceDataExportPreferences()
            preferences.sqlIncludesDatabaseName = true
            if format == .xlsx { preferences.nullStyle = .empty }
            preferences.sanitizesSpreadsheetFormulas = false // Explicit lossless transfer mode.
            let exportTarget = WorkspaceTableDataExportTarget(sessionFactory: factory, configuration: config, selection: selection("source.with.dot"))
            let request = try await exportTarget.makeRequest(format: format, preferences: preferences)
            let url = directory.appending(path: "data.\(format.fileExtension)")
            let count = try await WorkspaceDataExporter().export(request, to: url)
            try check(count == expected.count, "\(format): lost rows across pages")
            var options = WorkspaceDataImportOptions()
            options.format = .detect(url)
            if format == .xlsx { options.nullToken = "" }
            if format == .json { options.headerRow = 0; options.firstDataRow = 1 }
            let file = try await WorkspaceDataImportReader().read(url: url, options: options)
            if ProcessInfo.processInfo.environment["CHECK_LARGE_VALUES"] == "1" {
                try check(file.isDiskBacked, "Large import must use the disk snapshot")
            }
            if format == .sql {
                let text = try String(contentsOf: url, encoding: .utf8)
                try check(text.components(separatedBy: "INSERT INTO").count - 1 == 6, "Default SQL batch count")
                // Execute the actual exported statements, changing only the captured table identifier.
                let rewritten = text.replacingOccurrences(of: qualified("source.with.dot"), with: qualified("copy.with.dot"))
                for statement in rewritten.components(separatedBy: ";\n") where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await sql(statement, .insert)
                }
                try check(try await fetch("copy.with.dot") == expected, "\(format): native SQL execution differs")
                if type != .doris {
                    try await sql("DELETE FROM \(qualified("copy.with.dot"))", .delete(hasWhereClause: false))
                }
            }
            if type == .doris {
                try check(file.rowCount == expected.count, "Doris \(format): parse count")
                let expectedValues = expected.map { row in
                    row.map { cell -> String? in if case let .text(value) = cell { return value }; return nil }
                }
                let sourceIndices = request.columns.map { column in file.columns.firstIndex(of: column.name)! }
                let parsedValues = try file.rows.map { row in sourceIndices.map { row[$0] } }
                    .sorted { (($0.first ?? nil) ?? "") < (($1.first ?? nil) ?? "") }
                try check(parsedValues == expectedValues, "Doris \(format): exported cells differ")
                print("PASS Doris \(format): 5003 rows exported" + (format == .sql ? ", raw SQL replay matches" : ""))
                continue
            }
            let target = WorkspaceDataImportTarget(sessionFactory: factory, configuration: config, selection: selection("copy.with.dot"))
            let schema = try await target.loadSchema()
            let plan = WorkspaceDataImportPlan(file: file, schema: schema, mapping: schema.automaticMapping(file.columns), batchSize: 500, dialect: dialect)
            let outcome = await WorkspaceDataImporter().run(target: target, plan: plan, authorize: {}, progress: { _ in })
            try check(outcome.status == .completed && outcome.committedRows == expected.count, "\(format): \(outcome.message)")
            let actual = try await fetch("copy.with.dot")
            if actual != expected {
                let first = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }
                throw CheckFailure(description: "\(format): value mismatch at row \(first?.offset ?? -1): \(String(describing: first?.element))")
            }
            try await sql("DELETE FROM \(qualified("copy.with.dot"))", .delete(hasWhereClause: false))
            print("PASS \(type.rawValue) \(format): 5003 rows round-trip, every cell matches")
            if format == .sql {
                var broken = try file.rows
                broken[500] = broken[0] // First batch succeeds, second hits duplicate PK.
                let badFile = try WorkspaceDataImportFile(columns: file.columns, rows: broken)
                let badPlan = WorkspaceDataImportPlan(file: badFile, schema: schema, mapping: plan.mapping, batchSize: 500, dialect: dialect)
                let failed = await WorkspaceDataImporter().run(target: target, plan: badPlan, authorize: {}, progress: { _ in })
                try check(failed.status == .failed && failed.committedRows == 0, "Duplicate must fail: \(failed.message)")
                try check(try await fetch("copy.with.dot").isEmpty, "Rollback left rows")
                let task = Task {
                    await WorkspaceDataImporter().run(target: target, plan: plan, authorize: {}, progress: { _ in withUnsafeCurrentTask { $0?.cancel() } })
                }
                let cancelled = await task.value
                try check(cancelled.status == .cancelled && cancelled.committedRows == 0, "Cancellation outcome: \(cancelled.message)")
                try check(try await fetch("copy.with.dot").isEmpty, "Cancellation left rows")
                print("PASS \(type.rawValue): second-batch failure and cancellation both roll back to zero rows")
            }
        }
    }
}
