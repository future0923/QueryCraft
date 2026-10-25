import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor struct MobileWorkspaceSafetyTests {
    @Test func durableWriteMarkerSurvivesRestartAndExplicitVerificationPersists() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = MobileDriverSupportTests.profile(.mysql), repository = MobileWorkspaceRepository(directory: directory)
        let first = MobileDatabaseWorkspace(profile: profile, password: nil, service: MobileMySQLService(), workspaceRepository: repository)
        first.query.sql = "UPDATE sample SET value='unverified' WHERE id=1"
        #expect(first.query.persistWriteBoundary(true))
        let restored = MobileDatabaseWorkspace(profile: profile, password: nil, service: MobileMySQLService(), workspaceRepository: repository)
        #expect(restored.query.writeOutcomeUncertain); #expect(restored.hasPendingChanges)
        #expect(restored.query.execute() == nil)
        restored.query.acknowledgeUncertainOutcome()
        #expect(!restored.query.writeOutcomeUncertain)
        let checked = MobileDatabaseWorkspace(profile: profile, password: nil, service: MobileMySQLService(), workspaceRepository: repository)
        #expect(!checked.query.writeOutcomeUncertain)
    }
    @Test func interruptedTransferHistoryFencesRestartAndVerificationIsDurable() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "history.json")
        let run = TransferRunRecord(id: UUID(), name: "interrupted", sourceLabel: "source", targetLabel: "target", createdAt: .now, status: .running, items: [])
        try JSONEncoder().encode([run]).write(to: url)
        let manager = DataTransferManager(historyURL: url)
        let model = MobileTransferModel(profiles: [], manager: manager, library: .init(url: directory.appending(path: "tasks.json")), resolve: { _, _ in throw MobileQueryError.invalidConnection })
        #expect(model.hasUnverifiedRuns); #expect(model.blocksWrites); #expect(!manager.hasActiveRuns)
        manager.acknowledgeOutcome(run.id)
        #expect(!model.blocksWrites)
        #expect(DataTransferManager(historyURL: url).runs.first?.verifiedAt != nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_TRANSFER_MYSQL_PORT"] != nil))
    func documentsHaveIndependentSessionsAndRollbackBeforeClosing() async throws {
        let connection = try MobileTransferIntegrationTests.connection(.mysql)
        var profile = MobileDriverSupportTests.profile(.mysql)
        profile.port = connection.configuration.port; profile.username = "root"; profile.database = connection.endpoint.database
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = MobileDatabaseWorkspace(profile: profile, password: connection.configuration.password, service: MobileMySQLService(), workspaceRepository: MobileWorkspaceRepository(directory: directory))
        let first = try #require(workspace.activeDocument)
        first.query.sql = "BEGIN"; await first.query.executeAll()?.value
        #expect(first.query.transactionState == .inTransaction)
        let second = try #require(workspace.newDocument())
        second.query.sql = "SELECT 42 AS answer"; await second.query.executeAll()?.value
        #expect(second.query.result?.rows == [["42"]]); #expect(second.query.errorMessage == nil)
        second.query.sql = "BEGIN"; await second.query.executeAll()?.value
        #expect(second.query.transactionState == .inTransaction)
        #expect(!workspace.closeDocument(first.id, discarding: first.closeSnapshot))
        #expect(await workspace.rollbackAndCloseDocument(first.id, discarding: first.closeSnapshot))
        #expect(second.query.transactionState == .inTransaction)
        await second.query.transaction(.rollback)?.value
        #expect(second.query.transactionState == .autoCommit)
        workspace.selectDocument(second.id)
        second.query.sql = "SELECT 43 AS answer"
        await second.query.executeAll()?.value
        #expect(second.query.result?.rows == [["43"]])
        for document in workspace.documents { await document.query.disconnectSQL()?.value }
        workspace.cancelAll()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_TRANSFER_MYSQL_PORT"] != nil))
    func postgresDocumentsKeepTheirOwnDatabaseAndSchemaCatalog() async throws {
        let connection = try MobileTransferIntegrationTests.connection(.postgresql)
        var profile = MobileDriverSupportTests.profile(.postgresql)
        profile.port = connection.configuration.port; profile.username = "postgres"; profile.database = connection.endpoint.database; profile.schemaName = "workspace_source"
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = MobileDatabaseWorkspace(profile: profile, password: connection.configuration.password, service: MobileMySQLService(), workspaceRepository: MobileWorkspaceRepository(directory: directory))
        let first = try #require(workspace.activeDocument)
        await first.query.refreshSchemas()?.value
        #expect(first.query.availableSchemas?.contains("workspace_source") == true)
        let second = try #require(workspace.newDocument())
        second.query.database = "postgres"; second.query.schemaName = "workspace_source"
        await second.query.refreshSchemas()?.value
        #expect(second.query.schemaName == "public")
        #expect(second.query.availableSchemas?.contains("workspace_source") == false)
        #expect(first.query.schemaName == "workspace_source")
        #expect(first.query.database == "querycraft_ios_pg")
        #expect(first.query.availableSchemas?.contains("workspace_source") == true)
        workspace.cancelAll()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_TRANSFER_MYSQL_PORT"] != nil))
    func queuedTransferCredentialsAndProfileReloadPreserveTaskDraftAndSelection() async throws {
        let source = try MobileTransferIntegrationTests.connection(.mysql), target = try MobileTransferIntegrationTests.connection(.postgresql)
        var sourceProfile = MobileDriverSupportTests.profile(.mysql), targetProfile = MobileDriverSupportTests.profile(.postgresql)
        sourceProfile = MobileConnectionProfile(id: try #require(source.endpoint.profileID), name: sourceProfile.name, host: source.configuration.host, port: source.configuration.port, username: source.configuration.username, database: source.endpoint.database, tlsMode: .disabled, remembersPassword: false, requiresPassword: true, driver: .mysql)
        targetProfile = MobileConnectionProfile(id: try #require(target.endpoint.profileID), name: targetProfile.name, host: target.configuration.host, port: target.configuration.port, username: target.configuration.username, database: target.endpoint.database, tlsMode: .disabled, remembersPassword: false, requiresPassword: true, driver: .postgresql, schemaName: target.endpoint.schema)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MobileTransferModel(profiles: [sourceProfile, targetProfile], manager: .init(historyURL: directory.appending(path: "runs.json")), library: .init(url: directory.appending(path: "tasks.json")), resolve: { id, secret in
            guard let secret else { throw MobileTransferCredentialError.passwordRequired(id) }
            let connection = id == source.endpoint.profileID ? source : target
            let configuration = connection.configuration
            return .init(databaseType: configuration.databaseType, host: configuration.host, port: configuration.port, username: configuration.username, password: secret, database: configuration.database, tlsMode: configuration.tlsMode)
        })
        let sample = try #require(try await DataTransferCatalog().objects(source).first { $0.name == "sample" })
        model.configuration.source = source.endpoint; model.configuration.target = target.endpoint
        model.configuration.objects = [sample]; model.taskName = "unsaved draft"; model.configuration.batchSize = 321
        await model.reload(.source, preserveSelection: true)?.value
        await model.reload(.target)?.value
        #expect(model.credentialRequest?.id == sourceProfile.id)
        model.supplyPassword(try #require(source.configuration.password))
        await model.reload(.source, preserveSelection: true)?.value
        model.presentNextCredential()
        #expect(model.credentialRequest?.id == targetProfile.id)
        model.supplyPassword(try #require(target.configuration.password))
        await model.reload(.target)?.value
        #expect(model.configuration.objects == [sample]); #expect(model.sourceLoaded)
        sourceProfile.name = "renamed source"
        model.updateProfiles([sourceProfile, targetProfile], force: true)
        #expect(model.taskName == "unsaved draft"); #expect(model.configuration.batchSize == 321)
        #expect(model.configuration.objects == [sample]); #expect(!model.sourceLoaded)
        #expect(model.configuration.source == source.endpoint); #expect(model.configuration.target == target.endpoint)
        model.background(true)
    }

    @Test func unverifiedDocumentFencesOtherDocumentWritesButAllowsReadsAndRollback() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = MobileDriverSupportTests.profile(.mysql), repository = MobileWorkspaceRepository(directory: directory)
        let original = MobileDatabaseWorkspace(profile: profile, password: nil, service: MobileMySQLService(), workspaceRepository: repository)
        #expect(original.query.persistWriteBoundary(true))
        let restored = MobileDatabaseWorkspace(profile: profile, password: nil, service: MobileMySQLService(), workspaceRepository: repository)
        let uncertain = try #require(restored.activeDocument), other = try #require(restored.newDocument())
        restored.browser.safetyLock.disable()
        #expect(uncertain.query.writeOutcomeUncertain)
        #expect(other.query.allowsSQLExecution()); #expect(other.query.allowsSQLStatement(.read))
        #expect(other.query.allowsSQLStatement(.transaction(.begin)))
        #expect(other.query.allowsSQLStatement(.transaction(.rollback)))
        #expect(!other.query.allowsSQLStatement(.transaction(.commit)))
        #expect(!other.query.allowsSQLStatement(.insert))
        #expect(!other.query.allowsSQLStatement(.update(hasWhereClause: true)))
        #expect(!other.query.allowsDataMutation())
        uncertain.query.acknowledgeUncertainOutcome()
        #expect(!restored.hasUnverifiedQueryWrites)
        #expect(other.query.allowsSQLStatement(.transaction(.commit)))
        #expect(other.query.allowsSQLStatement(.insert)); #expect(other.query.allowsDataMutation())
        original.cancelAll(); restored.cancelAll()
    }
    @Test func schemaReadsRejectLateContextAndKeepCatalogOnFailedRefresh() async throws {
        let service = WorkspaceSchemaGate(), model = MobileQueryModel(metadataService: service)
        model.driver = .postgresql; model.database = "first"
        let first = try #require(model.refreshSchemas()); try await waitForSchema(service, database: "first")
        model.database = "second"
        let second = try #require(model.refreshSchemas()); try await waitForSchema(service, database: "second")
        await service.complete("second", schemas: ["public", "second_schema"]); await second.value
        await service.complete("first", schemas: ["first_schema"]); await first.value
        #expect(model.database == "second"); #expect(model.schemaName == "public")
        #expect(model.availableSchemas == ["public", "second_schema"])
        let refresh = try #require(model.refreshSchemas(force: true)); try await waitForSchema(service, database: "second")
        #expect(model.availableSchemas == ["public", "second_schema"]); #expect(model.isLoadingSchemas)
        await service.fail("second"); await refresh.value
        #expect(model.availableSchemas == ["public", "second_schema"]); #expect(model.schemaError != nil)
        let retry = try #require(model.refreshSchemas(force: true)); try await waitForSchema(service, database: "second")
        await service.complete("second", schemas: ["public", "retry_schema"]); await retry.value
        #expect(model.schemaError == nil); #expect(model.availableSchemas == ["public", "retry_schema"])
    }
    private func waitForSchema(_ service: WorkspaceSchemaGate, database: String) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await service.isWaiting(database)), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await service.isWaiting(database))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_TRANSFER_MYSQL_PORT"] != nil))
    func transferNamespaceSwitchInvalidatesPreviousObjectsBeforeAsyncRead() async throws {
        let source = try MobileTransferIntegrationTests.connection(.mysql)
        var profile = MobileDriverSupportTests.profile(.mysql)
        profile.port = source.configuration.port; profile.username = "root"; profile.database = source.endpoint.database
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MobileTransferModel(profiles: [profile], manager: .init(historyURL: directory.appending(path: "runs.json")), library: .init(url: directory.appending(path: "tasks.json")), resolve: { _, _ in source.configuration })
        model.chooseProfile(profile.id, side: .source); await model.reload(.source)?.value
        let object = try #require(model.objects.first { $0.name == "sample" })
        model.select(object, enabled: true); model.configuration.tableFilters[object.name] = "id > 0"
        model.chooseDatabase("new_namespace", side: .source)
        #expect(model.objects.isEmpty); #expect(!model.sourceLoaded)
        #expect(model.configuration.objects.isEmpty); #expect(model.configuration.tableFilters.isEmpty)
        #expect(!model.canPrepare)
        model.background(true)
    }

}

private actor WorkspaceSchemaGate: MobileSQLServicing {
    private var waiting: [String: CheckedContinuation<[String], any Error>] = [:]
    func schemas(configuration: MobileSQLConfiguration, database: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { waiting[database] = $0 }
    }
    func isWaiting(_ database: String) -> Bool { waiting[database] != nil }
    func complete(_ database: String, schemas: [String]) { waiting.removeValue(forKey: database)?.resume(returning: schemas) }
    func fail(_ database: String) { waiting.removeValue(forKey: database)?.resume(throwing: CocoaError(.fileReadUnknown)) }
    func databases(configuration: MobileSQLConfiguration) async throws -> [String] { [] }
    func objects(configuration: MobileSQLConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog { .init(objects: [], hasMore: false) }
    func columns(configuration: MobileSQLConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] { [] }
    func page(configuration: MobileSQLConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot { throw CocoaError(.featureUnsupported) }
}
