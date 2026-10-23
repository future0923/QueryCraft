import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileTableActionIntegrationTests {
    private func config(reader: Bool = false) throws -> MariaDBTransportConfiguration {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        return .init(host: "127.0.0.1", port: port, username: reader ? "proof_reader" : "proof_table_admin",
            password: reader ? "querycraft-proof-reader" : "querycraft-proof-table-admin", database: "querycraft_ios_table_actions", tlsMode: .required)
    }
    private func object(_ name: String, kind: MobileDatabaseObject.Kind = .table) -> MobileDatabaseObject {
        .init(database: "querycraft_ios_table_actions", name: name, kind: kind, comment: "")
    }
    private func read(_ sql: String) async throws -> CDatabaseQueryResult {
        try await MobileMariaDBExecutor().execute(configuration: config(), sql: sql)
    }
    private func write(_ sql: String) async throws -> CDatabaseQueryResult {
        let client = MariaDBClient(configuration: try config())
        do { try await client.connect(); let result = try await client.query(sql); await client.close(); return result }
        catch { await client.close(); throw error }
    }
    private func perform(_ action: WorkspaceTableAction, _ table: String, input: String = "") async throws {
        _ = try await MobileTableActionService().perform(action: action, object: object(table), input: input, configuration: config(), authorize: {})
    }

    @Test func appNavigationFollowsRealRenameThenLeavesDroppedTable() async throws {
        let configuration = try config()
        let profile = MobileConnectionProfile(id: UUID(), name: "owned DDL", host: configuration.host, port: configuration.port,
            username: configuration.username, database: "querycraft_ios_table_actions", tlsMode: .required, remembersPassword: false, requiresPassword: true)
        let app = MobileApplicationModel(repository: TableActionLibrary(profile), passwords: TableActionPasswords())
        app.open(profile, suppliedPassword: configuration.password)
        let workspace = try #require(app.workspace)
        await workspace.browser.loadDatabases().value; await workspace.browser.loadObjects()?.value
        let target = object("action_navigation")
        app.destination = .table(target); await workspace.browser.loadTable()?.value
        workspace.tableActions.prepare(.rename, object: target)
        let rename = try #require(workspace.tableActions.request); rename.input = "action_navigation_renamed"
        workspace.tableActions.safetyLock.disable(); await workspace.tableActions.submit(rename)?.value
        #expect(rename.hasCompleted); #expect(rename.message == nil)
        let renamed = object("action_navigation_renamed")
        #expect(app.destination == .table(renamed)); #expect(workspace.browser.selectedObject == renamed)
        #expect(workspace.browser.snapshot?.preview.result.rows == [["1","navigation"]])
        workspace.tableActions.prepare(.drop, object: renamed)
        let drop = try #require(workspace.tableActions.request); drop.confirmation = renamed.name
        await workspace.tableActions.submit(drop)?.value
        #expect(drop.hasCompleted); #expect(drop.message == nil)
        #expect(app.destination == nil); #expect(workspace.browser.selectedObject == nil); #expect(workspace.browser.snapshot == nil)
        #expect(workspace.browser.catalog?.objects.contains { $0.name == renamed.name } == false)
    }

    @Test func clearPreservesAutoCounterAndFiresDeleteTriggerWhileTruncateResetsCounter() async throws {
        try await perform(.clear, "action_clear")
        #expect(try await read("SELECT COUNT(*) FROM action_clear").rows == [["0"]])
        #expect(try await read("SELECT id FROM action_audit ORDER BY id").rows == [["41"],["42"]])
        let afterDelete = try await write("INSERT INTO action_clear(name) VALUES ('after clear')")
        #expect(afterDelete.insertID == 43)
        try await perform(.truncate, "action_truncate")
        let afterTruncate = try await write("INSERT INTO action_truncate(name) VALUES ('after truncate')")
        #expect(afterTruncate.insertID == 1)
    }

    @Test func renameQuotesIdentifierAndPreservesActualDataAndDropRemovesObject() async throws {
        let renamed = "重命名`quoted;name"
        try await perform(.rename, "action_rename", input: renamed)
        let rows = try await read("SELECT name FROM " + MobileMySQLService.identifier(renamed))
        #expect(rows.rows == [["keep me"]])
        #expect(try await read("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='querycraft_ios_table_actions' AND TABLE_NAME='action_rename'").rows == [["0"]])
        try await perform(.drop, "action_drop")
        #expect(try await read("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='querycraft_ios_table_actions' AND TABLE_NAME='action_drop'").rows == [["0"]])
    }

    @Test func bothAutoIncrementActionsUseActualColumnAndServerAdjustsLowValues() async throws {
        let service = MobileTableActionService(), target = object("action_auto")
        let initial = try await service.inspect(object: target, configuration: config())
        #expect(initial.hasAutoIncrement)
        try await perform(.setAutoIncrement, "action_auto", input: " 700 ")
        #expect(try await write("INSERT INTO action_auto(name) VALUES ('set')").insertID == 700)
        try await perform(.resetAutoIncrement, "action_auto")
        #expect(try await write("INSERT INTO action_auto(name) VALUES ('reset nonempty')").insertID == 701)
        try await perform(.clear, "action_auto")
        try await perform(.resetAutoIncrement, "action_auto")
        #expect(try await write("INSERT INTO action_auto(name) VALUES ('reset empty')").insertID == 1)
        let noAuto = try await service.inspect(object: object("action_no_auto"), configuration: config())
        #expect(!noAuto.hasAutoIncrement); #expect(noAuto.nextAutoIncrement == nil)
        await #expect(throws: WorkspaceTableActionError.self) { try await perform(.setAutoIncrement, "action_no_auto", input: "9") }
    }

    @Test func viewMissingObjectPrivilegeAndForeignKeyFailuresDoNotDisableChecksOrInventSuccess() async throws {
        let service = MobileTableActionService()
        await #expect(throws: WorkspaceTableActionError.self) {
            _ = try await service.perform(action: .drop, object: object("action_view", kind: .view), input: "", configuration: config(), authorize: {})
        }
        await #expect(throws: WorkspaceTableActionError.self) { try await perform(.clear, "does_not_exist") }
        do {
            _ = try await service.perform(action: .clear, object: object("action_denied"), input: "", configuration: config(reader: true), authorize: {})
            Issue.record("Read-only credentials must not clear tables")
        } catch { #expect(error is CDatabaseClientError); #expect(!(error is MobileTableActionError)) }
        #expect(try await read("SELECT COUNT(*) FROM action_denied").rows == [["1"]])
        for action in [WorkspaceTableAction.truncate, .drop, .clear] {
            do { try await perform(action, "action_parent"); Issue.record("Foreign-key parent must be protected") }
            catch { #expect(error is CDatabaseClientError); #expect(!(error is MobileTableActionError)) }
        }
        #expect(try await read("SELECT COUNT(*) FROM action_parent").rows == [["1"]])
        #expect(try await read("SELECT COUNT(*) FROM action_child").rows == [["1"]])
    }

    @Test func serviceRechecksAuthorizationImmediatelyBeforeDDLAndNeverSendsAfterRelock() async throws {
        let gate = TableAuthorizationGate(), service = MobileTableActionService()
        await #expect(throws: WorkspaceDatabaseDataCellEditError.safetyLockEnabled) {
            _ = try await service.perform(action: .truncate, object: object("action_denied"), input: "", configuration: config()) {
                try await gate.authorize()
            }
        }
        #expect(try await read("SELECT COUNT(*) FROM action_denied").rows == [["1"]])
    }

    @Test func realAutoCommittedTruncateWithLostAcknowledgementIsUncertainAndCannotRepeat() async throws {
        let configuration = try config(), connection = TableLostAcknowledgement(configuration: try config())
        let service = MobileTableActionService(makeConnection: { _ in connection })
        let controller = MobileTableActionController(configuration: configuration, safetyLock: WorkspaceSafetyLock(), service: service)
        let context = UUID(); controller.contextID = { context }; controller.isCurrent = { $0.contextID == context }; controller.hasPendingChanges = { _ in false }
        let target = object("action_unknown")
        controller.prepare(.truncate, object: target)
        let draft = try #require(controller.request); draft.confirmation = target.name; controller.safetyLock.disable()
        await controller.submit(draft)?.value
        #expect(draft.needsVerification); #expect(!draft.hasCompleted)
        #expect(try await read("SELECT COUNT(*) FROM action_unknown").rows == [["0"]])
        #expect(controller.submit(draft) == nil); #expect(await connection.ddlCount == 1)
        controller.dismiss(); controller.prepare(.truncate, object: target)
        #expect(controller.request === draft); #expect(controller.submit(draft) == nil)
    }
}
private actor TableAuthorizationGate {
    private var count = 0
    func authorize() throws { count += 1; if count == 2 { throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled } }
}
private actor TableLostAcknowledgement: MobileMutationConnection {
    private let client: MobileMariaDBMutationConnection
    private(set) var ddlCount = 0
    init(configuration: MariaDBTransportConfiguration) { client = .init(client: MariaDBClient(configuration: configuration)) }
    func connect() async throws { try await client.connect() }
    func close() async { await client.close() }
    func query(_ sql: String, bindings: [WorkspaceDatabaseDataCell]) async throws -> CDatabaseQueryResult {
        let result = try await client.query(sql, bindings: bindings)
        if sql.hasPrefix("TRUNCATE TABLE") { ddlCount += 1; await client.close(); throw URLError(.networkConnectionLost) }
        return result
    }
}

@MainActor private final class TableActionLibrary: MobileLibraryPersisting {
    var state: MobileLibraryState
    init(_ profile: MobileConnectionProfile) { state = .init(profiles: [profile]) }
    func load() throws -> MobileLibraryState { state }
    func write(_ state: MobileLibraryState) throws { self.state = state }
}
@MainActor private final class TableActionPasswords: MobilePasswordStoring {
    func password(for id: UUID) throws -> String? { nil }
    func setPassword(_ password: String?, for id: UUID) throws {}
}
