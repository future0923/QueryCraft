import Testing
@testable import QueryCraftPostgreSQLDriver

struct PostgreSQLQueryColumnMetadataTests {
    @Test
    func emptyResultsPreserveAliasesSchemaOriginsAndExpressionTypes() {
        let result = PostgreSQLCQueryResult(
            columns: ["display_name", "display_name", "user_nick"],
            columnTypes: ["character varying(20)", "text", "bigint"],
            columnOrigins: [
                .init(schemaName: "hr", tableName: "users", columnName: "user_nick"),
                .init(schemaName: "archive", tableName: "users", columnName: "label"),
                nil,
            ]
        )
        let columns = result.workspaceColumns
        #expect(columns.map(\.id) == [0, 1, 2])
        #expect(columns.map(\.name) == ["display_name", "display_name", "user_nick"])
        #expect(columns[0].origin?.schemaName == "hr")
        #expect(columns[0].origin?.columnName == "user_nick")
        #expect(columns[1].origin?.schemaName == "archive")
        #expect(columns[1].origin?.columnName == "label")
        #expect(columns[0].type == "character varying(20)")
        #expect(columns[2].type == "bigint")
        #expect(columns[2].origin == nil)
    }

    @Test
    func missingMetadataDoesNotBorrowFromAnotherColumn() {
        let columns = PostgreSQLCQueryResult(
            columns: ["known", "unknown"], columnTypes: ["integer"],
            columnOrigins: [.init(schemaName: "public", tableName: "users", columnName: "id")]
        ).workspaceColumns
        #expect(columns.count == 2)
        #expect(columns[1].type == nil)
        #expect(columns[1].origin == nil)
    }
}
