import AppKit
import Foundation
@testable import QueryCraftFeature

private struct TransactionCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct SQLTransactionStateCheck {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: env["CHECK_DRIVER_DIRECTORY"]!)
        // Load MySQL and Doris together to check their shared transport identity.
        let names = env["CHECK_DORIS_FIRST"] == "1"
            ? ["Doris", "MySQL", "PostgreSQL", "Redis", "Elasticsearch", "Kafka"]
            : ["MySQL", "Doris", "PostgreSQL", "Redis", "Elasticsearch", "Kafka"]
        for name in names {
            let path = directory.appendingPathComponent("\(name)-\(env["CHECK_ARCH"]!).querycraftdriver")
            guard let bundle = Bundle(url: path) else { throw TransactionCheckFailure(description: "Missing \(name) bundle") }
            try bundle.loadAndReturnError()
            guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else {
                throw TransactionCheckFailure(description: "Missing \(name) entry")
            }
            try await entry.init().activate()
        }
        // Use the same signature, compatibility and activation checks as app startup.
        // Direct Bundle loading alone can miss a broken nested framework layout.
        let installer = DatabaseDriverPackageInstaller(
            driversDirectory: directory,
            compatibilityValidator: .init(appVersion: env["CHECK_APP_VERSION"]!),
            maintainsInstalledDrivers: false
        )
        let installed = await installer.loadInstalledDrivers()
        guard Set(installed.map(\.databaseType)) == Set(DatabaseType.allCases) else {
            throw TransactionCheckFailure(description: "Installed drivers did not pass the app startup checks")
        }
        print("PASS drivers: six bundles passed startup signature, compatibility and activation checks")
        if env["CHECK_LOAD_ONLY"] == "1" { return }
        let type = DatabaseType(rawValue: env["CHECK_DRIVER"]!)!
        let config = DatabaseConnectionConfiguration(
            databaseType: type, host: "127.0.0.1", port: Int(env["CHECK_PORT"]!)!,
            username: env["CHECK_USER"]!, password: env["CHECK_PASSWORD"],
            database: env["CHECK_DATABASE"]!, tlsMode: .disabled
        )
        let session = try await DatabaseDriverRegistry.shared.makeSession(configuration: config)
        try await session.connect()
        if env["CHECK_READ_ONLY"] == "1" {
            do {
                let result = try await session.executeReadOnlyQuery("SELECT 1", database: nil, onBatch: { _ in })
                guard result.rowCount == 1 else { throw TransactionCheckFailure(description: "Read-only smoke returned no row") }
                await session.close()
            } catch {
                await session.close()
                throw error
            }
            print("PASS \(type.rawValue): read-only query with independently upgraded peer driver")
            return
        }
        let table = "qc_txn_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            try await verify(session, type: type, table: table)
            try await verifyEditor(config, table: table + "_editor")
            _ = try await session.executeStatement("DROP TABLE IF EXISTS \(table)", kind: .ddl(.drop), database: nil, onBatch: { _ in })
            await session.close()
        } catch {
            _ = try? await session.executeStatement("ROLLBACK", kind: .transaction(.rollback), database: nil, onBatch: { _ in })
            _ = try? await session.executeStatement("DROP TABLE IF EXISTS \(table)", kind: .ddl(.drop), database: nil, onBatch: { _ in })
            await session.close()
            throw error
        }
    }

    static func verify(_ session: any WorkspaceSession, type: DatabaseType, table: String) async throws {
        func execute(_ sql: String, _ kind: SQLStatementKind, _ state: WorkspaceQueryTransactionState) async throws {
            let result = try await session.executeStatement(sql, kind: kind, database: nil, maximumRows: kind == .read ? 10 : nil, onBatch: { _ in })
            guard result.transactionState == state else {
                throw TransactionCheckFailure(description: "Incorrect transaction state for \(sql): \(result.transactionState)")
            }
        }
        let control = type == .mysql ? "SET NAMES utf8mb4" : "SET client_encoding TO 'UTF8'"
        try await execute(control, .control, .autoCommit)
        try await execute("CREATE TABLE \(table) (id INTEGER PRIMARY KEY)", .ddl(.create), .autoCommit)
        try await execute("BEGIN", .transaction(.begin), .inTransaction)
        try await execute(control, .control, .inTransaction)
        try await execute("SELECT * FROM \(table) WHERE 1 = 0", .read, .inTransaction)
        try await execute("SAVEPOINT qc_probe", .transaction(.savepoint), .inTransaction)
        try await execute("INSERT INTO \(table) VALUES (1)", .insert, .inTransaction)
        try await execute("ROLLBACK TO SAVEPOINT qc_probe", .transaction(.savepoint), .inTransaction)
        try await execute("COMMIT", .transaction(.commit), .autoCommit)
        try await execute("BEGIN", .transaction(.begin), .inTransaction)
        try await execute("ALTER TABLE \(table) ADD COLUMN note INTEGER", .ddl(.alter), type == .mysql ? .autoCommit : .inTransaction)
        try await execute("ROLLBACK", .transaction(.rollback), .autoCommit)
        if type == .mysql {
            try await execute("SET autocommit = 0", .control, .autoCommit)
            try await execute("INSERT INTO \(table) (id) VALUES (2)", .insert, .inTransaction)
            try await execute("SET autocommit = 1", .control, .autoCommit)
        } else {
            try await execute("BEGIN", .transaction(.begin), .inTransaction)
            do {
                _ = try await session.executeStatement("SELECT * FROM qc_missing_\(table)", kind: .read, database: nil, onBatch: { _ in })
                throw TransactionCheckFailure(description: "Invalid SQL unexpectedly succeeded")
            } catch is TransactionCheckFailure { throw TransactionCheckFailure(description: "SQL errors must remain failures") }
            catch {}
            // COMMIT on a failed PostgreSQL transaction performs a rollback.
            try await execute("COMMIT", .transaction(.commit), .autoCommit)
            try await execute("SELECT 1", .read, .autoCommit)
        }
        print("PASS \(type.rawValue): SET, empty SELECT in transaction, savepoint, DDL, commit/rollback and server state transitions")
    }

    @MainActor static func verifyEditor(_ config: DatabaseConnectionConfiguration, table: String) async throws {
        let document = WorkspaceQueryDocumentModel(title: "Transaction regression", configuration: config, sessionFactory: DefaultWorkspaceSessionFactory())
        let control = config.databaseType == .mysql ? "SET NAMES utf8mb4;" : "SET client_encoding TO 'UTF8';"
        let sql = "\(control) CREATE TEMPORARY TABLE \(table) (id INTEGER); INSERT INTO \(table) VALUES (1); SELECT * FROM \(table); DROP TABLE \(table);"
        do {
            let source = SQLSourceSnapshot(revision: SQLSourceRevision(1), text: sql)
            let snapshot = try await SQLStructuralParser().parse(source)
            let target = try SQLExecutionTargetResolver.resolve(.all, source: source, selectedRange: NSRange(location: 0, length: 0), parseSnapshot: snapshot)
            let plan = try SQLExecutionBatchPreflight.makePlan(target: target, parseSnapshot: snapshot)
            await document.execute(plan, policy: .writesAllowed)
            guard document.statementResults.count == 5 else { throw TransactionCheckFailure(description: "Editor did not execute all statements") }
            for statement in document.statementResults {
                guard case .completed = statement.state else {
                    throw TransactionCheckFailure(description: "Editor statement failed: \(statement.state)")
                }
            }
            await document.closeForWorkspaceShutdown()
        } catch {
            await document.closeForWorkspaceShutdown()
            throw error
        }
        print("PASS \(config.databaseType.rawValue): real editor parser/model completes SET → CREATE → INSERT → SELECT → DROP")
    }
}
