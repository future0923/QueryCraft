import QueryCraftMariaDBTransport
import Testing
@testable import QueryCraftDorisDriver

struct DorisQueryColumnMetadataTests {
    @Test
    func emptyResultsCarrySourceMetadataThroughTheDorisSession() {
        let columns = DorisWorkspaceSession.dataColumns(from: .init(
            columns: ["display_name", "total"], columnTypes: ["varchar", "bigint"],
            columnOrigins: [.init(databaseName: "analytics", tableName: "users", columnName: "user_nick"), nil]
        ))
        #expect(columns.count == 2)
        #expect(columns[0].name == "display_name")
        #expect(columns[0].origin?.databaseName == "analytics")
        #expect(columns[0].origin?.tableName == "users")
        #expect(columns[0].origin?.columnName == "user_nick")
        #expect(columns[0].type == "varchar")
        #expect(columns[1].type == "bigint")
        #expect(columns[1].origin == nil)
    }

    @Test
    func serversWithoutLineageStillKeepResultTypes() {
        let columns = DorisWorkspaceSession.dataColumns(from: .init(
            columns: ["user_nick"], columnTypes: ["varchar"]
        ))
        #expect(columns[0].type == "varchar")
        #expect(columns[0].origin == nil)
    }
}
