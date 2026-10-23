import QueryCraftMobileCore
import XCTest
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileBrowserTests: XCTestCase {
    private let config = MariaDBTransportConfiguration(host: "unused", port: 3306, username: "unused", password: nil, database: "db", tlsMode: .disabled)
    private let first = MobileDatabaseObject(database: "db", name: "first", kind: .table, comment: "")
    private let second = MobileDatabaseObject(database: "db", name: "second", kind: .table, comment: "")

    func testSlowFirstLoadRefreshFailureAndRetryKeepStableSnapshot() async throws {
        let service = ControlledBrowser()
        let model = MobileBrowserModel(configuration: config, service: service)
        model.selectDatabase("db")
        let initial = try XCTUnwrap(model.selectObject(first))
        await service.wait(1)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.isLoadingTable)
        await service.complete(0, value: "old")
        await initial.value
        let revision = model.revision
        let refresh = try XCTUnwrap(model.loadTable())
        await service.wait(2)
        XCTAssertEqual(model.snapshot?.preview.result.rows, [["old"]])
        XCTAssertEqual(model.revision, revision)
        await service.fail(1)
        await refresh.value
        XCTAssertEqual(model.snapshot?.preview.result.rows, [["old"]])
        XCTAssertNotNil(model.tableError)
        let retry = try XCTUnwrap(model.loadTable())
        await service.wait(3)
        await service.complete(2, value: "new")
        await retry.value
        XCTAssertNil(model.tableError)
        XCTAssertEqual(model.snapshot?.preview.result.rows, [["new"]])
    }

    func testRapidObjectSwitchDoesNotShowPreviousObjectOrAcceptLateReply() async throws {
        let service = ControlledBrowser()
        let model = MobileBrowserModel(configuration: config, service: service)
        model.selectDatabase("db")
        let old = try XCTUnwrap(model.selectObject(first))
        await service.wait(1)
        let next = try XCTUnwrap(model.selectObject(second))
        await service.wait(2)
        XCTAssertNil(model.snapshot)
        await service.complete(1, value: "second")
        await next.value
        await service.complete(0, value: "first")
        await old.value
        XCTAssertEqual(model.snapshot?.object.id, second.id)
        XCTAssertEqual(model.snapshot?.preview.result.rows, [["second"]])
    }

    func testFailedNextPageKeepsCommittedPageAndDatabaseSwitchRejectsLatePage() async throws {
        let service = ControlledBrowser()
        let model = MobileBrowserModel(configuration: config, service: service)
        model.selectDatabase("db")
        let initial = try XCTUnwrap(model.selectObject(first))
        await service.wait(1); await service.complete(0, value: "page one"); await initial.value
        let next = try XCTUnwrap(model.loadTable(offset: 100))
        await service.wait(2); await service.fail(1); await next.value
        XCTAssertEqual(model.snapshot?.offset, 0)
        let late = try XCTUnwrap(model.loadTable(offset: 100))
        await service.wait(3)
        model.selectDatabase("other")
        XCTAssertNil(model.snapshot); XCTAssertNil(model.columns)
        await service.complete(2, value: "wrong database"); await late.value
        XCTAssertNil(model.snapshot)
    }

    func testStructureSwitchRejectsPendingDataAndSuccessfulEmptyPageIsDistinct() async throws {
        let service = ControlledBrowser()
        let model = MobileBrowserModel(configuration: config, service: service)
        model.selectDatabase("db")
        let request = try XCTUnwrap(model.selectObject(first))
        await service.wait(1)
        model.tab = .structure
        await model.loadTable()?.value
        XCTAssertNotNil(model.columns); XCTAssertNil(model.snapshot)
        await service.complete(0, value: "late"); await request.value
        XCTAssertNil(model.snapshot)
        model.tab = .data
        let empty = try XCTUnwrap(model.loadTable())
        await service.wait(2); await service.complete(1, value: nil); await empty.value
        XCTAssertNotNil(model.snapshot); XCTAssertTrue(model.snapshot?.preview.result.rows.isEmpty == true)
        XCTAssertFalse(model.isLoadingTable)
    }
}

private actor ControlledBrowser: MobileMySQLServicing {
    struct Request { let object: MobileDatabaseObject; let offset: Int; let size: Int; let continuation: CheckedContinuation<MobileTableSnapshot, any Error> }
    var requests: [Request] = []
    var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func databases(configuration: MariaDBTransportConfiguration) async throws -> [String] { ["db", "other"] }
    func objects(configuration: MariaDBTransportConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog {
        .init(objects: ["first", "second"].map { .init(database: database, name: $0, kind: .table, comment: "") }, hasMore: false)
    }
    func columns(configuration: MariaDBTransportConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] {
        [.init(name: "id", type: "int", isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: "编号")]
    }
    func page(configuration: MariaDBTransportConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot {
        try await withCheckedThrowingContinuation {
            requests.append(.init(object: object, offset: offset, size: size, continuation: $0))
            let ready = waiters.filter { $0.0 <= requests.count }; waiters.removeAll { $0.0 <= requests.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func wait(_ count: Int) async { if requests.count < count { await withCheckedContinuation { waiters.append((count, $0)) } } }
    func complete(_ index: Int, value: String?) {
        let r = requests[index]
        r.continuation.resume(returning: .init(object: r.object,
            preview: .init(result: .init(columns: ["id"], rows: value.map { [[$0]] } ?? [])), columns: [],
            offset: r.offset, pageSize: r.size, hasNextPage: true, hasStableOrder: true))
    }
    func fail(_ index: Int) { requests[index].continuation.resume(throwing: BrowserFailure.expected) }
    private enum BrowserFailure: Error { case expected }
}
