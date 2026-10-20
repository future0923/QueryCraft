import AppKit
import Foundation
@testable import QueryCraftFeature

private struct LiveFailure: Error, CustomStringConvertible { let description: String }
private actor IdentityRow {
    var value: String?
    func receive(_ batch: WorkspaceDatabaseDataBatch) {
        if let row = batch.rows.first, case let .text(text) = row.value(at: 0) { value = text }
    }
}
private actor NativeChannelRecorder {
    var native = false
    func receive(_ item: TransferItemProgress) { if item.message.contains("COPY") || item.message.contains("LOAD DATA") { native = true } }
}

@main struct DatabaseTransferLiveCheck {
    static func require(_ value: Bool, _ message: String) throws { if !value { throw LiveFailure(description: message) } }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
    }
    static func execute(_ sql: String, session: any WorkspaceSession, database: String, kind: SQLStatementKind = .ddl(.create)) async throws {
        do { _ = try await session.executeStatement(sql, kind: kind, database: database) { _ in } }
        catch WorkspaceSessionError.transactionStateUnavailable { }
    }
    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        if env["TRANSFER_LOAD_ONLY"] == "1", let driverRoot = env["TRANSFER_DRIVER_ROOT"] {
            for name in ["MySQL", "PostgreSQL", "Doris", "Redis", "Elasticsearch", "Kafka"] {
                guard let bundle = Bundle(path: driverRoot + "/\(name)-\(architecture).querycraftdriver") else { throw LiveFailure(description: "Missing \(name) driver") }
                try bundle.loadAndReturnError()
                guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else { throw LiveFailure(description: "Missing \(name) entry") }
                try await entry.init().activate()
                print("PASS \(name): installed driver loaded and activated against the updated host")
            }
            return
        }
        guard let sourceRaw = env["TRANSFER_SOURCE_TYPE"], let sourceType = DatabaseType(rawValue: sourceRaw),
              let targetRaw = env["TRANSFER_TARGET_TYPE"], let targetType = DatabaseType(rawValue: targetRaw),
              let driverRoot = env["TRANSFER_DRIVER_ROOT"], let token = env["TRANSFER_TOKEN"] else { throw LiveFailure(description: "Missing test environment") }
        for type in Set([sourceType, targetType]) {
            let name = type == .mysql ? "MySQL" : "PostgreSQL"
            guard let bundle = Bundle(path: driverRoot + "/\(name)-\(architecture).querycraftdriver") else { throw LiveFailure(description: "Missing test driver") }
            try bundle.loadAndReturnError()
            guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else { throw LiveFailure(description: "Missing bundle entry") }
            try await entry.init().activate()
        }
        func connection(_ side: String, type: DatabaseType) -> TransferConnection {
            let isPG = type == .postgresql
            let database = isPG ? "postgres" : "qc_xfer_" + token + "_" + side.lowercased()
            let schema = isPG ? "qc_xfer_" + token + "_" + side.lowercased() : ""
            let endpoint = TransferEndpoint(profileID: UUID(), database: database, schema: schema)
            return .init(endpoint: endpoint, configuration: .init(databaseType: type, host: "127.0.0.1", port: Int(env["TRANSFER_\(side)_PORT"]!)!, username: isPG ? "postgres" : "root", password: env["TRANSFER_\(side)_PASSWORD"], database: isPG ? "postgres" : "mysql", tlsMode: .disabled))
        }
        let source = connection("SOURCE", type: sourceType), target = connection("TARGET", type: targetType)
        let sourceAdmin = try await DatabaseDriverRegistry.shared.makeSession(configuration: source.configuration)
        try await sourceAdmin.connect()
        let targetAdmin = try await DatabaseDriverRegistry.shared.makeSession(configuration: target.configuration)
        try await targetAdmin.connect()
        do {
            for (connection, session) in [(source, sourceAdmin), (target, targetAdmin)] {
                let quote = TransferSQL.dialect(connection.type).identifier
                let sql = connection.type == .postgresql ? "CREATE SCHEMA \(quote(connection.endpoint.schema))" : "CREATE DATABASE \(quote(connection.endpoint.database)) CHARACTER SET utf8mb4"
                try await execute(sql, session: session, database: connection.type == .postgresql ? "postgres" : "mysql")
            }
            try await verify(source: source, target: target)
            await cleanup(source, session: sourceAdmin); await cleanup(target, session: targetAdmin)
        } catch {
            await cleanup(source, session: sourceAdmin); await cleanup(target, session: targetAdmin)
            await sourceAdmin.close(); await targetAdmin.close(); throw error
        }
        await sourceAdmin.close(); await targetAdmin.close()
    }
    static func cleanup(_ connection: TransferConnection, session: any WorkspaceSession) async {
        let quote = TransferSQL.dialect(connection.type).identifier
        let sql = connection.type == .postgresql ? "DROP SCHEMA IF EXISTS \(quote(connection.endpoint.schema)) CASCADE" : "DROP DATABASE IF EXISTS \(quote(connection.endpoint.database))"
        // All names are generated in this script and are never user profile names.
        try? await execute(sql, session: session, database: connection.type == .postgresql ? "postgres" : "mysql", kind: .ddl(.drop))
    }
    static func verify(source: TransferConnection, target: TransferConnection) async throws {
        let catalog = DataTransferCatalog(), read = try await catalog.open(source), write = try await catalog.open(target)
        do {
            let same = source.type == target.type
            func q(_ name: String, _ connection: TransferConnection) -> String { TransferSQL.qualified(connection.endpoint, name, type: connection.type) }
            let binary = source.type == .postgresql ? "bytea" : "blob"
            let generated = same ? ", computed bigint GENERATED ALWAYS AS (id + 1) STORED" : ""
            var extras = ""
            if same && source.type == .postgresql {
                try await execute("CREATE TYPE \(q("state_type", source)) AS ENUM ('active','暂停')", session: read, database: source.endpoint.database)
                extras = ", state \(q("state_type", source)) DEFAULT 'active', tags \(q("state_type", source))[] DEFAULT ARRAY['active'::\(q("state_type", source))]"
                try await execute("CREATE SEQUENCE \(q("counter", source)) START WITH 40", session: read, database: source.endpoint.database)
                try await execute("SELECT nextval(\(try TransferSQL.string(q("counter", source), type: .postgresql)))", session: read, database: source.endpoint.database, kind: .insert)
            }
            let identity = same && source.type == .postgresql ? " GENERATED ALWAYS AS IDENTITY" : ""
            let definition = "id bigint\(identity) PRIMARY KEY, payload text, amount decimal(30,9), raw \(binary), flag boolean\(generated)\(extras)"
            try await execute("CREATE TABLE \(q("parent.dot", source)) (\(definition))" + (source.type == .mysql ? " ENGINE=InnoDB" : ""), session: read, database: source.endpoint.database)
            let comment = "O'Reilly\\path 中文"
            if source.type == .postgresql {
                try await execute("COMMENT ON COLUMN \(q("parent.dot", source)).payload IS \(try TransferSQL.string(comment, type: .postgresql))", session: read, database: source.endpoint.database)
            }
            if same {
                try await execute("CREATE TABLE \(q("child.dot", source)) (id bigint PRIMARY KEY, parent_id bigint NOT NULL, CONSTRAINT qc_fk FOREIGN KEY (parent_id) REFERENCES \(q("parent.dot", source))(id))" + (source.type == .mysql ? " ENGINE=InnoDB" : ""), session: read, database: source.endpoint.database)
                let options = source.type == .postgresql ? " WITH (security_barrier=true,security_invoker=true)" : ""
                let check = source.type == .postgresql ? " WITH LOCAL CHECK OPTION" : ""
                try await execute("CREATE VIEW \(q("view.dot", source))\(options) AS SELECT id,payload FROM \(q("parent.dot", source)) WHERE id>0\(check)", session: read, database: source.endpoint.database)
                if source.type == .postgresql {
                    try await execute("CREATE MATERIALIZED VIEW \(q("materialized.dot", source)) AS SELECT COUNT(*) AS total FROM \(q("parent.dot", source)) WITH NO DATA", session: read, database: source.endpoint.database)
                    try await execute("CREATE FUNCTION \(q("audit_trigger", source))() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$", session: read, database: source.endpoint.database)
                    try await execute("CREATE TRIGGER qc_audit BEFORE INSERT ON \(q("parent.dot", source)) FOR EACH ROW EXECUTE FUNCTION \(q("audit_trigger", source))()", session: read, database: source.endpoint.database)
                } else {
                    try await execute("CREATE TRIGGER \(q("qc_audit", source)) BEFORE INSERT ON \(q("parent.dot", source)) FOR EACH ROW SET NEW.payload=NEW.payload", session: read, database: source.endpoint.database)
                }
                try await execute("CREATE INDEX qc_payload ON \(q("parent.dot", source)) (id,payload\(source.type == .mysql ? "(12)" : ""))", session: read, database: source.endpoint.database)
                let function = source.type == .postgresql
                    ? "CREATE FUNCTION \(q("add_one", source))(v bigint) RETURNS bigint LANGUAGE sql IMMUTABLE AS $$ SELECT v+1 $$"
                    : "CREATE FUNCTION \(q("add_one", source))(v BIGINT) RETURNS BIGINT DETERMINISTIC RETURN v+1"
                try await execute(function, session: read, database: source.endpoint.database)
            }
            let values = try (1...203).map { id -> String in
                var content = id % 7 == 0 ? "" : "中文🙂 O'Reilly'\u{301}\\\u{301}path \(id)"
                if id == 1 { content = "\\N" }
                if id == 2 { content = "\\." }
                if id == 3 { content = "NULL" }
                if id == 4 {
                    content = String(String.UnicodeScalarView((0...127).compactMap { value in
                        value == 0 && !(source.type == .mysql && target.type == .mysql) ? nil : UnicodeScalar(value)
                    }))
                }
                let text = id % 5 == 0 ? "NULL" : try TransferSQL.string(content, type: source.type)
                let blob = source.type == .postgresql ? "decode('00ff8027','hex')" : "X'00ff8027'"
                return "(\(id),\(text),123456789012345678901.123456789,\(blob),\(id % 2 == 0 ? "TRUE" : "FALSE"))"
            }.joined(separator: ",")
            let overrideIdentity = same && source.type == .postgresql ? " OVERRIDING SYSTEM VALUE" : ""
            try await execute("INSERT INTO \(q("parent.dot", source)) (id,payload,amount,raw,flag)\(overrideIdentity) VALUES \(values)", session: read, database: source.endpoint.database, kind: .insert)
            if same { try await execute("INSERT INTO \(q("child.dot", source)) (id,parent_id) SELECT id,id FROM \(q("parent.dot", source))", session: read, database: source.endpoint.database, kind: .insert) }
            if same && source.type == .postgresql { try await execute("REFRESH MATERIALIZED VIEW \(q("materialized.dot", source))", session: read, database: source.endpoint.database) }
            let available = try await DataTransferCatalog.objects(source, session: read)
            var config = DataTransferConfiguration()
            config.source = source.endpoint; config.target = target.endpoint; config.batchSize = 100
            config.objects = available.filter { [.table, .view, .materializedView, .function, .trigger].contains($0.kind) || $0.kind == .sequence && $0.name == "counter" }
            func run(_ configuration: DataTransferConfiguration, cancel: Bool = false) async throws -> TransferRunStatus {
                let plan = try await DataTransferPlanner(catalog: catalog).prepare(configuration: configuration, source: source, target: target, ownership: .skip)
                let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { item in
                    if cancel && item.readRows >= 100 { withUnsafeCurrentTask { $0?.cancel() } }
                    if item.status == .failed || item.status == .uncertain { print("ITEM \(item.name): \(item.message)") }
                }, backups: { _ in })
                if ![TransferRunStatus.completed, .cancelled].contains(result.0) { print("OUTCOME \(result.0): \(result.1)") }
                return result.0
            }
            try require(try await run(config) == .completed, "Initial structure and data transfer")
            func rows(_ connection: TransferConnection, session: any WorkspaceSession, name: String = "parent.dot") async throws -> [[WorkspaceDatabaseDataCell]] {
                let raw = connection.type == .postgresql ? "encode(raw,'hex')" : "LOWER(HEX(raw))"
                let bool = connection.type == .postgresql && source.type == .postgresql ? "CASE WHEN flag THEN '1' ELSE '0' END" : "CAST(flag AS \(connection.type == .postgresql ? "text" : "CHAR"))"
                return try await DataTransferCatalog.query("SELECT id,payload,amount,\(raw) AS raw,\(bool) AS flag FROM \(q(name, connection)) ORDER BY id", session: session, database: connection.endpoint.database).rows.map(\.values)
            }
            let expected = try await rows(source, session: read)
            try require(try await rows(target, session: write) == expected, "All 203 rows including binary/precision/NULL must match")
            if source.type == .postgresql {
                let columns = try await DataTransferCatalog.columns(.init(kind: .table, name: "parent.dot"), connection: target, session: write)
                try require(columns.first { $0.name == "payload" }?.comment == comment, "Column comments retain quotes, backslashes and Unicode")
            }
            if same {
                let function = try await DataTransferCatalog.query("SELECT \(q("add_one", target))(41) AS value", session: write, database: target.endpoint.database)
                try require(function.rows.first.flatMap { function.text($0, "value") } == "42", "Routine definition must execute in the target")
            }
            if same && source.type == .postgresql {
                let expected = try await DataTransferCatalog.query("SELECT state::text AS state,tags::text AS tags,computed FROM \(q("parent.dot", source)) ORDER BY id", session: read, database: source.endpoint.database).rows.map(\.values)
                let actual = try await DataTransferCatalog.query("SELECT state::text AS state,tags::text AS tags,computed FROM \(q("parent.dot", target)) ORDER BY id", session: write, database: target.endpoint.database).rows.map(\.values)
                try require(actual == expected, "Enum, enum arrays, defaults and generated columns")
                let next = try await DataTransferCatalog.query("SELECT nextval(\(try TransferSQL.string(q("counter", target), type: .postgresql))) AS value", session: write, database: target.endpoint.database)
                try require(next.rows.first.flatMap { next.text($0, "value") } == "41", "Standalone sequence position")
                let materialized = try await DataTransferCatalog.query("SELECT total FROM \(q("materialized.dot", target))", session: write, database: target.endpoint.database)
                try require(materialized.rows.first.flatMap { materialized.text($0, "total") } == "203", "Materialized view must populate after table data")
                let viewOptions = try await DataTransferCatalog.query("SELECT reloptions::text AS options FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=\(try TransferSQL.string(target.endpoint.schema, type: .postgresql)) AND c.relname='view.dot'", session: write, database: target.endpoint.database)
                let options = viewOptions.rows.first.flatMap { viewOptions.text($0, "options") } ?? ""
                try require(options.contains("security_barrier=true") && options.contains("security_invoker=true") && options.contains("check_option=local"), "View security and check options")
                try await execute("BEGIN", session: write, database: target.endpoint.database, kind: .transaction(.begin))
                let nextID = IdentityRow()
                _ = try await write.executeStatement("INSERT INTO \(q("parent.dot", target)) (payload) VALUES ('identity check') RETURNING id", kind: .insert, database: target.endpoint.database) { await nextID.receive($0) }
                try require(await nextID.value == "204", "Identity sequence was advanced after explicit inserts")
                try await execute("ROLLBACK", session: write, database: target.endpoint.database, kind: .transaction(.rollback))
                print("PASS PostgreSQL: enum/array/default, GENERATED ALWAYS identity, stored generated column and standalone sequence position")
            }
            print("PASS \(source.type.rawValue) → \(target.type.rawValue): structure+data, 203 rows, complete binary and exact decimals")
            if envNativeEdges {
                var duplicate = config; duplicate.content = .dataOnly; duplicate.objects = available.filter { $0.kind == .table }
                try require(try await run(duplicate) == .failed, "Duplicate keys must fail instead of silently skipping rows")
                try require(try await rows(target, session: write) == expected, "Duplicate-key failure must preserve target rows")
                print("PASS native duplicate-key rejection and rollback")
            }
            config.objects = available.filter { $0.kind == .table }; config.content = .dataOnly; config.strategy = .upsert
            try require(try await run(config) == .completed, "Upsert")
            try require(try await rows(target, session: write) == expected, "Upsert must not duplicate data")
            config.strategy = .overwrite
            try require(try await run(config) == .completed, "Overwrite")
            try require(try await rows(target, session: write) == expected, "Overwrite value equality")
            let cancelled = Task { try await run(config, cancel: true) }
            try require(try await cancelled.value == .cancelled, "Cancellation")
            try require(try await rows(target, session: write) == expected, "Cancelled overwrite must restore all original rows")
            print("PASS \(source.type.rawValue) → \(target.type.rawValue): upsert, overwrite, cancellation restores original rows")
            config.tableFilters = Dictionary(uniqueKeysWithValues: config.objects.map { ($0.name, "id<=101") })
            try require(try await run(config) == .completed, "Filtered overwrite")
            try require(try await rows(target, session: write).count == 101, "Filter count")
            if same {
                config.content = .structureAndData; config.strategy = .rebuild; config.objects = available.filter { [.table, .view, .materializedView, .function].contains($0.kind) || $0.kind == .sequence && $0.name == "counter" || source.type == .postgresql && $0.kind == .trigger }; config.tableFilters = [:]
                try require(try await run(config) == .completed, "Rebuild")
                try require(try await rows(target, session: write) == expected, "Rebuild value equality")
                let remaining = try await DataTransferCatalog.objects(target, session: write)
                try require(!remaining.contains { $0.name.hasPrefix("__qc_bak_") }, "Successful rebuild must clean original backups")
                print("PASS \(source.type.rawValue): FK-linked rebuild, view replacement, index copying and backup cleanup")
            }
            config.content = .structureAndData; config.strategy = .append; config.nameCase = .upper
            config.objects = available.filter { $0.kind == .table }; config.operationTimeoutSeconds = 0
            config.tableFilters = Dictionary(uniqueKeysWithValues: config.objects.map { ($0.name, "SELECT * FROM \(q($0.name, source)) WHERE id<=101") })
            try require(try await run(config) == .completed, "Uppercase target names and full SELECT filters")
            try require(try await rows(target, session: write, name: "PARENT.DOT") == Array(expected.prefix(101)), "Full SELECT filter preserves exact values")
            config.content = .dataOnly; config.strategy = .upsert; config.operationTimeoutSeconds = 1
            try require(try await run(config) == .completed, "Custom native operation timeout")
            print("PASS \(source.type.rawValue) → \(target.type.rawValue): uppercase targets, full SELECT filters, timeout 0 and 1")
            if envNativeEdges {
                try await nativeEdges(source: source, target: target, read: read, write: write)
            }
            await read.close(); await write.close()
        } catch { await read.close(); await write.close(); throw error }
    }

    private static var envNativeEdges: Bool { ProcessInfo.processInfo.environment["TRANSFER_NATIVE_EDGES"] == "1" }

    static func nativeEdges(source: TransferConnection, target: TransferConnection,
                            read: any WorkspaceSession, write: any WorkspaceSession) async throws {
        func q(_ connection: TransferConnection) -> String { TransferSQL.qualified(connection.endpoint, "native.edge", type: connection.type) }
        let catalog = DataTransferCatalog()
        try await execute("CREATE TABLE \(q(source)) (id bigint PRIMARY KEY, payload \(source.type == .mysql ? "longtext" : "text"), raw \(source.type == .mysql ? "longblob" : "bytea"))", session: read, database: source.endpoint.database)
        let blob = source.type == .mysql ? "UNHEX(REPEAT('00FF805C270A',200000))" : "decode(repeat('00ff805c270a',200000),'hex')"
        let text = source.type == .mysql ? "REPEAT(CONVERT(X'E4B8ADE69687F09F99825C090A' USING utf8mb4),100000)" : "repeat('中文🙂'||chr(92)||chr(9)||chr(10),100000)"
        try await execute("INSERT INTO \(q(source)) VALUES (0,\(text),\(blob)), (1,'',\(source.type == .mysql ? "X''" : "decode('','hex')")), (2,NULL,NULL)", session: read, database: source.endpoint.database, kind: .insert)
        var config = DataTransferConfiguration(); config.source = source.endpoint; config.target = target.endpoint
        guard let object = try await catalog.objects(source).first(where: { $0.kind == .table && $0.name == "native.edge" }) else {
            throw LiveFailure(description: "Missing native edge fixture")
        }
        config.objects = [object]; config.batchSize = 100
        func run(_ config: DataTransferConfiguration, expectsNative: Bool? = nil) async throws -> TransferRunStatus {
            let plan = try await DataTransferPlanner(catalog: catalog).prepare(configuration: config, source: source, target: target, ownership: .skip)
            let recorder = NativeChannelRecorder()
            let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { item in
                await recorder.receive(item)
                if item.status == .failed { print("EDGE ITEM \(item.message)") }
            }, backups: { _ in })
            if let expectsNative { try require(await recorder.native == expectsNative, "Unexpected native/fallback channel: expected \(expectsNative), actual \(await recorder.native), status \(result.0), message \(result.1)") }
            return result.0
        }
        try require(try await run(config) == .completed, "Wide rows across native chunks")
        func checksum(_ connection: TransferConnection, _ session: any WorkspaceSession) async throws -> [[WorkspaceDatabaseDataCell]] {
            let raw = connection.type == .mysql ? "MD5(raw)" : "md5(raw)"
            return try await DataTransferCatalog.query("SELECT id,md5(payload) AS text_hash,\(raw) AS binary_hash FROM \(q(connection)) ORDER BY id", session: session, database: connection.endpoint.database).rows.map(\.values)
        }
        let expected = try await checksum(source, read)
        try require(try await checksum(target, write) == expected, "Wide-row text/binary equality with NULL and empty")
        print("PASS native multi-megabyte rows, chunk boundaries, NULL/empty, binary and zero key")
        try await execute("UPDATE \(q(target)) SET payload='stale',raw=NULL WHERE id=0", session: write, database: target.endpoint.database, kind: .update(hasWhereClause: true))
        try await restrictedUpsert(source: source, target: target, admin: write, config: config)
        try require(try await checksum(target, write) == expected, "Restricted Upsert restores exact source values")
        if source.type == .postgresql && target.type == .postgresql {
            config.content = .dataOnly; config.strategy = .overwrite
            config.tableFilters = ["native.edge": "SELECT id,payload,encode(raw,'hex') AS raw FROM \(q(source))"]
            try require(try await run(config, expectsNative: true) == .failed, "Full SELECT result-type changes must retain binary validation")
            try require(try await checksum(target, write) == expected, "Invalid binary conversion must roll back")
            config.tableFilters = ["native.edge": "id != 1/(id-2)"]
            try require(try await run(config, expectsNative: true) == .failed, "Raw COPY OUT source failure aborts COPY IN")
            try require(try await checksum(target, write) == expected, "Raw COPY source failure restores original rows")
            config.tableFilters = [:]
            try await execute("ALTER TABLE \(q(target)) ENABLE ROW LEVEL SECURITY", session: write, database: target.endpoint.database, kind: .ddl(.alter))
            try require(try await run(config, expectsNative: false) == .completed, "RLS table uses INSERT")
            try require(try await checksum(target, write) == expected, "RLS fallback equality")
            try await execute("ALTER TABLE \(q(target)) DISABLE ROW LEVEL SECURITY", session: write, database: target.endpoint.database, kind: .ddl(.alter))
            let quote = TransferSQL.dialect(.postgresql).identifier
            let audit = TransferSQL.qualified(target.endpoint, "native_audit", type: .postgresql)
            let fn = TransferSQL.qualified(target.endpoint, "native_stmt_trigger", type: .postgresql)
            try await execute("CREATE TABLE \(audit) (n int)", session: write, database: target.endpoint.database)
            try await execute("CREATE FUNCTION \(fn)() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO \(audit) VALUES (1); RETURN NULL; END $$", session: write, database: target.endpoint.database)
            try await execute("CREATE TRIGGER \(quote("native_statement")) AFTER INSERT ON \(q(target)) FOR EACH STATEMENT EXECUTE FUNCTION \(fn)()", session: write, database: target.endpoint.database)
            try require(try await run(config, expectsNative: false) == .completed, "Statement trigger retains INSERT batches")
            let calls = try await DataTransferCatalog.query("SELECT COUNT(*)::text AS n FROM \(audit)", session: write, database: target.endpoint.database)
            try require(calls.rows.first.flatMap { calls.text($0, "n") } == "1", "Statement trigger must fire once for one configured batch")
            try await execute("DROP TRIGGER \(quote("native_statement")) ON \(q(target))", session: write, database: target.endpoint.database, kind: .ddl(.drop))
            try await execute("CREATE RULE \(quote("native_rule")) AS ON INSERT TO \(q(target)) DO ALSO INSERT INTO \(audit) VALUES (2)", session: write, database: target.endpoint.database)
            try require(try await run(config, expectsNative: false) == .completed, "INSERT rule retains INSERT semantics")
            try await execute("DROP RULE \(quote("native_rule")) ON \(q(target))", session: write, database: target.endpoint.database, kind: .ddl(.drop))
            try require(try await checksum(target, write) == expected, "Rule fallback equality")
            config.tableFilters = ["native.edge": "SELECT id, (1/(id-2))::text AS payload, raw FROM \(q(source))"]
            try require(try await run(config, expectsNative: true) == .failed, "Mid-stream source failure aborts COPY")
            try require(try await checksum(target, write) == expected, "Source failure restores overwritten target")
            print("PASS PostgreSQL RLS/rules/statement-trigger fallback, and COPY source-failure rollback")
        }
        if source.type == .mysql && target.type == .mysql {
            // Reuse the reviewed target SQL mode in a new run, including its NO_BACKSLASH_ESCAPES variant.
            try await execute("SET GLOBAL sql_mode = CONCAT(@@GLOBAL.sql_mode,',NO_BACKSLASH_ESCAPES')", session: write, database: target.endpoint.database, kind: .control)
            config.content = .dataOnly; config.strategy = .overwrite
            try require(try await run(config) == .completed, "LOCAL delimiters under NO_BACKSLASH_ESCAPES")
            try require(try await checksum(target, write) == expected, "NO_BACKSLASH_ESCAPES exact values")
            // LOAD LOCAL converts some strict-mode errors into warnings. Such a
            // warning must fail the whole transfer and restore the original row.
            try await execute("DELETE FROM \(q(target))", session: write, database: target.endpoint.database, kind: .delete(hasWhereClause: false))
            try await execute("ALTER TABLE \(q(target)) MODIFY payload varchar(2)", session: write, database: target.endpoint.database, kind: .ddl(.alter))
            try await execute("INSERT INTO \(q(target)) VALUES (99,'OK',X'00FF')", session: write, database: target.endpoint.database, kind: .insert)
            try require(try await run(config) == .failed, "Truncation warning must abort native commit")
            let result = try await DataTransferCatalog.query("SELECT id,payload,HEX(raw) AS raw FROM \(q(target))", session: write, database: target.endpoint.database)
            try require(result.rows.first?.values == [.text("99"),.text("OK"),.text("00FF")] && result.rows.count == 1, "Warning rollback restores original row")
            if let native = write as? any WorkspaceNativeBulkTransferSession {
                let stream = WorkspaceNativeBulkStream()
                do {
                    _ = try await native.executeNativeBulkTransfer(sql: "LOAD DATA LOCAL INFILE '/etc/hosts' INTO TABLE \(q(target))", token: "querycraft-memory-denied", stream: stream)
                    throw LiveFailure(description: "Unexpected LOCAL resource was accepted")
                } catch is LiveFailure { throw LiveFailure(description: "Unexpected LOCAL resource was accepted") }
                catch { stream.fail(error) }
            }
            print("PASS MySQL backslash modes, warning rollback and unexpected LOCAL resource denial")
        }
        let control = try await catalog.open(target)
        do {
            let id = try await write.connectionID()
            let sleeper = Task {
                try await write.executeStatement(target.type == .postgresql ? "SELECT pg_sleep(20)" : "SELECT SLEEP(20)", kind: .read,
                                                 database: target.endpoint.database) { _ in }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var entered = false
            while ContinuousClock.now < deadline {
                let sql = target.type == .postgresql
                    ? "SELECT COUNT(*)::text AS n FROM pg_stat_activity WHERE pid=\(id) AND state='active' AND query LIKE '%pg_sleep%'"
                    : "SELECT COUNT(*) AS n FROM information_schema.PROCESSLIST WHERE ID=\(id) AND INFO LIKE '%SLEEP%'"
                let state = try await DataTransferCatalog.query(sql, session: control, database: target.endpoint.database)
                if state.rows.first.flatMap({ state.text($0, "n") }) == "1" { entered = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let start = ContinuousClock.now; sleeper.cancel()
            do { _ = try await sleeper.value; throw LiveFailure(description: "Sleeping query did not cancel") }
            catch is CancellationError { }
            try require(entered && start.duration(to: .now) < .seconds(3), "Cancellation interrupts active database waits")
            let usable = try await DataTransferCatalog.query("SELECT 1 AS n", session: write, database: target.endpoint.database)
            try require(usable.rows.first.flatMap { usable.text($0, "n") } == "1", "Connection is usable after cancellation")
            await control.close()
            print("PASS \(target.type.rawValue) active server-query cancellation and reusable connection")
        } catch { await control.close(); throw error }
    }

    static func restrictedUpsert(source: TransferConnection, target: TransferConnection, admin: any WorkspaceSession,
                                  config original: DataTransferConfiguration) async throws {
        let user = "qc_bulk_" + UUID().uuidString.prefix(8).lowercased(), password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let quote = TransferSQL.dialect(target.type).identifier
        let account = target.type == .mysql ? "'\(user)'@'%'" : quote(user)
        let setup = target.type == .mysql
            ? "CREATE USER \(account) IDENTIFIED BY '\(password)'"
            : "CREATE ROLE \(account) LOGIN PASSWORD '\(password)'"
        try await execute(setup, session: admin, database: target.endpoint.database)
        do {
            if target.type == .mysql {
                try await execute("GRANT SELECT,INSERT,UPDATE,DELETE ON \(quote(target.endpoint.database)).* TO \(account)", session: admin, database: target.endpoint.database, kind: .control)
            } else {
                try await execute("REVOKE TEMP ON DATABASE \(quote(target.endpoint.database)) FROM PUBLIC", session: admin, database: target.endpoint.database, kind: .control)
                try await execute("GRANT USAGE ON SCHEMA \(quote(target.endpoint.schema)) TO \(account)", session: admin, database: target.endpoint.database, kind: .control)
                try await execute("GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA \(quote(target.endpoint.schema)) TO \(account)", session: admin, database: target.endpoint.database, kind: .control)
            }
            let endpoint = TransferEndpoint(profileID: UUID(), database: target.endpoint.database, schema: target.endpoint.schema)
            let restricted = TransferConnection(endpoint: endpoint, configuration: .init(databaseType: target.type, host: target.configuration.host, port: target.configuration.port,
                                                                                        username: user, password: password, database: target.endpoint.database, tlsMode: .disabled))
            var config = original; config.target = endpoint; config.content = .dataOnly; config.strategy = .upsert; config.tableFilters = [:]
            let plan = try await DataTransferPlanner().prepare(configuration: config, source: source, target: restricted, ownership: .skip)
            let recorder = NativeChannelRecorder()
            let result = await DataTransferRunner().run(plan, authorize: {}, progress: { await recorder.receive($0) }, backups: { _ in })
            let native = await recorder.native
            try require(result.0 == .completed && !native, "DML-only target must Upsert without temporary-table privileges: \(result.1)")
            // The owning test compares values before/after this operation as well.
            print("PASS \(target.type.rawValue) DML-only Upsert fallback and savepoint recovery")
        } catch {
            if target.type == .postgresql {
                try? await execute("GRANT TEMP ON DATABASE \(quote(target.endpoint.database)) TO PUBLIC", session: admin, database: target.endpoint.database, kind: .control)
                try? await execute("DROP OWNED BY \(account)", session: admin, database: target.endpoint.database, kind: .control)
            }
            try? await execute(target.type == .mysql ? "DROP USER \(account)" : "DROP ROLE \(account)", session: admin, database: target.endpoint.database)
            throw error
        }
        if target.type == .postgresql {
            try await execute("GRANT TEMP ON DATABASE \(quote(target.endpoint.database)) TO PUBLIC", session: admin, database: target.endpoint.database, kind: .control)
            try await execute("DROP OWNED BY \(account)", session: admin, database: target.endpoint.database, kind: .control)
        }
        try await execute(target.type == .mysql ? "DROP USER \(account)" : "DROP ROLE \(account)", session: admin, database: target.endpoint.database)
    }
}
