import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceTableActionTests {
    private let selection = WorkspaceDatabaseObjectSelection(databaseName: "app`db", objectName: "order`items", kind: .table)

    @Test func mysqlOperationsQuoteNamesAndKeepClearDistinctFromTruncate() throws {
        let rename = try WorkspaceTableActionStatement.make(action: .rename, selection: selection, databaseType: .mysql, input: "new`name")
        #expect(rename.sql == "RENAME TABLE `app``db`.`order``items` TO `app``db`.`new``name`")
        #expect(rename.resultingSelection?.objectName == "new`name")
        let drop = try make(.drop)
        #expect(drop.sql == "DROP TABLE `app``db`.`order``items`")
        #expect(drop.resultingSelection == nil)
        let truncate = try make(.truncate)
        #expect(truncate.sql == "TRUNCATE TABLE `app``db`.`order``items`")
        #expect(truncate.kind == .ddl(.truncate))
        let clear = try make(.clear)
        #expect(clear.sql == "DELETE FROM `app``db`.`order``items`")
        #expect(clear.kind == .delete(hasWhereClause: false))
        #expect(try make(.resetAutoIncrement).sql == "ALTER TABLE `app``db`.`order``items` AUTO_INCREMENT = 1")
        #expect(try make(.setAutoIncrement, input: " 00042 ").sql == "ALTER TABLE `app``db`.`order``items` AUTO_INCREMENT = 42")
        #expect(try make(.setAutoIncrement, input: "18446744073709551615").sql.hasSuffix("18446744073709551615"))
    }

    @Test(arguments: ["", "0", "-1", "+1", "1.5", "1e5", "１", "2; DROP TABLE x", "18446744073709551616"])
    func rejectsInvalidNumericInput(_ value: String) {
        #expect(throws: WorkspaceTableActionError.self) { try make(.setAutoIncrement, input: value) }
    }

    @Test(arguments: ["", "  ", "order`items", "a\0b"])
    func rejectsInvalidRename(_ value: String) {
        #expect(throws: WorkspaceTableActionError.self) { try make(.rename, input: value) }
    }

    @Test func postgresqlUsesSchemaAndOwnedSequences() throws {
        let table = WorkspaceDatabaseObjectSelection(databaseName: "app", objectName: "audit.Order\"Items", kind: .table)
        let rename = try WorkspaceTableActionStatement.make(action: .rename, selection: table, databaseType: .postgresql, input: "new.name")
        #expect(rename.sql == "ALTER TABLE \"audit\".\"Order\"\"Items\" RENAME TO \"new.name\"")
        #expect(rename.resultingSelection?.objectName == "audit.new.name")
        let truncate = try WorkspaceTableActionStatement.make(action: .truncate, selection: table, databaseType: .postgresql, input: "")
        #expect(truncate.sql == "TRUNCATE TABLE \"audit\".\"Order\"\"Items\" CONTINUE IDENTITY RESTRICT")
        let sequence = try WorkspaceTableActionStatement.make(action: .setAutoIncrement, selection: table, databaseType: .postgresql, input: "123")
        #expect(sequence.sql.hasPrefix("DO E'"))
        #expect(sequence.sql.contains("pg_get_serial_sequence"))
        #expect(sequence.sql.contains("ACCESS EXCLUSIVE"))
        #expect(sequence.sql.contains("RESTART WITH 123"))
        #expect(sequence.sql.contains("RAISE EXCEPTION"))
        #expect(sequence.sql.contains("setval") == false)
        #expect(throws: WorkspaceTableActionError.self) {
            try WorkspaceTableActionStatement.make(action: .setAutoIncrement, selection: table, databaseType: .postgresql, input: "9223372036854775808")
        }
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka])
    func driverCapabilitiesAreExplicit(_ type: DatabaseType) throws {
        for action in WorkspaceTableAction.allCases {
            let supported = type == .mysql || type == .postgresql || (type == .doris && [.rename, .drop, .truncate].contains(action))
            #expect((action.unavailabilityReason(for: type) == nil) == supported)
            if !supported {
                #expect(throws: WorkspaceTableActionError.self) {
                    try WorkspaceTableActionStatement.make(action: action, selection: selection, databaseType: type, input: "next")
                }
            }
        }
    }

    @Test func dorisRenameUsesItsOwnSyntaxAndViewsAreRejected() throws {
        #expect(try WorkspaceTableActionStatement.make(action: .rename, selection: selection, databaseType: .doris, input: "new").sql
                == "ALTER TABLE `app``db`.`order``items` RENAME `new`")
        let view = WorkspaceDatabaseObjectSelection(databaseName: "app", objectName: "v", kind: .view)
        #expect(throws: WorkspaceTableActionError.self) {
            try WorkspaceTableActionStatement.make(action: .drop, selection: view, databaseType: .mysql, input: "")
        }
    }

    private func make(_ action: WorkspaceTableAction, input: String = "") throws -> WorkspaceTableActionStatement {
        try .make(action: action, selection: selection, databaseType: .mysql, input: input)
    }

    @MainActor @Test func safetyLockAndStaleWorkspaceBlockExecution() async throws {
        let profile = ConnectionProfile(id: UUID(), name: "Test", groupID: nil, host: "127.0.0.1", port: 3306,
            username: "root", defaultDatabase: "app`db", tlsMode: .disabled, storesCredential: false, createdAt: .now)
        let model = WorkspaceModel(profileID: profile.id, repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(), sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["app`db"]))
        _ = await model.connect()
        model.requestTableAction(.clear, for: selection)
        let request = try #require(model.tableActionRequest)
        let statement = try make(.clear)
        await #expect(throws: WorkspaceDatabaseTableMutationError.safetyLockEnabled) {
            try await model.performTableAction(request, statement: statement)
        }
        model.safetyLock.disable()
        let stale = WorkspaceTableActionRequest(action: .clear, selection: selection, workspaceID: UUID())
        await #expect(throws: WorkspaceDatabaseTableMutationError.contextChanged) {
            try await model.performTableAction(stale, statement: statement)
        }
        #expect(model.tableActionRevision == 0)
        _ = try await model.performTableAction(request, statement: statement)
        #expect(model.tableActionRevision == 1)
        model.requestTableAction(.drop, for: .init(databaseName: "other", objectName: "t", kind: .table))
        #expect(model.tableActionRequest?.id == request.id)
        _ = await model.connect()
        model.safetyLock.disable()
        await #expect(throws: WorkspaceDatabaseTableMutationError.contextChanged) {
            try await model.performTableAction(request, statement: statement)
        }
    }

    @MainActor @Test func mysqlRequiresAnActualAutoIncrementColumn() async throws {
        let profile = ConnectionProfile(id: UUID(), name: "Test", groupID: nil, host: "127.0.0.1", port: 3306,
            username: "root", defaultDatabase: selection.databaseName, tlsMode: .disabled, storesCredential: false, createdAt: .now)
        let model = WorkspaceModel(profileID: profile.id, repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(), sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: [selection.databaseName], detailsByObject: [selection: .init(columns: [], ddl: "CREATE TABLE t (id int)")]))
        _ = await model.connect()
        model.safetyLock.disable()
        model.requestTableAction(.resetAutoIncrement, for: selection)
        let request = try #require(model.tableActionRequest)
        await #expect(throws: WorkspaceTableActionError.self) {
            try await model.performTableAction(request, statement: make(.resetAutoIncrement))
        }
        #expect(model.tableActionRevision == 0)
    }
}
