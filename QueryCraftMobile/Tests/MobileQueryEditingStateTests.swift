import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileQueryEditingStateTests {
    private func model(metadata: any MobileSQLServicing, writer: any MobileDataMutating = QueryEditingUnknownWriter()) -> MobileQueryModel {
        let model = MobileQueryModel(executor: QueryEditingExecutor(), metadataService: metadata, mutationService: writer)
        model.database = "db"; model.sql = "SELECT id,name FROM t"
        return model
    }
    @Test func slowMetadataCancelAndLateResponseCannotReplaceCurrentEditingContext() async throws {
        let metadata = QueryEditingMetadata(delaysFirst: true), model = model(metadata: metadata)
        let old = try #require(model.execute())
        await metadata.waitUntilWaiting()
        #expect(model.result?.rows[0] == ["1","before"]); #expect(!model.isLoading); #expect(model.isLoadingEditing)
        #expect(model.editing == nil)
        model.cancel(); model.sql = "SELECT id,name FROM t WHERE id=1"
        await model.execute()?.value
        let current = try #require(model.editing), revision = model.resultRevision
        await metadata.release(); await old.value
        #expect(model.editing === current); #expect(model.resultRevision == revision); #expect(!model.isLoadingEditing)
    }
    @Test func metadataFailureKeepsDataAndRetryUsesSameExecutePath() async throws {
        let metadata = QueryEditingMetadata(failsFirst: true), model = model(metadata: metadata)
        await model.execute()?.value
        #expect(model.result?.rows[0][1] == "before"); #expect(model.editing == nil); #expect(model.editingMessage != nil)
        #expect(model.errorMessage == nil); #expect(!model.isLoadingEditing)
        await model.execute()?.value
        #expect(model.editing != nil); #expect(model.editingMessage == nil)
    }
    @Test func stalePresentedRequestCannotStageAfterNewResultAndUncertainCommitRequiresRerun() async throws {
        let model = model(metadata: QueryEditingMetadata())
        await model.execute()?.value
        let old = try #require(model.editing), page = try #require(model.editingPage)
        let request = try old.request(page: page, row: 0, column: 1)
        await model.execute()?.value
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try old.stage(request, text: "stale", mode: .value) }
        let current = try #require(model.editing), currentPage = try #require(model.editingPage)
        try current.stage(current.request(page: currentPage, row: 0, column: 1), text: "draft", mode: .value)
        let database = model.database
        model.host = "changed.invalid"; model.database = "new_db"
        #expect(model.host == "127.0.0.1"); #expect(model.database == database); #expect(model.hasPendingChanges)
        current.safetyLock.disable(); await current.submit()?.value
        #expect(current.needsVerification); #expect(model.execute() == nil)
        current.discard()
        #expect(!model.hasPendingChanges); #expect(model.requiresResultReload); #expect(model.editingMessage != nil)
        #expect(model.errorMessage == nil)
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try current.request(page: currentPage, row: 0, column: 1) }
        await model.execute()?.value; #expect(!model.requiresResultReload); #expect(model.editing != nil)
    }
    @Test func tableAndQueryShareLockAndConnectionCannotBeReplacedWithQueryDrafts() async throws {
        let profile = MobileConnectionProfile(id: UUID(), name: "test", host: "127.0.0.1", port: 3306,
            username: "test", database: "db", tlsMode: .disabled, remembersPassword: false, requiresPassword: false)
        let workspace = MobileDatabaseWorkspace(profile: profile, password: nil, service: QueryEditingMetadata())
        #expect(workspace.query.safetyLock === workspace.browser.safetyLock)
        workspace.query.safetyLock.disable(); workspace.cancelAll(); #expect(workspace.query.safetyLock.isEnabled)
    }
}

struct QueryEditingExecutor: MobileQueryExecuting {
    func execute(configuration: MobileSQLConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        .init(columns: ["id","name"], columnTypes: ["int","varchar(80)"],
            columnOrigins: ["id","name"].map { .init(databaseName: "db", tableName: "t", columnName: $0) }, rows: [["1","before"]])
    }
}
actor QueryEditingMetadata: MobileSQLServicing {
    private let delaysFirst: Bool, failsFirst: Bool
    private var count = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var waiting = false
    init(delaysFirst: Bool = false, failsFirst: Bool = false) { self.delaysFirst = delaysFirst; self.failsFirst = failsFirst }
    func waitUntilWaiting() async { while !waiting { await Task.yield() } }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
    func databases(configuration: MobileSQLConfiguration) async throws -> [String] { ["db"] }
    func objects(configuration: MobileSQLConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog {
        count += 1
        if count == 1, delaysFirst { waiting = true; await withCheckedContinuation { releaseContinuation = $0 } }
        if count == 1, failsFirst { throw MobileQueryError.invalidServerMetadata }
        return .init(objects: [.init(database: "db", name: "t", kind: .table, comment: "")], hasMore: false)
    }
    func columns(configuration: MobileSQLConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] {
        [.init(name: "id", type: "int", isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: ""),
         .init(name: "name", type: "varchar(80)", isNullable: true, key: "", defaultValue: nil, extra: "", comment: "")]
    }
    func page(configuration: MobileSQLConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int,
              sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot { throw MobileQueryError.invalidServerMetadata }
}
private struct QueryEditingUnknownWriter: MobileDataMutating {
    func apply(_ changes: WorkspaceDatabaseDataChangeSet, configuration: MobileSQLConfiguration,
               authorize: @escaping @Sendable () async throws -> Void) async throws {
        try await authorize(); throw MobileDataMutationError.uncertainCommit
    }
}
