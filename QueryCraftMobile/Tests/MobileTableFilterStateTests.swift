import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileTableFilterStateTests {
    private let config = MariaDBTransportConfiguration(host: "unused", port: 1, username: "unused", password: nil, database: "db", tlsMode: .required)
    private let object = MobileDatabaseObject(database: "db", name: "first", kind: .table, comment: "")
    private func filter(_ value: String) -> WorkspaceDatabaseDataFilter {
        .init(conditions: [.init(columnName: "id", columnKind: .number, operation: .greaterThan, value: value)])
    }

    @Test func failedFilterKeepsCommittedPageAndRetryStartsAtFirstFilteredPage() async throws {
        let service = ControlledFilterService(), model = MobileBrowserModel(configuration: config, service: service)
        model.selectDatabase("db")
        let initial = try #require(model.selectObject(object))
        try await service.wait(1); await service.respond(0, value: "initial"); await initial.value
        let page = try #require(model.loadTable(offset: 100))
        try await service.wait(2); await service.respond(1, value: "old page"); await page.value
        let condition = filter("110")
        let request = try #require(try model.applyFilter(condition, objectID: object.id))
        try await service.wait(3)
        #expect(model.snapshot?.offset == 100)
        #expect(model.snapshot?.filter.isActive == false)
        #expect(model.isLoadingTable)
        await service.fail(2); await request.value
        #expect(model.snapshot?.preview.result.rows == [["old page"]])
        #expect(model.tableError != nil)
        let retry = try #require(model.loadTable())
        try await service.wait(4)
        let info = await service.info(3)
        #expect(info.offset == 0 && info.filter == condition)
        await service.respond(3, value: "filtered"); await retry.value
        #expect(model.snapshot?.offset == 0)
        #expect(model.snapshot?.filter == condition)
        #expect(model.tableError == nil)
    }

    @Test func rapidFiltersAndObjectSwitchRejectLateFilteredResponses() async throws {
        let service = ControlledFilterService(), model = MobileBrowserModel(configuration: config, service: service)
        model.selectDatabase("db")
        let initial = try #require(model.selectObject(object))
        try await service.wait(1); await service.respond(0, value: "initial"); await initial.value
        let first = try #require(try model.applyFilter(filter("10"), objectID: object.id))
        try await service.wait(2)
        let currentFilter = filter("20")
        let second = try #require(try model.applyFilter(currentFilter, objectID: object.id))
        try await service.wait(3); await service.respond(2, value: "new"); await second.value
        await service.respond(1, value: "late"); await first.value
        #expect(model.snapshot?.preview.result.rows == [["new"]])
        #expect(model.snapshot?.filter == currentFilter)
        let pending = try #require(try model.applyFilter(filter("30"), objectID: object.id))
        try await service.wait(4)
        let other = MobileDatabaseObject(database: "db", name: "second", kind: .table, comment: "")
        let next = try #require(model.selectObject(other))
        try await service.wait(5)
        #expect(model.snapshot == nil)
        #expect(model.dataFilter == .empty)
        #expect(throws: (any Error).self) { try model.applyFilter(currentFilter, objectID: object.id) }
        await service.respond(3, value: "wrong object"); await pending.value
        await service.respond(4, value: "other"); await next.value
        #expect(model.snapshot?.object == other)
        #expect(model.snapshot?.filter == .empty)
    }

    @Test func pagingSortingRefreshAndClearUseTheSameFilter() async throws {
        let service = ControlledFilterService(), model = MobileBrowserModel(configuration: config, service: service)
        model.selectDatabase("db")
        let initial = try #require(model.selectObject(object))
        try await service.wait(1); await service.respond(0, value: "initial"); await initial.value
        let active = filter("5")
        let request = try #require(try model.applyFilter(active, objectID: object.id))
        try await service.wait(2); await service.respond(1, value: "filtered"); await request.value
        #expect(try model.applyFilter(active, objectID: object.id) == nil)
        model.sort(by: "id")
        try await service.wait(3)
        let sorted = await service.info(2)
        #expect(sorted.filter == active && sorted.offset == 0 && sorted.sort == "id")
        await service.respond(2, value: "sorted"); try await finish(model)
        let page = try #require(model.loadTable(offset: 25))
        try await service.wait(4)
        #expect(await service.info(3).filter == active)
        await service.respond(3, value: "page"); await page.value
        let refresh = try #require(model.loadTable(reloadColumns: true))
        try await service.wait(5)
        let refreshed = await service.info(4)
        #expect(refreshed.filter == active && refreshed.offset == 25)
        await service.respond(4, value: "refresh"); await refresh.value
        let clear = try #require(try model.applyFilter(.empty, objectID: object.id))
        try await service.wait(6)
        #expect(await service.info(5).offset == 0)
        await service.respond(5, value: nil); await clear.value
        #expect(model.snapshot != nil)
        #expect(model.snapshot?.preview.result.rows.isEmpty == true)
        #expect(model.snapshot?.filter.isActive == false)
    }

    @Test func changedSchemaFailurePreservesOldGridAndOffersFreshFieldsForRepair() async throws {
        let service = ControlledFilterService(), model = MobileBrowserModel(configuration: config, service: service)
        model.selectDatabase("db")
        let initial = try #require(model.selectObject(object))
        try await service.wait(1); await service.respond(0, value: "initial"); await initial.value
        let request = try #require(try model.applyFilter(filter("5"), objectID: object.id))
        try await service.wait(2); await service.respond(1, value: "old data"); await request.value
        await service.changeColumnType()
        await model.loadTable(reloadColumns: true)?.value
        #expect(model.snapshot?.preview.result.rows == [["old data"]])
        #expect(model.tableError != nil)
        let columns = try #require(model.columns)
        #expect(columns[0].type == "varchar(80)")
        let draft = MobileTableFilterDraft(object: object, columns: columns, filter: model.dataFilter)
        #expect(draft.canApply == false)
        draft.filter = .empty
        let repair = try #require(try model.applyFilter(draft.filter, objectID: object.id))
        try await service.wait(3); await service.respond(2, value: "new data"); await repair.value
        #expect(model.tableError == nil)
        #expect(model.snapshot?.filter == .empty)
    }

    private func finish(_ model: MobileBrowserModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.isLoadingTable {
            guard ContinuousClock.now < deadline else { throw FilterStateError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum FilterStateError: Error { case expected, timeout }
private actor ControlledFilterService: MobileMySQLServicing {
    struct Info: Sendable { let offset: Int; let filter: WorkspaceDatabaseDataFilter; let sort: String? }
    private struct Request {
        let object: MobileDatabaseObject; let info: Info; let size: Int; let columns: [MobileTableColumn]
        let continuation: CheckedContinuation<MobileTableSnapshot, any Error>
    }
    private var requests: [Request] = []
    private var type = "int"
    func databases(configuration: MariaDBTransportConfiguration) async throws -> [String] { ["db"] }
    func objects(configuration: MariaDBTransportConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog {
        .init(objects: ["first", "second"].map { .init(database: database, name: $0, kind: .table, comment: "") }, hasMore: false)
    }
    func columns(configuration: MariaDBTransportConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] {
        [.init(name: "id", type: type, isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: "")]
    }
    func changeColumnType() { type = "varchar(80)" }
    func page(configuration: MariaDBTransportConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot {
        try MobileTableFilterDraft.validate(filter, columns: columns)
        return try await withCheckedThrowingContinuation {
            requests.append(.init(object: object, info: .init(offset: offset, filter: filter, sort: sortColumn), size: size, columns: columns, continuation: $0))
        }
    }
    func wait(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while requests.count < count {
            guard ContinuousClock.now < deadline else { throw FilterStateError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func info(_ index: Int) -> Info { requests[index].info }
    func respond(_ index: Int, value: String?) {
        let request = requests[index]
        request.continuation.resume(returning: .init(object: request.object,
            preview: .init(result: .init(columns: ["id"], rows: value.map { [[$0]] } ?? [])), columns: request.columns,
            offset: request.info.offset, pageSize: request.size, hasNextPage: value != nil, hasStableOrder: true, filter: request.info.filter))
    }
    func fail(_ index: Int) { requests[index].continuation.resume(throwing: FilterStateError.expected) }
}
