import AppKit
import Foundation
@testable import QueryCraftFeature

private struct SmokeFailure: Error, CustomStringConvertible { let description: String }

@main struct NativeDorisSmoke {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() }
        catch { print("FAIL Doris: \(error)"); exit(1) }
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw SmokeFailure(description: message) } }
    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        for name in ["Doris", "MySQL", "PostgreSQL"] {
            guard let bundle = Bundle(path: env["BENCH_DRIVER_ROOT"]! + "/\(name)-\(architecture).querycraftdriver") else {
                throw SmokeFailure(description: "Missing \(name) bundle")
            }
            try bundle.loadAndReturnError()
            let entry = bundle.principalClass as! QueryCraftDriverBundleEntry.Type
            try await entry.init().activate()
        }
        let source = TransferConnection(endpoint: .init(profileID: UUID(), database: "qc_native_stream"),
                                        configuration: .init(databaseType: .doris, host: "127.0.0.1", port: Int(env["BENCH_DORIS_PORT"]!)!, username: "root", password: nil, database: "qc_native_stream", tlsMode: .disabled))
        let catalog = DataTransferCatalog(), read = try await catalog.open(source)
        do {
            print("Doris source connected")
            try require(try await read.fetchDatabases().contains("qc_native_stream"), "Databases")
            let objects = try await read.fetchObjects(in: source.endpoint.database)
            guard let object = objects.first(where: { $0.name == "native_rows" }) else { throw SmokeFailure(description: "Object catalog") }
            let details = try await read.fetchDetails(for: object, in: source.endpoint.database)
            try require(details.columns.map(\.name) == ["id","payload","amount"], "Column details")
            let expected = try await DataTransferCatalog.query("SELECT id,payload,amount FROM qc_native_stream.native_rows ORDER BY id", session: read, database: source.endpoint.database)
            try require(expected.rows.count == 2 && expected.rows.first?.values[1] == .text("数据🙂"), "Unicode query values")
            for type in [DatabaseType.mysql, .postgresql] {
                let name = "qc_doris_" + UUID().uuidString.prefix(8).lowercased()
                let endpoint = TransferEndpoint(profileID: UUID(), database: type == .mysql ? name : "postgres", schema: type == .postgresql ? name : "")
                let target = TransferConnection(endpoint: endpoint, configuration: .init(databaseType: type, host: "127.0.0.1", port: Int(env[type == .mysql ? "BENCH_MYSQL_PORT" : "BENCH_PG_PORT"]!)!, username: type == .mysql ? "root" : "postgres", password: env["BENCH_PASSWORD"], database: type == .mysql ? "mysql" : "postgres", tlsMode: .disabled))
                let admin = try await DatabaseDriverRegistry.shared.makeSession(configuration: target.configuration)
                print("Connecting owned \(type.rawValue) target")
                try await admin.connect()
                let quote = TransferSQL.dialect(type).identifier
                let setup = type == .mysql ? "CREATE DATABASE \(quote(name)) CHARACTER SET utf8mb4" : "CREATE SCHEMA \(quote(name))"
                _ = try await admin.executeStatement(setup, kind: .ddl(.create), database: type == .mysql ? "mysql" : "postgres") { _ in }
                let table = TransferSQL.qualified(endpoint, "native_rows", type: type)
                _ = try await admin.executeStatement("CREATE TABLE \(table) (id bigint PRIMARY KEY, payload text, amount decimal(30,9))", kind: .ddl(.create), database: type == .mysql ? "mysql" : "postgres") { _ in }
                var config = DataTransferConfiguration(); config.source = source.endpoint; config.target = endpoint; config.content = .dataOnly
                config.objects = try await catalog.objects(source).filter { $0.kind == .table && $0.name == "native_rows" }
                let plan = try await DataTransferPlanner(catalog: catalog).prepare(configuration: config, source: source, target: target)
                let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { item in
                    if item.status == .failed { print("ITEM \(item.message)") }
                }, backups: { _ in })
                try require(result.0 == .completed, "Transfer to \(type): \(result.1)")
                let actual = try await DataTransferCatalog.query("SELECT id,payload,amount FROM \(table) ORDER BY id", session: admin, database: type == .mysql ? "mysql" : "postgres")
                try require(actual.rows.map(\.values) == expected.rows.map(\.values), "Values to \(type)")
                config.content = .structureAndData; config.nameCase = .upper
                let created = try await DataTransferPlanner(catalog: catalog).prepare(configuration: config, source: source, target: target)
                let copied = await DataTransferRunner(catalog: catalog).run(created, authorize: {}, progress: { item in
                    if item.status == .failed { print("ITEM automatic mapping: \(item.message)") }
                }, backups: { _ in })
                try require(copied.0 == .completed, "Automatic Doris type mapping to \(type): \(copied.1)")
                let mapped = try await DataTransferCatalog.query("SELECT id,payload,amount FROM \(TransferSQL.qualified(endpoint, "NATIVE_ROWS", type: type)) ORDER BY id", session: admin, database: type == .mysql ? "mysql" : "postgres")
                try require(mapped.rows.map(\.values) == expected.rows.map(\.values), "Automatic mapping values")
                _ = try await admin.executeStatement(type == .mysql ? "DROP DATABASE \(quote(name))" : "DROP SCHEMA \(quote(name)) CASCADE", kind: .ddl(.drop), database: type == .mysql ? "mysql" : "postgres") { _ in }
                await admin.close(); print("PASS Doris → \(type.rawValue): source metadata/query and native destination, exact decimals/Unicode/NULL")
            }
            await read.close()
        } catch { await read.close(); throw error }
    }
}
