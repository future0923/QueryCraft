import Foundation
import QueryCraftFeature
#if DORIS_OVERVIEW_FIXTURE
@testable import QueryCraftDorisDriver
#else
import QueryCraftMariaDBTransport
@testable import QueryCraftPostgreSQLDriver
#endif

@main
struct NativeSQLMetadataCheck {
    static func main() async throws {
#if DORIS_OVERVIEW_FIXTURE
        let doris = try DorisWorkspaceSession(configuration: .init(.init(databaseType: .doris,
            host: "127.0.0.1", port: Int(CommandLine.arguments[1])!, username: "fixture",
            password: nil, database: nil, tlsMode: .disabled)))
        try await doris.connect()
        let objects = try await doris.fetchSQLObjectOverview(in: "supported")
        precondition(objects.count == 2 && objects[0].comment == "员工资料")
        precondition(objects[0].engine == "OLAP" && objects[0].collation == "utf8mb4_bin")
        precondition(objects[0].estimatedRowCount == 123456789 && objects[0].storageByteCount == 4294967296)
        precondition(objects[1].object.kind == .view && objects[1].comment == "昵称视图")
        precondition(objects[1].estimatedRowCount == nil && objects[1].storageByteCount == nil)
        precondition(objects[1].engine == nil && objects[1].collation == nil)
        let partial = try await doris.fetchSQLObjectOverview(in: "partial")
        precondition(partial[0].comment == "员工资料" && partial[0].engine == "OLAP")
        precondition(partial[0].estimatedRowCount == nil && partial[0].storageByteCount == nil)
        let noProperties = try await doris.fetchSQLObjectOverview(in: "no_properties")
        precondition(noProperties[0].comment == "员工资料" && noProperties[0].estimatedRowCount == 123456789)
        precondition(noProperties[0].engine == nil && noProperties[0].collation == nil)
        let fallback = try await doris.fetchSQLObjectOverview(in: "legacy")
        precondition(fallback.count == 2 && fallback[1].object.kind == .view)
        precondition(fallback.allSatisfy { $0.comment.isEmpty && $0.engine == nil && $0.collation == nil && $0.estimatedRowCount == nil && $0.storageByteCount == nil })
        await doris.close()
        print("Doris native protocol: bulk overview, comments, 64-bit statistics, views and legacy metadata fallback verified.")

#else
        let pg = LibPQClient(configuration: .init(host: "127.0.0.1", port: Int(CommandLine.arguments[1])!, username: "fixture", password: nil, database: "fixture", tlsMode: .disabled))
        try await pg.connect()
        for sql in ["SELECT_FIXTURE", "EMPTY_FIXTURE"] {
            let result = try await pg.query(sql)
            let columns = result.workspaceColumns
            precondition(columns.count == 3)
            precondition(columns[0].name == "display_name")
            precondition(columns[0].origin?.schemaName == "hr")
            precondition(columns[0].origin?.columnName == "user_nick")
            precondition(columns[1].origin?.schemaName == "archive")
            precondition(columns[2].origin == nil)
            precondition(columns[0].type == "character varying(20)")
            precondition(columns[2].type == "bigint")
            precondition(result.rows.count == (sql == "EMPTY_FIXTURE" ? 0 : 1))
        }
        let unavailable = try await pg.query("FAIL_METADATA")
        precondition(unavailable.rows.count == 1)
        precondition(unavailable.workspaceColumns.allSatisfy { $0.origin == nil && $0.type == nil })
        _ = try await pg.query("SELECT_FIXTURE")
        await pg.close()
        print("PostgreSQL native protocol: aliases, cross-schema fields, expression types, empty results, metadata failure verified.")

        let mysql = MariaDBClient(configuration: .init(host: "127.0.0.1", port: Int(CommandLine.arguments[2])!, username: "fixture", password: nil, database: nil, tlsMode: .disabled))
        try await mysql.connect()
        for sql in ["SELECT_FIXTURE", "EMPTY_FIXTURE"] {
            let result = try await mysql.query(sql)
            let columns = result.workspaceColumns
            precondition(columns.count == 3)
            precondition(columns[0].name == "display_name")
            precondition(columns[0].origin?.databaseName == "hr")
            precondition(columns[0].origin?.columnName == "user_nick")
            precondition(columns[1].origin?.databaseName == "archive")
            precondition(columns[2].origin == nil)
            precondition(columns[0].type == "varchar")
            precondition(columns[2].type == "bigint unsigned")
            precondition(result.rows.count == (sql == "EMPTY_FIXTURE" ? 0 : 1))
        }
        await mysql.close()
        print("MySQL/Doris native transport: aliases, cross-database fields, unsigned expression types and empty results verified.")
#endif
    }
}
