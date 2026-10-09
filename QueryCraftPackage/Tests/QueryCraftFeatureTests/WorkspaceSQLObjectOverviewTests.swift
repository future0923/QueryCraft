import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceSQLObjectOverviewTests {
    private func entry(_ name: String = "public.users", comment: String = "员工资料", kind: WorkspaceDatabaseObjectKind = .table) -> WorkspaceSQLObjectOverviewEntry {
        .init(object: .init(name: name, kind: kind), comment: comment, estimatedRowCount: 1200, storageByteCount: 8192)
    }

    @Test func searchesNamesAndCommentsAndRespectsSchemaAndKind() {
        let entries = [entry(), entry("archive.users", comment: "历史", kind: .view)]
        #expect(WorkspaceSQLObjectOverviewRow.filtered(entries, search: " 员工 ", schema: nil, kind: nil).map(\.name) == ["public.users"])
        #expect(WorkspaceSQLObjectOverviewRow.filtered(entries, search: "USERS", schema: "archive", kind: .view).map(\.name) == ["archive.users"])
        #expect(WorkspaceSQLObjectOverviewRow.filtered(entries, search: "历史", schema: nil, kind: .table).isEmpty)
        #expect(WorkspaceSQLObjectOverviewRow.filtered(entries, search: "视图", schema: nil, kind: nil).map(\.name) == ["archive.users"])
        #expect(WorkspaceSQLObjectOverviewRow.filtered(entries, search: "VIEW", schema: nil, kind: nil).map(\.name) == ["archive.users"])
        let table = WorkspaceSQLObjectOverviewEntry(object: .init(name: "users", kind: .table),
                                                  engine: "InnoDB", collation: "utf8mb4_bin")
        #expect(WorkspaceSQLObjectOverviewRow.filtered([table], search: "innodb", schema: nil, kind: nil).count == 1)
        #expect(WorkspaceSQLObjectOverviewRow.filtered([table], search: " utf8mb4_BIN ", schema: nil, kind: nil).count == 1)
        #expect(WorkspaceSQLObjectOverviewRow.filtered([table], search: "innodb", schema: nil, kind: .view).isEmpty)
        #expect(WorkspaceSQLObjectOverviewRow.filtered([entry("admin_user")], search: "dmus", schema: nil, kind: nil).count == 1)
        #expect(WorkspaceSQLObjectOverviewRow.filtered([table], search: "uf8bn", schema: nil, kind: nil).count == 1)
    }

    @Test func savedQueriesShareTheListWithoutInventingTableMetadataOrMixingDatabases() {
        let profile = UUID()
        func query(_ database: String?) -> SavedQuery {
            .init(id: UUID(), connectionProfileID: profile, defaultDatabase: database,
                  name: "users", sql: "SELECT * FROM admin_user", createdAt: .now, updatedAt: .now)
        }
        let queries = [query("db"), query(nil), query("other")]
        let rows = WorkspaceSQLObjectOverviewRow.filtered([entry("users")], search: "", schema: nil,
                                                         kind: nil, savedQueries: queries, database: "db")
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3)
        #expect(rows.filter { $0.kind == .query }.allSatisfy {
            $0.entry == nil && $0.engine.isEmpty && $0.collation.isEmpty && $0.rowCount == -1 && $0.storageSize == -1
        })
        let matches = WorkspaceSQLObjectOverviewRow.filtered([], search: "dmus", schema: "public",
                                                            kind: .query, savedQueries: queries, database: "db")
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.savedQuery != nil })
        #expect(WorkspaceSQLObjectOverviewRow.filtered([], search: "查询", schema: nil, kind: nil,
                                                      savedQueries: queries, database: "db").count == 2)
    }

    @Test func numericSortingUsesValuesAndMissingStatisticsRemainUnknown() {
        let small = WorkspaceSQLObjectOverviewEntry(object: .init(name: "small", kind: .table), estimatedRowCount: 9)
        let large = WorkspaceSQLObjectOverviewEntry(object: .init(name: "large", kind: .table), estimatedRowCount: 1200)
        let rows = [large, small].map { WorkspaceSQLObjectOverviewRow(entry: $0) }
            .sorted(using: [KeyPathComparator(\.rowCount)])
        #expect(rows.map(\.name) == ["small", "large"])
        let unknown = WorkspaceSQLObjectOverviewEntry(object: small.object, fieldCount: -1, estimatedRowCount: -1, storageByteCount: -1)
        #expect(unknown.fieldCount == nil && unknown.estimatedRowCount == nil && unknown.storageByteCount == nil)
    }

    @Test func failedRefreshPreservesContentAndRetryCanProduceAnEmptyResult() async {
        let model = WorkspaceSQLObjectOverviewModel()
        #expect(!model.hasLoaded && !model.isLoading && model.error == nil)
        await model.load(database: "db") { _ in [entry()] }
        await model.load(database: "db") { _ in
            #expect(model.isLoading && model.entries.count == 1 && model.hasLoaded)
            throw WorkspaceSessionError.notConnected
        }
        #expect(model.entries.count == 1 && model.error != nil && !model.isLoading && !model.didCompleteRefresh)
        await model.load(database: "db") { _ in [] }
        #expect(model.entries.isEmpty && model.hasLoaded && model.error == nil && model.didCompleteRefresh)
    }

    @Test func switchingDatabasesRejectsLateResponsesAndNeverShowsThePreviousObjects() async {
        let model = WorkspaceSQLObjectOverviewModel()
        await model.load(database: "initial") { _ in [entry("initial.users")] }
        var pending: CheckedContinuation<[WorkspaceSQLObjectOverviewEntry], Never>?
        let old = Task { @MainActor in
            await model.load(database: "old") { _ in
                #expect(model.entries.isEmpty && !model.hasLoaded && model.isLoading)
                return await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        await model.load(database: "new") { _ in [entry("new.users")] }
        pending?.resume(returning: [entry("old.users")])
        await old.value
        #expect(model.entries.map(\.object.name) == ["new.users"])
        #expect(model.hasLoaded && !model.isLoading && model.error == nil)
    }

    @Test func repeatedRefreshIgnoresTheOlderResultWithoutClearingRows() async {
        let model = WorkspaceSQLObjectOverviewModel()
        await model.load(database: "db") { _ in [entry()] }
        var pending: CheckedContinuation<[WorkspaceSQLObjectOverviewEntry], Never>?
        let old = Task { @MainActor in
            await model.load(database: "db") { _ in
                #expect(model.entries.count == 1)
                return await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        await model.load(database: "db") { _ in [entry("latest")] }
        pending?.resume(returning: [entry("stale")])
        await old.value
        #expect(model.entries.map(\.object.name) == ["latest"])
    }

    @Test func overviewKeepsOpenTabsAndOldViewsCannotRemoveTheCurrentRefreshAction() {
        let tabs = WorkspaceContentTabsModel()
        tabs.open(.init(databaseName: "db", objectName: "users", kind: .table))
        tabs.showDatabaseOverview()
        #expect(tabs.selectedContentID == nil && tabs.contentItems.count == 1)
        let registry = WorkspaceContentRefreshRegistry()
        let old = UUID(), current = UUID()
        registry.updateOverview(.init(title: "old", isStopping: false, didComplete: false, perform: {}), owner: old)
        registry.updateOverview(.init(title: "current", isStopping: false, didComplete: false, perform: {}), owner: current)
        registry.removeOverview(owner: old)
        #expect(registry.overviewActions?.title == "current")
        registry.removeOverview(owner: current)
        #expect(registry.overviewActions == nil)
    }
}
