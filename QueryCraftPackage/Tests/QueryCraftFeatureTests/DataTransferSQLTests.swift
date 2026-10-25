import Foundation
import Testing
#if os(iOS)
import QueryCraftMobileCore
@testable import QueryCraftMobileProof
#else
@testable import QueryCraftFeature
#endif

struct DataTransferSQLTests {
    private func column(_ name: String = "value", type: String = "text", key: String = "", extra: String = "", nullable: Bool = true) -> WorkspaceDatabaseColumn {
        .init(name: name, type: type, collation: nil, isNullable: nullable, key: key, defaultValue: nil, extra: extra, comment: "")
    }

    @Test("Six drivers expose truthful source/target capabilities")
    func capabilities() {
        for type in [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka] {
            #expect(TransferCapabilities.canRead(type) == [.mysql, .postgresql, .doris].contains(type))
            #expect(TransferCapabilities.canWrite(type) == [.mysql, .postgresql].contains(type))
        }
        #expect(TransferCapabilities.supports(.table, source: .doris, target: .mysql))
        #expect(!TransferCapabilities.supports(.function, source: .mysql, target: .postgresql))
        #expect(!TransferCapabilities.supports(.sequence, source: .mysql, target: .mysql))
    }

    @Test("Switching transfer modes and driver pairs uses one selection policy")
    func changingCapabilitiesPrunesOnlyUnsupportedObjects() {
        let table = TransferObject(kind: .table, name: "table"), view = TransferObject(kind: .view, name: "view")
        var configuration = DataTransferConfiguration()
        configuration.objects = [table, view]; configuration.content = .structureOnly; configuration.strategy = .overwrite
        configuration.pruneSelection(sourceType: .mysql, targetType: .mysql)
        #expect(configuration.objects == [table, view]); #expect(configuration.strategy == .overwrite)
        configuration.pruneSelection(sourceType: .mysql, targetType: .postgresql)
        #expect(configuration.objects == [table]); #expect(configuration.strategy == .append)
        configuration.content = .dataOnly; configuration.strategy = .rebuild
        configuration.pruneSelection(sourceType: .postgresql, targetType: .mysql)
        #expect(configuration.strategy == .append)
        configuration.source = .init(profileID: UUID(), database: "source")
        configuration.target = .init(profileID: UUID(), database: "target")
        configuration.tableFilters = ["table": "id=1"]
        configuration.swapEndpoints()
        #expect(configuration.source.database == "target"); #expect(configuration.target.database == "source")
        #expect(configuration.objects.isEmpty); #expect(configuration.tableFilters.isEmpty)
    }

    @Test("Filters cannot smuggle writes or extra statements", arguments: ["id=1; DROP TABLE t", "SELECT * INTO OUTFILE '/tmp/a' FROM t", "SELECT * FROM t FOR UPDATE", "CALL f()", "id=1 /* open", "'unterminated", "WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x", "SELECT * FROM t /*!50000 INTO OUTFILE '/tmp/a' */", "id=1 /*M! AND x=1 */"])
    func rejectedFilter(_ value: String) {
        #expect(throws: (any Error).self) { try TransferSQL.validateFilter(value) }
    }

    @Test("SQL-looking literal content and quoted column names remain data", arguments: ["label='DROP TABLE; DELETE FROM x'", "`update`=1", "\"into\" IS NULL", "SELECT * FROM t WHERE id<=90000", "id IN (SELECT id FROM other)"])
    func acceptedFilter(_ value: String) throws { try TransferSQL.validateFilter(value) }

    @Test("Qualified rewriting preserves quoted strings, comments and escaped identifiers")
    func rewrite() throws {
        let sql = "CREATE VIEW `old`.`v` AS SELECT 'old.t', `old`.`ta``ble`.id FROM `old`.`ta``ble` -- old.t\n"
        let result = try TransferSQL.rewriteQualified(sql, sourceNamespace: "old", targetNamespace: "new", tableNames: ["ta`ble": "copy"], type: .mysql)
        #expect(result.contains("CREATE VIEW `new`.`v`"))
        #expect(result.contains("FROM `new`.`copy`"))
        #expect(result.contains("'old.t'"))
        #expect(result.contains("-- old.t"))
        #expect(try TransferSQL.retargetCreate("CREATE TABLE `a.b` (`x` int)", keyword: "TABLE", target: "`d`.`copy`") == "CREATE TABLE `d`.`copy` (`x` int)")
        #expect(try TransferSQL.retargetCreate("CREATE DEFINER=`VIEW`@`localhost` VIEW `v` AS SELECT 1", keyword: "VIEW", target: "`db`.`v`").contains("DEFINER=`VIEW`@`localhost` VIEW `db`.`v`"))
        let functions = try TransferSQL.rewriteQualified("SELECT old.users(), old.users.id FROM old.users", sourceNamespace: "old", targetNamespace: "new", tableNames: ["users": "USERS"], type: .postgresql)
        #expect(functions.contains("\"new\".users()"))
        #expect(functions.contains("\"new\".\"USERS\".id"))
    }

    @Test("Binary transfer retains all bytes and rejects preview-only data")
    func binary() throws {
        let blob = column(type: "blob"), bytea = column(type: "bytea")
        #expect(try TransferSQL.literal(.text("00FF8027"), source: blob, sourceType: .mysql, target: bytea, targetType: .postgresql) == "decode('00FF8027','hex')")
        #expect(try TransferSQL.literal(.text("\\x00ff8027"), source: bytea, sourceType: .postgresql, target: blob, targetType: .mysql) == "X'00ff8027'")
        #expect(throws: (any Error).self) { try TransferSQL.literal(.binary(byteCount: 100, preview: [0, 1]), source: blob, sourceType: .mysql, target: bytea, targetType: .postgresql) }
        #expect(throws: (any Error).self) { try TransferSQL.literal(.text("ZZ"), source: blob, sourceType: .mysql, target: bytea, targetType: .postgresql) }
        let select = try TransferSQL.select(object: .init(kind: .table, name: "a.b"), columns: [blob], endpoint: .init(database: "db"), type: .mysql, filter: "", order: [], offset: 0, limit: 100)
        #expect(select.contains("HEX(`value`) AS `value`"))
        #expect(select.contains("`db`.`a.b`"))
        let doris = try TransferSQL.select(object: .init(kind: .table, name: "a.b"), columns: [column(type: "string")], endpoint: .init(database: "db"), type: .doris, filter: "", order: [], offset: 0, limit: 100)
        #expect(doris.contains("HEX(CAST(`value` AS STRING))"))
    }

    @Test("Numeric primary-key paging retains exact large IDs and safe fallback modes", arguments: [DatabaseType.mysql, .postgresql])
    func keysetPaging(type: DatabaseType) throws {
        let key = WorkspaceDatabaseColumn(name: "id", type: "bigint", collation: nil, isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: "")
        let columns = [key, column("payload")]
        let endpoint = TransferEndpoint(database: "db", schema: type == .postgresql ? "public" : "")
        let filter = "WHERE id<=9007199255740993"
        #expect(try TransferSQL.paginationKey(columns: columns, type: type, filter: filter) == key)
        let sql = try TransferSQL.select(object: .init(kind: .table, name: "rows"), columns: columns, endpoint: endpoint,
                                         type: type, filter: filter, order: ["id"], offset: 1000, limit: 1000,
                                         paginationKey: key, after: "9007199254740993")
        #expect(sql.contains("(id<=9007199255740993) AND " + TransferSQL.dialect(type).identifier("id") + " > 9007199254740993"))
        #expect(!sql.contains("OFFSET"))
        #expect(!sql.contains("'9007199254740993'"))
        #expect(throws: (any Error).self) {
            try TransferSQL.select(object: .init(kind: .table, name: "rows"), columns: columns, endpoint: endpoint,
                                   type: type, filter: "", order: ["id"], offset: 0, limit: 1000,
                                   paginationKey: key, after: "1; DROP TABLE rows")
        }
        let fullQuery = "SELECT * FROM rows"
        #expect(try TransferSQL.paginationKey(columns: columns, type: type, filter: fullQuery) == nil)
        #expect(try TransferSQL.paginationKey(columns: columns, type: .doris, filter: "") == nil)
        let secondKey = WorkspaceDatabaseColumn(name: "part", type: "int", collation: nil, isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: "")
        #expect(try TransferSQL.paginationKey(columns: [key, secondKey], type: type, filter: "") == nil)
        for unsupported in [column("id", type: "double", key: "PRI", nullable: false), column("id", type: "varchar(20)", key: "PRI", nullable: false), column("id", type: "bigint", key: "PRI", extra: "STORED GENERATED", nullable: false), column("id", type: "bigint", nullable: false), column("id", type: "bigint", key: "PRI")] {
            #expect(try TransferSQL.paginationKey(columns: [unsupported], type: type, filter: "") == nil)
        }
        let fallback = try TransferSQL.select(object: .init(kind: .table, name: "rows"), columns: columns, endpoint: endpoint,
                                              type: type, filter: fullQuery, order: ["id"], offset: 1000, limit: 1000)
        #expect(fallback.contains("OFFSET 1000"))
        let streaming = try TransferSQL.select(object: .init(kind: .table, name: "rows"), columns: columns, endpoint: endpoint,
                                               type: type, filter: "id>0", order: ["id"], offset: 0, limit: nil)
        #expect(!streaming.contains("LIMIT") && !streaming.contains("OFFSET") && !streaming.contains("ORDER BY"))
        let orderedStream = try TransferSQL.select(object: .init(kind: .table, name: "rows"), columns: columns, endpoint: endpoint,
                                                   type: type, filter: "id>0", order: ["id"], offset: 0, limit: nil, preserveOrder: true)
        #expect(orderedStream.contains("ORDER BY") && !orderedStream.contains("LIMIT") && !orderedStream.contains("OFFSET"))
    }

    @Test("Precision, NULL, empty strings and SQL-looking text survive bulk INSERT")
    func values() throws {
        let columns = [column("id", type: "bigint", key: "PRI"), column("value"), column("amount", type: "numeric(30,9)")]
        let rows = [WorkspaceDatabaseDataRow(id: 0, values: [.text("9007199254740993"), .null, .text("123456789012345678901.123456789")]), .init(id: 1, values: [.text("2"), .text(""), .text("0")]), .init(id: 2, values: [.text("3"), .text("O'Reilly; DROP TABLE t"), .text("-1")])]
        let sql = try TransferSQL.insert(rows: rows, columns: columns, targetColumns: columns, sourceType: .postgresql, targetType: .postgresql, endpoint: .init(database: "db", schema: "schema.with.dot"), name: "table.with.dot", strategy: .upsert, keys: ["id"])
        #expect(sql.contains("9007199254740993")); #expect(sql.contains("123456789012345678901.123456789"))
        #expect(sql.contains("NULL")); #expect(sql.contains("E''")); #expect(sql.contains("O''Reilly; DROP TABLE t"))
        #expect(sql.contains("ON CONFLICT (\"id\") DO UPDATE"))
        #expect(sql.contains("\"schema.with.dot\".\"table.with.dot\""))
    }

    @Test("Prepared INSERT encoding retains column order, identity, binary and boolean semantics")
    func preparedInsert() throws {
        let source = [column("id", type: "bigint", key: "PRI"), column("raw", type: "blob"), column("flag", type: "tinyint(1)")]
        let target = [column("flag", type: "boolean"), column("raw", type: "bytea"), column("id", type: "bigint", key: "PRI", extra: "IDENTITY ALWAYS")]
        let encoder = try TransferSQL.InsertEncoder(columns: source, targetColumns: target, sourceType: .mysql, targetType: .postgresql,
                                                    endpoint: .init(database: "db", schema: "public"), name: "copy", strategy: .upsert, keys: ["id"])
        let rows: [WorkspaceDatabaseDataRow] = [.init(id: 0, values: [.text("9007199254740993"), .text("00ff8027"), .text("0")]),
                                               .init(id: 1, values: [.text("9007199254740994"), .null, .text("1")])]
        let sql = try encoder.statement(rows: rows)
        #expect(sql.hasPrefix("INSERT INTO \"public\".\"copy\" (\"id\", \"raw\", \"flag\") OVERRIDING SYSTEM VALUE VALUES "))
        #expect(sql.contains("(E'9007199254740993', decode('00ff8027','hex'), FALSE),\n(E'9007199254740994', NULL, TRUE)"))
        #expect(sql.contains("ON CONFLICT (\"id\") DO UPDATE SET \"raw\" = EXCLUDED.\"raw\", \"flag\" = EXCLUDED.\"flag\""))
        let sliced = try encoder.statement(rows: rows.dropFirst())
        #expect(!sliced.contains("9007199254740993"))
        #expect(sliced.contains("9007199254740994"))
        #expect(throws: (any Error).self) { try encoder.statement(rows: [WorkspaceDatabaseDataRow(id: 0, values: [.text("1")])]) }
        let boolean = TransferSQL.CellEncoder(source: column(type: "boolean"), sourceType: .postgresql,
                                              target: column(type: "tinyint(1)"), targetType: .mysql)
        #expect(try boolean.encode(.text("t")) == "'1'")
        #expect(try boolean.encode(.text("false")) == "'0'")
        #expect(try boolean.encode(.null) == "NULL")
        #expect(throws: (any Error).self) {
            try TransferSQL.literal(.text("ＦＦ"), source: column(type: "blob"), sourceType: .mysql, target: column(type: "blob"), targetType: .mysql)
        }
    }

    @Test("Foreign-key extraction ignores commas, quoted text and nested expressions")
    func foreignKeys() throws {
        let ddl = "CREATE TABLE `t` (`id` int, `note` varchar(30) COMMENT 'FOREIGN REFERENCES, test', CHECK (`id` IN (1,2)), CONSTRAINT `fk` FOREIGN KEY (`id`) REFERENCES `parent` (`id`)) ENGINE=InnoDB"
        let split = try DataTransferPlanner.splitMySQLForeignKeys(ddl)
        #expect(split.keys.count == 1)
        #expect(split.ddl.contains("COMMENT 'FOREIGN REFERENCES, test'"))
        #expect(split.ddl.contains("CHECK (`id` IN (1,2))"))
        #expect(!split.ddl.contains("CONSTRAINT `fk`"))
        #expect(try DataTransferPlanner.referencedTable(split.keys[0]) == "parent")
    }

    @Test("Cross-engine conversion refuses types it cannot preserve")
    func conversion() throws {
        #expect(try DataTransferPlanner.convertedType("bigint unsigned", target: .postgresql) == "numeric(20,0)")
        #expect(try DataTransferPlanner.convertedType("decimal(30,9)", target: .postgresql) == "decimal(30,9)")
        #expect(try DataTransferPlanner.convertedType("string", target: .mysql) == "longtext")
        #expect(try DataTransferPlanner.convertedType("text", target: .mysql) == "longtext")
        #expect(try DataTransferPlanner.convertedType("character varying", target: .mysql) == "longtext")
        #expect(try DataTransferPlanner.convertedType("int", target: .mysql) == "int")
        #expect(try DataTransferPlanner.convertedType("decimalv3(30, 9)", target: .mysql) == "decimal(30, 9)")
        #expect(try DataTransferPlanner.convertedType("decimalv3(30, 9)", target: .postgresql) == "decimal(30, 9)")
        #expect(try DataTransferPlanner.convertedType("datetimev2(6)", target: .mysql) == "datetime(6)")
        #expect(try DataTransferPlanner.convertedType("datev2", target: .postgresql) == "date")
        #expect(throws: (any Error).self) { try DataTransferPlanner.convertedType("timestamp with time zone", target: .mysql) }
        #expect(throws: (any Error).self) { try DataTransferPlanner.convertedType("HLL", target: .postgresql) }
    }

    @Test("All options and exact identifiers round-trip without credentials")
    func persistence() throws {
        var config = DataTransferConfiguration()
        config.source = .init(profileID: UUID(), database: "db.with.dot", schema: "schema.点")
        config.target = .init(profileID: UUID(), database: "target", schema: "public")
        config.objects = [.init(kind: .table, name: "table.with.dot")]
        config.strategy = .rebuild; config.content = .structureAndData; config.nameCase = .upper; config.batchSize = 2000
        config.operationTimeoutSeconds = 0; config.tableFilters = ["table.with.dot": "id<100"]
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(DataTransferConfiguration.self, from: data) == config)
        #expect(!String(decoding: data, as: UTF8.self).contains("password"))
        try config.validate(sourceType: .postgresql, targetType: .postgresql)
        config.target = config.source
        #expect(throws: (any Error).self) { try config.validate(sourceType: .postgresql, targetType: .postgresql) }
    }

    @Test("SQL review mappings identify both databases and PostgreSQL schemas", arguments: [DatabaseType.mysql, .postgresql, .doris])
    func reviewMapping(type: DatabaseType) {
        var configuration = DataTransferConfiguration()
        configuration.content = .dataOnly
        configuration.source = .init(profileID: UUID(), database: "src.db", schema: "sales")
        configuration.target = .init(profileID: UUID(), database: "dst.db", schema: "archive")
        let source = TransferConnection(endpoint: configuration.source, configuration: .init(databaseType: type, host: "localhost", port: 3306, username: "test", password: nil, database: "src.db", tlsMode: .disabled))
        let target = TransferConnection(endpoint: configuration.target, configuration: source.configuration.selecting(database: "dst.db"))
        let item = TransferPlanItem(object: .init(kind: .table, name: "orders.with.dot"), targetName: "ORDERS.with.dot", existed: true, sourceColumns: [], targetColumns: [], statements: [], primaryKey: [], backupName: nil)
        let second = TransferPlanItem(object: .init(kind: .table, name: "customers"), targetName: "CUSTOMERS", existed: true, sourceColumns: [], targetColumns: [], statements: [], primaryKey: [], backupName: nil)
        let plan = DataTransferPlan(id: UUID(), configuration: configuration, source: source, target: target, items: [item, second], warnings: [])
        let expected = type == .postgresql
            ? "\"src.db\".\"sales\".\"orders.with.dot\" → \"dst.db\".\"archive\".\"ORDERS.with.dot\""
            : "`src.db`.`orders.with.dot` → `dst.db`.`ORDERS.with.dot`"
        #expect(plan.sql.contains(expected))
        let summaries = plan.sql.split(separator: "\n").filter { $0.contains("1000") }
        #expect(summaries.count == 1)
        #expect(summaries.first?.contains("2") == true)
        let escaped = TransferSQL.previewQualified(configuration.source, "line\r\nbreak", type: type)
        #expect(!escaped.contains("\r") && !escaped.contains("\n"))
        #expect(escaped.contains("line\\r\\nbreak"))
    }
}
