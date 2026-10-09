import Foundation
import QueryCraftFeature
import QueryCraftMariaDBTransport
@testable import QueryCraftPostgreSQLDriver

@main
struct NativeSQLMetadataCheck {
    static func main() async throws {
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
    }
}
