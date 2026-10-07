import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
@Suite("Kafka workspace restoration", .timeLimit(.minutes(1)))
struct WorkspaceKafkaLifecycleTests {
    @Test("Topic deletion rechecks lock, drafts and connection after authentication",
          arguments: ["delete", "relock", "draft", "disconnect"])
    func topicDeletionAuthorization(_ action: String) async throws {
        let factory = KafkaLifecycleFactory(selection: selection)
        let model = makeModel(factory: factory, mechanism: .scramSHA512)
        _ = await model.connect()
        let count = await factory.sessionCount()
        await #expect(throws: WorkspaceKafkaTopicDeletionError.self) { try await model.deleteKafkaTopic(selection) }
        #expect(await factory.sessionCount() == count)
        model.safetyLock.disable()
        await factory.setNextConnectAction { @MainActor in
            switch action {
            case "relock": model.safetyLock.enable()
            case "draft": model.kafkaHasPendingChanges = { _ in true }
            case "disconnect": await model.disconnect()
            default: break
            }
        }
        if action == "delete" {
            try await model.deleteKafkaTopic(selection)
            guard case .loaded(let objects) = model.currentDatabase?.objectsState else {
                Issue.record("Successful deletion must keep the sidebar loaded")
                return
            }
            #expect(objects.allSatisfy { $0.name != selection.objectName })
            #expect(model.selectedObjectDataState.page == nil)
        } else {
            await #expect(throws: WorkspaceKafkaTopicDeletionError.self) { try await model.deleteKafkaTopic(selection) }
        }
        let admin = try #require(await factory.sessions.last)
        #expect(await admin.deletedTopics == (action == "delete" ? ["events"] : []))
        #expect(await admin.mechanismAtConnect == .scramSHA512)
        #expect(await admin.connected == false)
        await model.disconnect()
    }

    @Test("Topic config editing uses an authenticated isolated session and rechecks the safety lock", arguments: [false, true])
    func configurationSafetyLock(_ relock: Bool) async throws {
        let factory = KafkaLifecycleFactory(selection: selection)
        let model = makeModel(factory: factory, mechanism: .scramSHA512)
        _ = await model.connect()
        let request = WorkspaceKafkaTopicConfigurationRequest(topic: "events", changes: [
            .init(original: .init(name: "retention.ms", value: "1000", isDefault: false), value: "2000")
        ])
        let count = await factory.sessionCount()
        await #expect(throws: WorkspaceDatabaseDataCellEditError.self) { try await model.updateKafkaTopicConfiguration(request) }
        #expect(await factory.sessionCount() == count)
        model.safetyLock.disable()
        if relock {
            await factory.setNextConnectAction { @MainActor in model.safetyLock.enable() }
            await #expect(throws: WorkspaceDatabaseDataCellEditError.self) { try await model.updateKafkaTopicConfiguration(request) }
        } else {
            try await model.updateKafkaTopicConfiguration(request)
        }
        let admin = try #require(await factory.sessions.last)
        #expect(await admin.configurationWrites == (relock ? [] : [request]))
        #expect(await admin.mechanismAtConnect == .scramSHA512)
        #expect(await admin.connected == false)
        #expect(model.connectionState == .connected)
        await model.disconnect()
    }

    private let selection = WorkspaceDatabaseObjectSelection(databaseName: "Kafka", objectName: "events", kind: .table)

    @Test("Sending requires an unlocked workspace and uses a dedicated authenticated session")
    func produceRequiresSafetyUnlock() async throws {
        let factory = KafkaLifecycleFactory(selection: selection)
        let model = makeModel(factory: factory, mechanism: .scramSHA512)
        _ = await model.connect()
        let count = await factory.sessionCount()
        let request = WorkspaceKafkaProduceRequest(topic: "events", partition: 1, value: Data("test".utf8))
        await #expect(throws: WorkspaceDatabaseDataCellEditError.self) { try await model.produceKafkaMessage(request) }
        #expect(await factory.sessionCount() == count)
        model.safetyLock.disable()
        #expect(try await model.produceKafkaMessage(request) == .init(partition: 1, offset: 42))
        let producer = try #require(await factory.sessions.last)
        #expect(await producer.produced == [request])
        #expect(await producer.mechanismAtConnect == .scramSHA512)
        #expect(await producer.connected == false)
        #expect(model.connectionState == .connected)
        await model.disconnect()
    }

    @Test("Re-enabling the safety lock while the producer connects prevents dispatch")
    func relockBeforeProduce() async throws {
        let factory = KafkaLifecycleFactory(selection: selection)
        let model = makeModel(factory: factory)
        _ = await model.connect()
        model.safetyLock.disable()
        await factory.setNextConnectAction { @MainActor in model.safetyLock.enable() }
        await #expect(throws: WorkspaceDatabaseDataCellEditError.self) {
            try await model.produceKafkaMessage(.init(topic: "events", value: Data()))
        }
        let producer = try #require(await factory.sessions.last)
        #expect(await producer.produced.isEmpty)
        #expect(await producer.connected == false)
        await model.disconnect()
    }

    @Test("Restored Kafka topics load their first page without a view retry", arguments: [false, true])
    func restoredTopicLoadsAutomatically(empty: Bool) async throws {
        let factory = KafkaLifecycleFactory(selection: selection, empty: empty)
        let model = makeModel(factory: factory)
        // The detail view may request its page before the workspace has connected.
        await model.loadData(for: selection, offset: 0)
        _ = await model.connect()
        #expect(model.connectionState == .connected)
        #expect(model.selectedObject == selection)
        guard case .loaded(let page) = model.selectedObjectDataState else {
            Issue.record("Restoring a Kafka topic must finish loading automatically")
            await model.disconnect()
            return
        }
        #expect(page.rows.count == (empty ? 0 : 1))
        #expect(!page.hasNextPage)
        await model.disconnect()

        let reopened = makeModel(factory: KafkaLifecycleFactory(selection: selection, empty: empty))
        _ = await reopened.connect()
        #expect(reopened.selectedObjectDataState.page?.rows.count == (empty ? 0 : 1))
        #expect(!reopened.selectedObjectDataState.isFetching)
        await reopened.disconnect()
    }

    @Test("Failed restored data connection leaves loading and a retry succeeds")
    func failedDataConnectionRetries() async throws {
        let factory = KafkaLifecycleFactory(selection: selection, failFirstDataConnection: true)
        let model = makeModel(factory: factory)
        _ = await model.connect()
        guard case .failed = model.selectedObjectDataState else {
            Issue.record("Data connection failure must show a retryable error")
            await model.disconnect()
            return
        }
        #expect(!model.selectedObjectDataState.isFetching)
        await model.loadData(for: selection, offset: 0, force: true)
        #expect(model.selectedObjectDataState.page?.rows.count == 1)
        #expect(!model.selectedObjectDataState.isFetching)
        await model.disconnect()
    }

    @Test("Forced refresh opens a fresh Kafka reader and reapplies positioning")
    func refreshReappliesPosition() async {
        let factory = KafkaLifecycleFactory(selection: selection)
        let model = makeModel(factory: factory)
        _ = await model.connect()
        let request = WorkspaceKafkaReadRequest(partition: 1, start: .offset(42))
        model.setKafkaReadRequest(request, for: selection)
        await model.loadData(for: selection, offset: 0, force: true)
        #expect(await factory.requests() == [.init(), request])
        #expect(await factory.sessionCount() == 3)
        #expect(!model.selectedObjectDataState.isFetching)
        await model.disconnect()
    }

    @Test("Opening pending messages applies the group's next offset to a fresh reader")
    func pendingMessagesUseDedicatedPositionedReader() async throws {
        let factory = KafkaLifecycleFactory(selection: selection)
        let model = makeModel(factory: factory)
        _ = await model.connect()
        let consumerOffset = WorkspaceKafkaConsumerOffset(
            partition: 1, committedOffset: 42, beginningOffset: 10, endOffset: 100
        )
        let request = try #require(consumerOffset.pendingMessagesReadRequest)
        model.setKafkaReadRequest(request, for: selection)
        await model.loadData(for: selection, offset: 0, force: true)
        #expect(model.kafkaReadRequest(for: selection) == request)
        #expect(await factory.requests() == [.init(), .init(partition: 1, start: .offset(42))])
        #expect(await factory.sessionCount() == 3)
        #expect(model.selectedObjectDataState.page != nil)
        await model.disconnect()
    }

    @Test("Older plugins can still read messages and report unsupported member details")
    func legacyPluginMemberDetails() async {
        let model = makeModel(factory: KafkaLifecycleFactory(selection: selection))
        _ = await model.connect()
        await #expect(throws: WorkspaceKafkaConsumerGroupError.self) {
            try await model.fetchKafkaConsumerGroupDetails(groupID: "group", topic: "events")
        }
        #expect(model.selectedObjectDataState.page != nil)
        #expect(model.connectionState == .connected)
        await model.disconnect()
    }

    @Test("Unsupported scan preserves the previous page and clearing the filter restores browsing")
    func legacyScanFailurePreservesPage() async {
        let model = makeModel(factory: KafkaLifecycleFactory(selection: selection))
        _ = await model.connect()
        let original = model.selectedObjectDataState.page?.rows
        model.setKafkaScanRequest(.init(text: "message"), for: selection)
        await model.loadData(for: selection, offset: 0, force: true)
        #expect(model.kafkaScanProgress(for: selection)?.status == .failed)
        #expect(model.kafkaScanProgress(for: selection)?.error != nil)
        #expect(model.selectedObjectDataState.page?.rows == original)
        #expect(!model.selectedObjectDataState.isFetching)
        model.setKafkaScanRequest(nil, for: selection)
        await model.loadData(for: selection, offset: 0, force: true)
        #expect(model.kafkaScanProgress(for: selection) == nil)
        #expect(model.selectedObjectDataState.page?.rows.count == 1)
        await model.disconnect()
    }

    @Test("Offset is partition scoped and invalid read ranges are rejected")
    func readRequestValidation() {
        #expect(!WorkspaceKafkaReadRequest(start: .offset(1)).isValid)
        #expect(!WorkspaceKafkaReadRequest(partition: -1).isValid)
        #expect(!WorkspaceKafkaReadRequest(partition: 0, start: .offset(-1)).isValid)
        #expect(!WorkspaceKafkaReadRequest(start: .latest(0)).isValid)
        #expect(!WorkspaceKafkaReadRequest(start: .timestamp(-1)).isValid)
        #expect(WorkspaceKafkaReadRequest(partition: 0, start: .offset(0)).isValid)
        #expect(WorkspaceKafkaReadRequest(start: .latest(100)).isValid)
    }

    @Test("SCRAM is applied before connecting main, data, and refreshed sessions")
    func scramRestorationAndRefresh() async {
        let factory = KafkaLifecycleFactory(selection: selection)
        let model = makeModel(factory: factory, mechanism: .scramSHA512)
        _ = await model.connect()
        #expect(model.connectionState == .connected)
        await model.loadData(for: selection, offset: 0, force: true)
        #expect(await factory.mechanismsAtConnect() == [.scramSHA512, .scramSHA512, .scramSHA512])
        await model.disconnect()
    }

    @Test("Connection testing applies SCRAM and closes the session")
    func scramConnectionTesting() async throws {
        let session = KafkaLifecycleSession(selection: selection, empty: true, failsConnection: false)
        let registry = DatabaseDriverRegistry(drivers: [KafkaLifecycleDriver(session: session)])
        let tester = DatabaseDriverConnectionTester(registry: registry)
        let configuration = DatabaseConnectionConfiguration(databaseType: .kafka, host: "localhost", port: 9092,
            username: "reader", password: "secret", database: nil, tlsMode: .disabled)
        try await tester.test(configuration, kafkaSASLMechanism: .scramSHA256)
        #expect(await session.mechanismAtConnect == .scramSHA256)
        #expect(await session.connected == false)
    }

    private func makeModel(factory: KafkaLifecycleFactory, mechanism: KafkaSASLMechanism = .plain) -> WorkspaceModel {
        let profile = ConnectionProfile(id: UUID(), name: "Kafka", groupID: nil, databaseProduct: .kafka,
            host: "localhost", port: 9092, username: "reader", kafkaSASLMechanism: mechanism, defaultDatabase: nil,
            tlsMode: .disabled, storesCredential: false, createdAt: .now)
        let contextID = UUID()
        let context = WorkspaceDatabaseContextRestorationState(
            id: contextID, databaseName: "Kafka", selectedObject: selection,
            queryDocuments: [], selectedQueryDocumentID: nil,
            contentTabOrder: [.databaseObject(selection)], selectedContentTab: .databaseObject(selection),
            sidebarMode: .items
        )
        return WorkspaceModel(profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            restorationState: .init(id: UUID(), connectionProfileID: profile.id, databaseContexts: [context],
                selectedDatabaseContextID: contextID, windowFrame: nil, createdAt: .now, updatedAt: .now),
            credentialStore: InMemoryCredentialStore(), sessionFactory: factory)
    }
}

private actor KafkaLifecycleFactory: WorkspaceSessionFactory {
    let selection: WorkspaceDatabaseObjectSelection
    let empty: Bool
    let failFirstDataConnection: Bool
    var sessions: [KafkaLifecycleSession] = []
    var nextConnectAction: (@Sendable () async -> Void)?
    func setNextConnectAction(_ action: @escaping @Sendable () async -> Void) { nextConnectAction = action }
    init(selection: WorkspaceDatabaseObjectSelection, empty: Bool = false, failFirstDataConnection: Bool = false) {
        self.selection = selection
        self.empty = empty
        self.failFirstDataConnection = failFirstDataConnection
    }
    func makeSession(configuration: DatabaseConnectionConfiguration) async -> any WorkspaceSession {
        let session = KafkaLifecycleSession(selection: selection, empty: empty,
            failsConnection: failFirstDataConnection && sessions.count == 1, onConnect: nextConnectAction)
        nextConnectAction = nil
        sessions.append(session)
        return session
    }
    func makeSchemaCatalogSession(configuration: DatabaseConnectionConfiguration) async -> (any WorkspaceSession)? { nil }
    func sessionCount() -> Int { sessions.count }
    func mechanismsAtConnect() async -> [KafkaSASLMechanism?] {
        var result: [KafkaSASLMechanism?] = []
        for session in sessions { result.append(await session.mechanismAtConnect) }
        return result
    }
    func requests() async -> [WorkspaceKafkaReadRequest] {
        var result: [WorkspaceKafkaReadRequest] = []
        for session in sessions { result += await session.requests }
        return result
    }
}

private struct KafkaLifecycleDriver: DatabaseDriver {
    let databaseType = DatabaseType.kafka
    let session: KafkaLifecycleSession
    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession { session }
    func testConnection(configuration: DatabaseConnectionConfiguration) async throws {
        Issue.record("SCRAM testing must configure the session before connecting")
    }
}

private actor KafkaLifecycleSession: WorkspaceSession, WorkspaceKafkaReading, WorkspaceKafkaAuthenticationConfiguring, WorkspaceKafkaProducing, WorkspaceKafkaTopicConfigurationEditing, WorkspaceKafkaTopicDeleting {
    let selection: WorkspaceDatabaseObjectSelection
    let empty: Bool
    let failsConnection: Bool
    var connected = false
    var mechanism: KafkaSASLMechanism?
    var mechanismAtConnect: KafkaSASLMechanism?
    func configureSASL(_ mechanism: KafkaSASLMechanism) async throws {
        #expect(!connected)
        self.mechanism = mechanism
    }
    var requests: [WorkspaceKafkaReadRequest] = []
    var produced: [WorkspaceKafkaProduceRequest] = []
    var configurationWrites: [WorkspaceKafkaTopicConfigurationRequest] = []
    var deletedTopics: [String] = []
    func deleteTopic(name: String) async throws { deletedTopics.append(name) }
    func updateTopicConfiguration(_ request: WorkspaceKafkaTopicConfigurationRequest) async throws {
        configurationWrites.append(request)
    }
    let onConnect: (@Sendable () async -> Void)?
    func produce(_ request: WorkspaceKafkaProduceRequest) async throws -> WorkspaceKafkaProduceReceipt {
        produced.append(request)
        return .init(partition: request.partition ?? 0, offset: 42)
    }
    init(selection: WorkspaceDatabaseObjectSelection, empty: Bool, failsConnection: Bool,
         onConnect: (@Sendable () async -> Void)? = nil) {
        self.selection = selection; self.empty = empty; self.failsConnection = failsConnection
        self.onConnect = onConnect
    }
    func connect() async throws {
        mechanismAtConnect = mechanism
        if failsConnection { throw WorkspaceSessionError.notConnected }
        connected = true
        await onConnect?()
    }
    func isConnected() async -> Bool { connected }
    func close() async { connected = false }
    func fetchDatabases() async throws -> [String] { ["Kafka"] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [selection.object] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails {
        .init(columns: [], ddl: "")
    }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int {
        Issue.record("Kafka first page must not start a blocking count scan")
        return 0
    }
    func prepareReading(topic: String, request: WorkspaceKafkaReadRequest) async throws { requests.append(request) }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int,
                       sort: WorkspaceDatabaseDataSort,
                       onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult {
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "value")]
        if !empty {
            await onBatch(.init(columns: columns, rows: [.init(id: 0, values: [.text("message")])]))
        }
        return .init(columns: columns, hasNextPage: false)
    }
}
