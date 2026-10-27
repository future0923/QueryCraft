import XCTest
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor
final class MobileMariaDBIntegrationTests: XCTestCase {
    private func configuration(tls: ConnectionTLSMode = .required) throws -> MobileSQLConfiguration {
        guard let port = ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Set PROOF_MYSQL_PORT for the isolated local MySQL fixture.")
        }
        return .init(host: MobileFixtureEndpoint.host, port: port, username: "proof_reader",
                     password: "querycraft-proof-reader", database: "querycraft_ios_proof", tlsMode: tls)
    }

    func testRealQueryPreservesMetadataNullUnicodeAndBinaryType() async throws {
        let result = try await MobileMariaDBExecutor().execute(configuration: configuration(), sql: """
            SELECT id AS alias_id, name, nullable_value, payload, amount,
                   CONCAT(name, '!') AS expression_value
            FROM sample ORDER BY id LIMIT 10
            """)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0][1], "你好 iPad 👋")
        XCTAssertNil(result.rows[0][2])
        XCTAssertEqual(result.rows[1][2], "")
        XCTAssertEqual(result.columnTypes[3], "varbinary")
        XCTAssertEqual(result.columnOrigins[0]?.columnName, "id")
        XCTAssertEqual(result.columnOrigins[0]?.tableName, "sample")
        XCTAssertNil(result.columnOrigins[5])
        XCTAssertEqual(result.workspaceColumns[0].origin?.columnName, "id")
    }

    func testRealEmptyQueryRetainsColumns() async throws {
        let result = try await MobileMariaDBExecutor().execute(configuration: configuration(), sql: "SELECT id, name FROM sample WHERE 1 = 0")
        XCTAssertEqual(result.columns, ["id", "name"])
        XCTAssertTrue(result.rows.isEmpty)
    }

    func testConnectionIsActuallyEncrypted() async throws {
        let result = try await MobileMariaDBExecutor().execute(configuration: configuration(), sql: "SHOW STATUS LIKE 'Ssl_cipher'")
        XCTAssertFalse(result.rows.first?[1]?.isEmpty ?? true)
    }

    func testServerErrorAndBadPasswordAreReported() async throws {
        let config = try configuration()
        do {
            _ = try await MobileMariaDBExecutor().execute(configuration: config, sql: "SELECT missing_column FROM sample")
            XCTFail("Missing column should fail")
        } catch let error as CDatabaseClientError {
            XCTAssertEqual(error.code, 1054)
        }
        let invalid = MobileSQLConfiguration(host: config.host, port: config.port, username: config.username,
            password: "intentionally-invalid", database: config.database, tlsMode: config.tlsMode)
        do {
            _ = try await MobileMariaDBExecutor().execute(configuration: invalid, sql: "SELECT 1")
            XCTFail("Invalid password should fail")
        } catch let error as CDatabaseClientError {
            XCTAssertEqual(error.code, 1045)
        }
    }

    func testCancellationInterruptsServerAndNextQueryStillWorks() async throws {
        let config = try configuration()
        let task = Task {
            try await MobileMariaDBExecutor().execute(configuration: config, sql: "SELECT SLEEP(20)")
        }
        try await Task.sleep(for: .milliseconds(500))
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled query should not publish a result")
        } catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        let next = try await MobileMariaDBExecutor().execute(configuration: config, sql: "SELECT 42 AS answer")
        XCTAssertEqual(next.rows, [["42"]])
    }

    func testNativePreviewRowByteLimitsAndBinaryCells() async throws {
        let client = MariaDBClient(configuration: try configuration())
        try await client.connect()
        let limited = try await client.queryPreview("WITH RECURSIVE n AS (SELECT 1 AS x UNION ALL SELECT x + 1 FROM n WHERE x < 700) SELECT x FROM n", maximumRows: 5)
        XCTAssertEqual(limited.result.rows.count, 5); XCTAssertTrue(limited.isTruncated)
        // A limited unbuffered query closes its socket instead of draining the rest.
        try await client.connect()
        let binary = try await client.queryPreview("SELECT payload, nullable_value FROM sample ORDER BY id", maximumRows: 10)
        XCTAssertFalse(binary.isTruncated)
        XCTAssertEqual(binary.cells[0][0], .binary(byteCount: 3, preview: [0, 65, 255]))
        XCTAssertEqual(binary.cells[0][1], .null)
        XCTAssertEqual(binary.cells[1][1], .text(""))
        let large = try await client.queryPreview("SELECT REPEAT('x', 1000) AS value", maximumRows: 10, maximumBytes: 100)
        XCTAssertTrue(large.isTruncated); XCTAssertTrue(large.result.rows.isEmpty)
        try await client.connect()
        let next = try await client.query("SELECT 42")
        XCTAssertEqual(next.rows, [["42"]])
        await client.close()
    }

    func testRealBrowserMetadataPagingSortingAndLiteralSearch() async throws {
        let service = MobileMySQLService(), config = try configuration()
        let databases = try await service.databases(configuration: config)
        XCTAssertTrue(databases.contains("querycraft_ios_proof"))
        let catalog = try await service.objects(configuration: config, database: "querycraft_ios_proof", search: "sam")
        let object = try XCTUnwrap(catalog.objects.first { $0.name == "sample" })
        let columns = try await service.columns(configuration: config, object: object)
        XCTAssertEqual(columns.first?.key, "PRI")
        XCTAssertEqual(columns.first?.comment, "primary identifier")
        let first = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 1, sortColumn: nil, ascending: true)
        XCTAssertEqual(first.preview.result.rows.first?.first ?? nil, "1")
        XCTAssertTrue(first.hasNextPage); XCTAssertTrue(first.hasStableOrder)
        let second = try await service.page(configuration: config, object: object, columns: columns, offset: 1, size: 1, sortColumn: nil, ascending: true)
        XCTAssertEqual(second.preview.result.rows.first?.first ?? nil, "2"); XCTAssertFalse(second.hasNextPage)
        let descending = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 1, sortColumn: "id", ascending: false)
        XCTAssertEqual(descending.preview.result.rows.first?.first ?? nil, "2")
        let empty = try await service.objects(configuration: config, database: "querycraft_ios_proof", search: "%' OR 1=1 --")
        XCTAssertTrue(empty.objects.isEmpty)
        do { _ = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 1, sortColumn: "injected`name", ascending: true); XCTFail() }
        catch MobileQueryError.invalidServerMetadata { }
    }

    func testRealCatalogTabsSeparateTablesAndViewsAndReadView() async throws {
        let service = MobileMySQLService(), config = try configuration()
        let tables = try await service.objects(configuration: config, database: "querycraft_ios_proof", search: "sam", kind: .table)
        let views = try await service.objects(configuration: config, database: "querycraft_ios_proof", search: "sam", kind: .view)
        XCTAssertEqual(tables.objects.map(\.name), ["sample"])
        XCTAssertEqual(views.objects.map(\.name), ["sample_view"])
        XCTAssertTrue(tables.objects.allSatisfy { $0.kind == .table })
        XCTAssertTrue(views.objects.allSatisfy { $0.kind == .view })
        let view = try XCTUnwrap(views.objects.first)
        let columns = try await service.columns(configuration: config, object: view)
        let page = try await service.page(configuration: config, object: view, columns: columns, offset: 0, size: 100, sortColumn: "id", ascending: true)
        XCTAssertEqual(page.preview.result.rows.count, 2)
        XCTAssertEqual(page.preview.result.columns, ["id", "name"])
    }

    func testReadOnlyPolicyRejectsWritesBeforeServerExecution() async throws {
        let config = try configuration()
        do { _ = try await MobileMariaDBExecutor().execute(configuration: config, sql: "DELETE FROM sample"); XCTFail() }
        catch MobileQueryError.readOnlySQLRequired { }
        let result = try await MobileMariaDBExecutor().execute(configuration: config, sql: "SELECT COUNT(*) FROM sample")
        XCTAssertEqual(result.rows, [["2"]])
    }

    func testUnimplementedVerifiedTLSModesAreRefusedBeforeConnecting() async throws {
        for mode in [ConnectionTLSMode.verifyCA, .verifyIdentity] {
            let config = MobileSQLConfiguration(host: "127.0.0.1", port: 1, username: "unused",
                password: nil, database: nil, tlsMode: mode)
            do {
                _ = try await MobileMariaDBExecutor().execute(configuration: config, sql: "SELECT 1")
                XCTFail("Unimplemented strict verification must be refused, never silently weakened")
            } catch MobileQueryError.verifiedTLSUnavailable { }
        }
    }

    func testRealCatalogUsesDesktopFuzzyMatcherForCaseAndSkippedCharacters() async throws {
        let service = MobileMySQLService(), config = try configuration()
        for text in ["ad", "amu", "ADMIN_USER"] {
            let catalog = try await service.objects(configuration: config, database: "querycraft_ios_proof", search: text, kind: .table)
            XCTAssertTrue(catalog.objects.contains { $0.name == "admin_user" }, text)
        }
        let literal = try await service.objects(configuration: config, database: "querycraft_ios_proof", search: "%", kind: .table)
        XCTAssertEqual(literal.objects.map(\.name), ["Case_Search%_表"])
        let wide = MobileDatabaseObject(database: "querycraft_ios_proof", name: "admin_user", kind: .table, comment: "")
        let columns = try await service.columns(configuration: config, object: wide)
        XCTAssertEqual(columns.count, 78)
        let page = try await service.page(configuration: config, object: wide, columns: columns, offset: 0, size: 100, sortColumn: nil, ascending: true)
        XCTAssertEqual(page.preview.result.rows.count, 100)
        XCTAssertTrue(page.hasNextPage)
        XCTAssertEqual(page.preview.result.columns.count, 78)
    }
}
