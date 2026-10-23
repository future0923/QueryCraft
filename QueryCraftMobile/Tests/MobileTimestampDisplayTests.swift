import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileTimestampDisplayTests {
    private let formatter = WorkspaceTimestampDisplayFormatter(timeZone: TimeZone(secondsFromGMT: 0))

    @Test func automaticHintsUseRealTypeAndOriginWithoutChangingRawSearch() async throws {
        let result = CDatabaseQueryResult(columns: ["alias", "id", "created_at", "eventTime"],
            columnTypes: ["bigint", "bigint", "varchar", "bigint"],
            columnOrigins: [.init(databaseName: "db", tableName: "t", columnName: "created_at"), nil, nil, nil],
            rows: [["1700000000", "1700000000", "1700000000", "1700000000000"]])
        let data = MobileGridData(preview: .init(result: result))
        #expect(data.metadata == result.workspaceColumns)
        #expect(formatter.timestamp("1700000000", column: data.metadata[0]) == "2023-11-14 22:13:20")
        #expect(formatter.timestamp("1700000000", column: data.metadata[1]) == nil)
        #expect(formatter.timestamp("1700000000", column: data.metadata[2]) == nil)
        #expect(formatter.timestamp("1700000000000", column: data.metadata[3]) == "2023-11-14 22:13:20")
        let search = try await WorkspaceGridSearchWorker().search(source: MobileGridSearchSource(revision: UUID(), data: data),
            request: .init(query: "1700000000", dataColumnIndex: 0, searchOperator: .equals, isCaseSensitive: false))
        #expect(search.matches == [.init(rowIndex: 0, dataColumnIndex: 0)])
        #expect(data.cell(row: 0, column: 0) == .text("1700000000"))
    }

    @Test func explicitFormatsRespectBoundsAndPreserveLargeIDs() {
        let column = WorkspaceDatabaseDataColumn(id: 0, name: "created_at", type: "bigint")
        #expect(formatter.timestamp("0", column: column) == nil)
        #expect(formatter.timestamp("0", column: column, mode: .seconds) == "1970-01-01 00:00:00")
        #expect(formatter.timestamp("-1", column: column, mode: .milliseconds) == "1969-12-31 23:59:59")
        #expect(formatter.timestamp("1700000000000", column: column, mode: .milliseconds) == "2023-11-14 22:13:20")
        #expect(formatter.timestamp("1700000000", column: column, mode: .raw) == nil)
        for raw in ["318987599031067570", "9223372036854775807", "253402300800", "1.7e9", "1700000000.1", " 1700000000", String(repeating: "1", count: 100_000)] {
            #expect(formatter.timestamp(raw, column: column, mode: .seconds) == nil)
            #expect(formatter.preview(.text(raw), column: column, maximumCharacterCount: 200) == WorkspaceDatabaseDataCell.boundedPreview(raw, maximumCharacterCount: 200))
        }
    }

    @Test func timeZoneAndTypedFallbackMatchDesktop() {
        let column = WorkspaceDatabaseDataColumn(id: 0, name: "timestamp", type: "bigint")
        let china = WorkspaceTimestampDisplayFormatter(timeZone: TimeZone(secondsFromGMT: 8 * 3_600))
        #expect(china.timestamp("1700000000", column: column) == "2023-11-15 06:13:20")
        #expect(formatter.timestamp("1700000000", column: column) == "2023-11-14 22:13:20")
        for cell in [WorkspaceDatabaseDataCell.null, .text(""), .text("2023-11-14 22:13:20"), .binary(byteCount: 3, preview: [0, 65, 255])] {
            #expect(formatter.preview(cell, column: column, maximumCharacterCount: 200) == cell.gridPreviewText(nullDisplayText: "NULL", maximumCharacterCount: 200))
        }
        #expect(formatter.preview(.text("1700000000"), column: column, maximumCharacterCount: 10) == WorkspaceDatabaseDataCell.boundedPreview("2023-11-14 22:13:20", maximumCharacterCount: 10))
    }

    @Test func modesSurviveRefreshAndResetOnObjectOrMetadataChanges() {
        let display = MobileGridTimestampDisplay()
        let columns: [WorkspaceDatabaseDataColumn] = [.init(id: 0, name: "same", type: "bigint"), .init(id: 1, name: "same", type: "bigint")]
        #expect(display.configure(scope: "a", columns: columns))
        #expect(display.set(.seconds, column: 0))
        #expect(display.mode(column: 1) == .automatic)
        #expect(display.configure(scope: "a", columns: columns) == false)
        #expect(display.mode(column: 0) == .seconds)
        #expect(display.configure(scope: "b", columns: columns))
        #expect(display.mode(column: 0) == .automatic)
        display.set(.raw, column: 0)
        #expect(display.configure(scope: "b", columns: [.init(id: 0, name: "same", type: "varchar")]))
        #expect(display.mode(column: 0) == .automatic)
        #expect(display.set(.seconds, column: 1) == false)
    }

    @Test func realMySQLTableAliasesJoinExpressionsAndEmptyMetadata() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        let config = MariaDBTransportConfiguration(host: "127.0.0.1", port: port, username: "proof_reader",
            password: "querycraft-proof-reader", database: "querycraft_ios_proof", tlsMode: .required)
        let service = MobileMySQLService()
        let object = MobileDatabaseObject(database: "querycraft_ios_proof", name: "epoch_values", kind: .table, comment: "")
        let columns = try await service.columns(configuration: config, object: object)
        let page = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 100, sortColumn: nil, ascending: true)
        let data = MobileGridData(preview: page.preview)
        #expect(data.rows.count == 3)
        #expect(data.cell(row: 0, column: 0) == .text("318987599031067570"))
        #expect(formatter.timestamp("1700000000", column: data.metadata[1]) == "2023-11-14 22:13:20")
        #expect(formatter.timestamp("1700000000000", column: data.metadata[2]) == "2023-11-14 22:13:20")
        #expect(formatter.timestamp("1700000000", column: data.metadata[3]) == nil)
        let sql = "SELECT a.created_at AS alias, b.updated_at AS joined, a.created_at + 0 AS expression FROM querycraft_ios_proof.epoch_values a JOIN querycraft_ios_other.epoch_values b ON a.id = b.id"
        let executor = MobileMariaDBExecutor()
        for suffix in [" ORDER BY a.id", " WHERE 1 = 0"] {
            let result = try await executor.execute(configuration: config, sql: sql + suffix)
            let metadata = MobileGridData(preview: .init(result: result)).metadata
            #expect(metadata[0].origin?.columnName == "created_at")
            #expect(metadata[1].origin?.databaseName == "querycraft_ios_other")
            #expect(metadata[1].origin?.columnName == "updated_at")
            #expect(metadata[2].origin == nil)
            #expect(formatter.timestamp("1700000000", column: metadata[0]) != nil)
            #expect(formatter.timestamp("1700000000", column: metadata[2]) == nil)
            if suffix.contains("1 = 0") { #expect(result.rows.isEmpty) }
        }
    }
}
