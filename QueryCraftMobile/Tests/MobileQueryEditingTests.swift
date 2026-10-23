import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

struct MobileQueryEditingTests {
    private func configuration(user: String = "proof_writer") throws -> MariaDBTransportConfiguration {
        .init(host: "127.0.0.1", port: try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init)),
            username: user, password: user == "proof_writer" ? "querycraft-proof-writer" : "querycraft-proof-reader",
            database: "querycraft_ios_edit", tlsMode: .required)
    }
    @MainActor private func model(_ sql: String, user: String = "proof_writer") async throws -> MobileQueryModel {
        let config = try configuration(user: user), model = MobileQueryModel()
        model.host = config.host; model.port = String(config.port); model.username = config.username
        model.password = config.password ?? ""; model.database = config.database ?? ""; model.sql = sql
        await model.execute()?.value
        #expect(model.errorMessage == nil)
        return model
    }
    private func query(_ sql: String) async throws -> CDatabaseQueryResult {
        try await MobileMariaDBExecutor().execute(configuration: configuration(), sql: sql)
    }

    @Test @MainActor func aliasesRawIDsDuplicateProjectionsCommitWithoutRerunningDraftAndDelete() async throws {
        let model = try await model("SELECT id AS row_key,name AS label,name AS again,CONCAT(name,'!') AS expression,payload FROM query_rows ORDER BY id")
        let changes = try #require(model.editing), page = try #require(model.editingPage)
        #expect(model.columnDetails[1].contains("physical name")); #expect(!model.columnDetails[3].contains("physical name"))
        let request = try changes.request(page: page, row: 0, column: 1)
        #expect(request.column.name == "name"); #expect(request.primaryKey.first?.value == .text("318987599031067570"))
        #expect(throws: WorkspaceDatabaseDataCellEditError.metadataUnavailable) { try changes.request(page: page, row: 0, column: 3) }
        #expect(throws: WorkspaceDatabaseDataCellEditError.binaryValueUnavailable) { try changes.request(page: page, row: 0, column: 4) }
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try changes.newInsert() }
        let value = "query 雪'\\\u{0}"
        try changes.stage(request, text: value, mode: .value)
        #expect(model.displayData.cell(row: 0, column: 1) == .text(value))
        #expect(model.displayData.cell(row: 0, column: 2) == .text(value))
        #expect(model.displayData.cell(row: 0, column: 3) == .text("original!"))
        #expect(model.displayData.pendingCells.count == 2)
        model.sql = "SELECT 999 AS untouched_draft"
        #expect(model.execute() == nil); #expect(model.preview?.result.rows[0][1] == "original")
        let capturedID = model.resultID
        #expect(changes.submit() == nil); changes.safetyLock.disable(); await changes.submit()?.value
        #expect(changes.message == nil); #expect(!changes.hasChanges)
        #expect(model.resultID == capturedID); #expect(model.sql == "SELECT 999 AS untouched_draft")
        #expect(model.result?.columns.first == "row_key"); #expect(model.result?.rows[0][1] == value)
        #expect(model.result?.rows[0][2] == value); #expect(model.result?.rows[0][3] == "original!")
        #expect(try await query("SELECT name FROM query_rows ORDER BY id").rows[0][0] == value)
        let patched = try #require(model.editingPage)
        try changes.stage(changes.request(page: patched, row: 1, column: 1), text: "not applied", mode: .value)
        try changes.toggleDelete(page: patched, row: 1)
        #expect(changes.changeSet.updates.isEmpty); #expect(model.displayData.deletedRows == [1])
        try changes.toggleDelete(page: patched, row: 1); #expect(changes.changeSet.updates.count == 1)
        try changes.toggleDelete(page: patched, row: 1); await changes.submit()?.value
        #expect(changes.message == nil); #expect(model.result?.rows.count == 1)
        #expect(try await query("SELECT COUNT(*) FROM query_rows").rows[0][0] == "1")
    }

    @Test @MainActor func crossDatabaseCompositeKeysAndPrimaryKeyMutationUseCapturedOrigin() async throws {
        let model = try await model("SELECT tenant AS t,id AS k,name AS n FROM querycraft_ios_query_other.query_rows ORDER BY tenant")
        let changes = try #require(model.editing), page = try #require(model.editingPage)
        #expect(changes.object.database == "querycraft_ios_query_other")
        try changes.stage(changes.request(page: page, row: 0, column: 1), text: "318987599031067572", mode: .value)
        try changes.stage(changes.request(page: page, row: 0, column: 2), text: "updated", mode: .value)
        model.database = "querycraft_ios_query_other"
        #expect(model.database == "querycraft_ios_edit"); #expect(model.hasPendingChanges)
        changes.safetyLock.disable(); await changes.submit()?.value
        #expect(changes.message == nil)
        #expect(model.result?.rows[0] == ["1","318987599031067572","updated"])
        #expect(try await query("SELECT tenant,id,name FROM querycraft_ios_query_other.query_rows ORDER BY tenant").rows == [["1","318987599031067572","updated"],["2","318987599031067570","two"]])
        let request = try changes.request(page: #require(model.editingPage), row: 0, column: 2)
        #expect(request.primaryKey.map(\.value) == [.text("1"), .text("318987599031067572")])
    }

    @Test @MainActor func rollbackRetainsResultDraftsAndCanCorrectRetry() async throws {
        let model = try await model("SELECT * FROM query_failure ORDER BY id")
        let changes = try #require(model.editing), page = try #require(model.editingPage)
        try changes.stage(changes.request(page: page, row: 0, column: 1), text: "save", mode: .value)
        try changes.stage(changes.request(page: page, row: 1, column: 2), text: "-1", mode: .value)
        changes.safetyLock.disable(); await changes.submit()?.value
        #expect(changes.hasChanges); #expect(changes.message != nil); #expect(model.result?.rows[0][1] == "first")
        #expect(try await query("SELECT name FROM query_failure WHERE id=1").rows[0][0] == "first")
        try changes.stage(changes.request(page: page, row: 1, column: 2), text: "30", mode: .value)
        await changes.submit()?.value
        #expect(changes.message == nil); #expect(model.result?.rows == [["1","save","10"],["2","second","30"]])
    }

    @Test @MainActor func serverDefaultRequiresExplicitRerunAndPreservesDraft() async throws {
        let model = try await model("SELECT id,name FROM query_defaults")
        let changes = try #require(model.editing), page = try #require(model.editingPage)
        try changes.stage(changes.request(page: page, row: 0, column: 1), text: "", mode: .useDefault)
        model.sql = "SELECT 42"; changes.safetyLock.disable(); await changes.submit()?.value
        #expect(changes.message == nil); #expect(model.requiresResultReload); #expect(model.sql == "SELECT 42")
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try changes.request(page: #require(model.editingPage), row: 0, column: 1) }
        #expect(try await query("SELECT name FROM query_defaults").rows[0][0] == "server default")
        await model.execute()?.value
        #expect(model.result?.rows[0][0] == "42"); #expect(!model.requiresResultReload)
    }

    @Test @MainActor func quotedUnicodeAliasesReusePhysicalMetadata() async throws {
        let model = try await model("SELECT id AS `编号`, name AS `名称`, CONCAT(name, '!') AS `计算值` FROM query_denied")
        let changes = try #require(model.editing, Comment(rawValue: model.editingMessage ?? "missing editing"))
        let request = try changes.request(page: #require(model.editingPage), row: 0, column: 1)
        #expect(request.column.name == "name"); #expect(request.primaryKey.first?.columnName == "id")
    }

    @Test @MainActor func expressionNamedPKCannotSupplyMissingKeyAndRealKeyIsChosenPastExpression() async throws {
        let missing = try await model("SELECT 123 AS id,name FROM query_denied")
        let changes = try #require(missing.editing), page = try #require(missing.editingPage)
        #expect(throws: WorkspaceDatabaseDataCellEditError.primaryKeyValueUnavailable("id")) { try changes.request(page: page, row: 0, column: 1) }
        #expect(throws: WorkspaceDatabaseDataCellEditError.primaryKeyValueUnavailable("id")) { try changes.toggleDelete(page: page, row: 0) }
        let complete = try await model("SELECT 123 AS id,id AS actual_key,name FROM query_denied")
        let request = try #require(complete.editing).request(page: #require(complete.editingPage), row: 0, column: 2)
        #expect(request.primaryKey.first?.value == .text("1"))
        #expect(throws: WorkspaceDatabaseDataCellEditError.metadataUnavailable) { try #require(complete.editing).request(page: #require(complete.editingPage), row: 0, column: 0) }
    }

    @Test @MainActor func joinsSelfJoinsViewsNoPKAndEmptyResultsRemainSafe() async throws {
        for sql in ["SELECT a.id,a.name,b.name FROM query_denied a JOIN query_denied b ON a.id=b.id",
                    "SELECT a.id,a.name,b.name FROM query_denied a JOIN query_failure b ON a.id=b.id",
                    "SELECT * FROM query_view"] {
            let result = try await model(sql)
            #expect(result.editing == nil, Comment(rawValue: sql)); #expect(result.editingMessage != nil)
            #expect(result.result != nil)
        }
        let noPK = try await model("SELECT * FROM edit_nopk")
        #expect(throws: WorkspaceDatabaseDataCellEditError.primaryKeyRequired) { try #require(noPK.editing).request(page: #require(noPK.editingPage), row: 0, column: 1) }
        let empty = try await model("SELECT * FROM query_denied WHERE id=-1")
        #expect(empty.result?.rows.isEmpty == true); #expect(empty.editing != nil)
    }

    @Test @MainActor func deniedWriteRetainsQueryAndStagedValues() async throws {
        let model = try await model("SELECT * FROM query_denied", user: "proof_reader")
        let changes = try #require(model.editing), page = try #require(model.editingPage)
        try changes.stage(changes.request(page: page, row: 0, column: 1), text: "denied", mode: .value)
        changes.safetyLock.disable(); await changes.submit()?.value
        #expect(changes.message != nil); #expect(changes.hasChanges)
        #expect(model.result?.rows[0][1] == "unchanged")
        #expect(try await query("SELECT name FROM query_denied").rows[0][0] == "unchanged")
    }

    @Test @MainActor func queryDraftsSurviveHomeAndPreventConnectionReplacementOrDeletion() async throws {
        let config = try configuration()
        let profile = MobileConnectionProfile(id: UUID(), name: "owned query", host: config.host, port: config.port,
            username: config.username, database: config.database ?? "", tlsMode: .required, remembersPassword: false, requiresPassword: true)
        let app = MobileApplicationModel(repository: QueryEditingLibrary(profile: profile), passwords: QueryEditingPasswords())
        app.open(profile, suppliedPassword: config.password)
        let workspace = try #require(app.workspace)
        workspace.query.sql = "SELECT * FROM query_denied"
        await workspace.query.execute()?.value
        let changes = try #require(workspace.query.editing), page = try #require(workspace.query.editingPage)
        try changes.stage(changes.request(page: page, row: 0, column: 1), text: "retained", mode: .value)
        #expect(workspace.hasPendingChanges)
        app.showLibrary(); #expect(changes.safetyLock.isEnabled); #expect(changes.hasChanges)
        let other = MobileConnectionProfile(id: UUID(), name: "other", host: profile.host, port: profile.port,
            username: profile.username, database: profile.database, tlsMode: profile.tlsMode, remembersPassword: false, requiresPassword: true)
        app.open(other, suppliedPassword: config.password)
        #expect(app.workspace === workspace); #expect(app.message != nil)
        #expect(throws: MobileDataMutationError.self) { try app.delete(profile) }
        app.open(profile, suppliedPassword: config.password); app.selectTab(.query)
        #expect(workspace.query.editing === changes); #expect(changes.hasChanges)
        changes.discard(); workspace.cancelAll()
    }

    @Test @MainActor func sharedProjectionRejectsConflictingKeysAndKeepsOrdinaryTablePreparation() throws {
        let metadata = [MobileTableColumn(name: "id", type: "int", isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: "").editingColumn]
        let origin = WorkspaceDatabaseDataColumn.Origin(databaseName: "db", tableName: "t", columnName: "id")
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "a", origin: origin), .init(id: 1, name: "b", origin: origin)]
        #expect(throws: WorkspaceDatabaseDataCellEditError.primaryKeyValueUnavailable("id")) {
            try WorkspaceQueryResultEditing.validatedColumns(selection: .init(databaseName: "db", objectName: "t", kind: .table),
                columns: columns, row: .init(id: 0, values: [.text("1"),.text("2")]), metadata: metadata)
        }
    }
}

@MainActor private final class QueryEditingLibrary: MobileLibraryPersisting {
    var state: MobileLibraryState
    init(profile: MobileConnectionProfile) { state = .init(profiles: [profile]) }
    func load() throws -> MobileLibraryState { state }
    func write(_ state: MobileLibraryState) throws { self.state = state }
}
@MainActor private final class QueryEditingPasswords: MobilePasswordStoring {
    func password(for id: UUID) throws -> String? { nil }
    func setPassword(_ password: String?, for id: UUID) throws {}
}
