import CMariaDB
import QueryCraftMariaDBTransport
import Testing

struct MySQLQueryColumnMetadataTests {
    @Test
    func emptyResultsKeepAliasOriginsFromDifferentDatabasesAndExpressionTypes() {
        let result = CDatabaseQueryResult(
            columns: ["display_name", "display_name", "user_nick"],
            columnTypes: ["varchar", "varchar", "bigint unsigned"],
            columnOrigins: [
                .init(databaseName: "hr", tableName: "users", columnName: "user_nick"),
                .init(databaseName: "archive", tableName: "users", columnName: "label"),
                nil,
            ]
        )
        let columns = result.workspaceColumns
        #expect(columns.map(\.id) == [0, 1, 2])
        #expect(columns[0].name == "display_name")
        #expect(columns[0].origin?.databaseName == "hr")
        #expect(columns[0].origin?.columnName == "user_nick")
        #expect(columns[1].origin?.databaseName == "archive")
        #expect(columns[1].origin?.columnName == "label")
        #expect(columns[2].type == "bigint unsigned")
        #expect(columns[2].origin == nil)
    }

    @Test
    func protocolTypesDistinguishUnsignedNumbersAndBinaryStrings() {
        var field = MYSQL_FIELD()
        field.type = MYSQL_TYPE_LONGLONG
        field.flags = UInt32(UNSIGNED_FLAG)
        #expect(MariaDBColumnType.name(for: field) == "bigint unsigned")
        field.flags = 0
        #expect(MariaDBColumnType.name(for: field) == "bigint")
        field.type = MYSQL_TYPE_VAR_STRING
        field.charsetnr = 45
        #expect(MariaDBColumnType.name(for: field) == "varchar")
        field.charsetnr = 63
        #expect(MariaDBColumnType.name(for: field) == "varbinary")
        field.type = MYSQL_TYPE_BLOB
        #expect(MariaDBColumnType.name(for: field) == "blob")
        field.charsetnr = 45
        #expect(MariaDBColumnType.name(for: field) == "text")
        field.type = MYSQL_TYPE_NEWDECIMAL
        #expect(MariaDBColumnType.name(for: field) == "decimal")
        field.type = MYSQL_TYPE_DATETIME
        #expect(MariaDBColumnType.name(for: field) == "datetime")
        field.type = MAX_NO_FIELD_TYPES
        #expect(MariaDBColumnType.name(for: field) == nil)
    }

    @Test
    func incompleteMetadataKeepsUnknownFieldsUnresolved() {
        let columns = CDatabaseQueryResult(
            columns: ["known", "unknown"], columnTypes: ["int"]
        ).workspaceColumns
        #expect(columns.count == 2)
        #expect(columns[1].type == nil)
        #expect(columns[1].origin == nil)
    }
}
