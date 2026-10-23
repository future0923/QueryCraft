import XCTest
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileSQLAndGridTests: XCTestCase {
    func testSQLPolicyHandlesCommentsQuotesAndServerEscapeMode() throws {
        for sql in ["SELECT 'DROP TABLE x; UPDATE y'", "/* comment */ SELECT `delete` FROM `db`.`table` ; -- done\n", "WITH x AS (SELECT 1) SELECT * FROM x", "SHOW CREATE TABLE sample", "SELECT 'it''s fine'"] {
            XCTAssertNoThrow(try MobileSQLReadPolicy.validate(sql), sql)
        }
        for sql in ["DELETE FROM sample", "SELECT 1; SELECT 2", "SELECT 1 INTO OUTFILE '/tmp/file'", "/*! SELECT 1 */", "/*M! SELECT 1 */", "SELECT 'unclosed", "/* unclosed", "WITH x AS (SELECT 1) DELETE FROM sample", "EXPLAIN ANALYZE UPDATE sample SET id=2"] {
            XCTAssertThrowsError(try MobileSQLReadPolicy.validate(sql), sql)
        }
        XCTAssertThrowsError(try MobileSQLReadPolicy.validate("SELECT 'x\\' INTO OUTFILE '/tmp/x' -- '", backslashEscapes: false))
        XCTAssertThrowsError(try MobileSQLReadPolicy.validate(String(repeating: "x", count: 262_145)))
    }
    func testCommentsRequireMatchingProtocolOriginIncludingAliasesAndSchemas() {
        let object = MobileDatabaseObject(database: "db", name: "sample", kind: .table, comment: "")
        let columns = [MobileTableColumn(name: "id", type: "int unsigned", isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: "identifier")]
        let result = CDatabaseQueryResult(columns: ["alias", "id", "id", "id"], columnTypes: ["int", "int", "int", "int"], columnOrigins: [
            .init(databaseName: "db", tableName: "sample", columnName: "id"), nil,
            .init(databaseName: "other", tableName: "sample", columnName: "id"),
            .init(databaseName: "db", tableName: "joined", columnName: "id")], rows: [])
        XCTAssertEqual(MobileColumnDetails.resolve(result: result, object: object, columns: columns), ["int unsigned · identifier", "int", "int", "int"])
    }
    func testDesktopAndMobileShareBoundedSamplingAndCellPreview() {
        for (rows, columns, maximum) in [(0, 1, 0), (1, 1, 1), (1_000_000, 20, 30), (1_000_000, 1000, 10)] {
            let indexes = WorkspaceGridSampling.sampleIndexes(rowCount: rows, columnCount: columns)
            XCTAssertEqual(indexes.count, maximum)
            XCTAssertEqual(Set(indexes).count, indexes.count)
            XCTAssertTrue(indexes.allSatisfy { $0 >= 0 && $0 < rows })
            if rows > 1 { XCTAssertEqual(indexes.last, rows - 1) }
        }
        XCTAssertEqual(WorkspaceDatabaseDataCell.text(String(repeating: "👨‍👩‍👧", count: 1000)).gridPreviewText(nullDisplayText: "NULL", maximumCharacterCount: 3), "👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧...")
    }

    func testNativeGridRefreshPreservesViewportAndSelectionButSwitchClearsOldCells() throws {
        let columns = ["id", "name", "value", "extra"]
        let rows: [[String?]] = (0..<100).map { [String($0), String(repeating: "name", count: 10), "value", "extra"] }
        let key = UUID().uuidString
        let first = MobileDataGrid(data: .init(columns: columns, rows: rows), revision: "first", widthKey: key) { _, _ in }
        let coordinator = first.makeCoordinator()
        let view = MobileDataGrid.makeCollectionView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 160, height: 300)
        let headers = MobileDataGrid(data: .init(columns: columns, rows: []), revision: "headers", widthKey: key) { _, _ in }
        headers.apply(to: view, coordinator: coordinator)
        first.apply(to: view, coordinator: coordinator)
        XCTAssertGreaterThan(coordinator.widths[1], 100, "First arriving rows must participate in automatic sizing")
        coordinator.widths[0] = 240
        (view.collectionViewLayout as? MobileGridLayout)?.widths = coordinator.widths
        view.collectionViewLayout.invalidateLayout(); view.layoutIfNeeded()
        view.contentOffset = CGPoint(x: 80, y: 200)
        let selected = IndexPath(item: 1, section: 9)
        view.selectItem(at: selected, animated: false, scrollPosition: [])
        let refresh = MobileDataGrid(data: .init(columns: columns, rows: rows), revision: "refresh", widthKey: key) { _, _ in }
        refresh.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(view.contentOffset, CGPoint(x: 80, y: 200))
        XCTAssertEqual(view.indexPathsForSelectedItems, [selected])
        XCTAssertEqual(coordinator.widths[0], 240)
        view.frame = CGRect(x: 0, y: 0, width: 700, height: 220)
        view.collectionViewLayout.invalidateLayout(); view.layoutIfNeeded()
        XCTAssertEqual(view.indexPathsForSelectedItems, [selected])
        XCTAssertEqual(coordinator.widths[0], 240)
        let landscapeHeaders = try XCTUnwrap(view.collectionViewLayout.layoutAttributesForElements(in: view.bounds))
        XCTAssertTrue(landscapeHeaders.filter { $0.indexPath.section == 0 }.allSatisfy { $0.frame.minY == view.contentOffset.y })
        let cleared = MobileDataGrid(data: .init(columns: [], rows: []), revision: "switched", widthKey: "other") { _, _ in }
        cleared.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(view.numberOfSections, 1)
        XCTAssertEqual(view.numberOfItems(inSection: 0), 0)
        XCTAssertTrue(view.indexPathsForSelectedItems?.isEmpty ?? true)
        XCTAssertEqual(view.contentOffset, .zero)
        let next = MobileDataGrid(data: .init(columns: ["new"], rows: [["fresh"]]), revision: "loaded", widthKey: "other") { _, _ in }
        next.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(view.numberOfSections, 2)
        XCTAssertEqual(view.numberOfItems(inSection: 1), 1)
    }
    func testGridLayoutWorkIsBoundedByVisibleCellsAndHeaderStaysPinned() throws {
        let layout = MobileGridLayout()
        layout.widths = Array(repeating: 100, count: 1000); layout.rowCount = 1_000_000
        let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 500), collectionViewLayout: layout)
        view.contentOffset = CGPoint(x: 50_000, y: 50_000)
        let attributes = try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(x: 50_000, y: 50_000, width: 400, height: 500)))
        XCTAssertLessThan(attributes.count, 120)
        XCTAssertTrue(attributes.filter { $0.indexPath.section == 0 }.allSatisfy { $0.frame.minY == 50_000 && $0.zIndex == 10 })
        XCTAssertEqual(layout.collectionViewContentSize.width, 100_000)
        XCTAssertGreaterThan(layout.collectionViewContentSize.height, 30_000_000)
    }
}
