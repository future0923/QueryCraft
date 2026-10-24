import XCTest
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

final class MobileCatalogSearchTests: XCTestCase {
    private func objects(_ names: [String]) -> [MobileDatabaseObject] {
        names.map { .init(database: "db", name: $0, kind: .table, comment: "") }
    }

    func testDesktopFuzzySearchExamplesAndRankedStableResults() {
        let catalog = objects(["admin_user", "team_amu", "amu_store", "amu", "other", "ADmin_User"])
        XCTAssertEqual(MobileCatalogSearch.objects(catalog, matching: "amu").map(\.name),
                       ["amu", "amu_store", "team_amu", "admin_user", "ADmin_User"])
        XCTAssertEqual(MobileCatalogSearch.objects(catalog, matching: "ad").map(\.name), ["admin_user", "ADmin_User"])
        XCTAssertEqual(MobileCatalogSearch.objects(catalog, matching: "ADMIN_USER").map(\.name), ["admin_user", "ADmin_User"])
        XCTAssertTrue(MobileCatalogSearch.objects(catalog, matching: "mua").isEmpty)
        XCTAssertTrue(MobileCatalogSearch.objects(objects(["admin_user"]), matching: "aa").isEmpty)
        XCTAssertEqual(MobileCatalogSearch.objects(catalog, matching: ""), catalog)
    }

    func testUnicodeAndSQLPatternCharactersStayLiteral() {
        let catalog = objects(["管理用户", "admin_user", "percent%table", "ordinary"])
        XCTAssertEqual(MobileCatalogSearch.objects(catalog, matching: "管户").map(\.name), ["管理用户"])
        XCTAssertEqual(MobileCatalogSearch.objects(catalog, matching: "%").map(\.name), ["percent%table"])
        XCTAssertEqual(MobileCatalogSearch.objects(catalog, matching: "_").map(\.name), ["admin_user"])
        XCTAssertTrue(MobileCatalogSearch.objects(catalog, matching: "%' OR 1=1 --").isEmpty)
    }

    func testCatalogBeyondTwoHundredIsAvailableBeforeFuzzyFiltering() async throws {
        let names = (0..<220).map { "catalog_\($0)" } + ["admin_user"]
        let service = MobileMySQLService(executor: CatalogExecutor(names: names))
        let config = MobileSQLConfiguration(host: "unused", port: 3306, username: "unused", password: nil, database: "db", tlsMode: .disabled)
        let full = try await service.objects(configuration: config, database: "db", search: "", kind: .table)
        XCTAssertEqual(full.objects.count, 221)
        XCTAssertFalse(full.hasMore)
        let matches = try await service.objects(configuration: config, database: "db", search: "amu", kind: .table)
        XCTAssertEqual(matches.objects.map(\.name), ["admin_user"])
    }
}

private struct CatalogExecutor: MobileQueryExecuting {
    let names: [String]
    func execute(configuration: MobileSQLConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        .init(columns: ["TABLE_NAME", "TABLE_TYPE", "TABLE_COMMENT"], rows: names.map { [$0, "BASE TABLE", ""] })
    }
}
