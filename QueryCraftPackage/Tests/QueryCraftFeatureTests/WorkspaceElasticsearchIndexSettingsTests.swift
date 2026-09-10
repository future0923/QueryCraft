import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceElasticsearchIndexSettingsTests {
    @Test func fullSettingsPreserveUnknownArraysNumbersEscapesAndDefaults() async throws {
        let body = #"{"logs":{"settings":{"index.uuid":"uuid-logs","index.number_of_replicas":"0","index.analysis.filter.synonyms.synonyms":["a,b","c,d"],"future.setting":18446744073709551615,"escaped":"a\"b\\c"},"defaults":{"index.refresh_interval":"1s","unknown.default":["x","y"]}}}"#
        let worker = WorkspaceIndexSettingsWorker()
        let snapshot = try await worker.load(indexSelection("logs")) { request in
            request.path.contains("_settings") ? indexDeletionResponse(200, body) : indexDeletionResponse(200)
        }
        #expect(snapshot.rawJSON == Data(body.utf8))
        #expect(try await worker.rawSettingsText(snapshot) == body)
        let source = try await worker.consoleSource(snapshot)
        #expect(source == "PUT /logs/_settings\n{\n  \"index\": {}\n}")
        #expect(!source.contains("uuid") && !source.contains("defaults"))
    }

    @Test(arguments: [WorkspaceDatabaseObjectKind.elasticsearchIndex, .elasticsearchAlias, .elasticsearchDataStream])
    func consoleUsesOneEncodedTargetAndSafeResourceMethod(kind: WorkspaceDatabaseObjectKind) async throws {
        let name = "logs%&测试"
        let snapshot = WorkspaceIndexSettingsSnapshot(selection: .init(databaseName: "Elasticsearch", objectName: name, kind: kind),
            indices: [.init(name: name, settings: ["index.uuid": "uuid"], defaults: [:])],
            documentCount: nil, storeBytes: nil, health: nil, warnings: [], rawJSON: Data("{}".utf8))
        let source = try await WorkspaceIndexSettingsWorker().consoleSource(snapshot)
        let path = try WorkspaceElasticsearchIndexName.encodedPath(name)
        #expect(source.hasPrefix((kind == .elasticsearchIndex ? "PUT " : "GET ") + path + "/_settings"))
        #expect(path.removingPercentEncoding == "/" + name)
        if kind != .elasticsearchIndex { #expect(!source.contains("PUT") && source.hasSuffix("include_defaults=true")) }
    }

    @Test @MainActor func openingSettingsOnlyCreatesSourceAndRetainsPendingDraft() async throws {
        let (workspace, session) = await indexSettingsFixture()
        let editor = WorkspaceElasticsearchIndexInspectorModel()
        var sources: [String] = []
        workspace.openElasticsearchRequestSource = { sources.append($0) }
        editor.openSettingsRequest(workspace: workspace)
        #expect(sources.isEmpty && !editor.canOpenSettingsRequest)
        await editor.load { try await settingsSnapshot() }
        workspace.safetyLock.enable()
        editor.openSettingsRequest(workspace: workspace)
        #expect(sources == ["PUT /logs/_settings\n{\n  \"index\": {}\n}"])
        #expect(workspace.safetyLock.isEnabled && !editor.hasChanges)
        workspace.safetyLock.disable()
        editor.requestEdit(workspace: workspace)
        editor.update(replicas: "0", interval: "5s", workspace: workspace)
        await waitForSettings { editor.prepared != nil }
        let prepared = try #require(editor.prepared)
        let originalRaw = editor.rawSettingsText
        editor.openSettingsRequest(workspace: workspace)
        #expect(sources.last == "PUT /logs/_settings\n" + String(decoding: prepared.request.body ?? Data(), as: UTF8.self))
        #expect(editor.hasChanges && editor.prepared == prepared && editor.rawSettingsText == originalRaw)
        editor.update(replicas: "0", interval: "invalid", workspace: workspace)
        #expect(!editor.canOpenSettingsRequest)
        editor.openSettingsRequest(workspace: workspace)
        #expect(sources.count == 2)
        editor.discard()
        editor.openSettingsRequest(workspace: workspace)
        #expect(sources.last == sources.first && !editor.hasChanges)
        #expect(await session.requests.isEmpty) // Neither preview nor opening sends REST traffic.
        await workspace.disconnect()
    }

    @Test func defaultsRemainDistinctAndOnlyChangedSettingsAreSent() async throws {
        let worker = WorkspaceIndexSettingsWorker()
        let snapshot = try await settingsSnapshot()
        #expect(snapshot.editableIndex?.settings["index.refresh_interval"] == nil)
        #expect(snapshot.editableIndex?.effective("index.refresh_interval") == "1s")
        let prepared = try await worker.prepare(snapshot, replicas: "2", interval: "1s")
        #expect(prepared.request.method == .put && prepared.request.path == "/logs/_settings")
        let body = try #require(prepared.request.body)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: [String: Int]])
        #expect(root == ["index": ["number_of_replicas": 2]])
        try await worker.validatePrepared(prepared)
        await #expect(throws: WorkspaceIndexSettingsError.self) {
            try await worker.validatePrepared(.init(baseline: snapshot, changes: prepared.changes,
                request: .init(method: .delete, path: "/logs")))
        }
    }

    @Test(arguments: ["-1", "0", "500ms", "2s", "1m", "1h", "1d"])
    func validIntervals(interval: String) async throws {
        _ = try await WorkspaceIndexSettingsWorker().prepare(settingsSnapshot(), replicas: "0", interval: interval)
    }
    @Test(arguments: ["", "-2", "1.5s", "nan", "1", " 1s", "1s\n"])
    func invalidIntervals(interval: String) async throws {
        let snapshot = try await settingsSnapshot()
        await #expect(throws: WorkspaceIndexSettingsError.self) {
            try await WorkspaceIndexSettingsWorker().prepare(snapshot, replicas: "0", interval: interval)
        }
    }
    @Test(arguments: ["", "-1", "true", "1.5", "999999999999999999999999", "２"])
    func invalidReplicas(replicas: String) async throws {
        let snapshot = try await settingsSnapshot()
        await #expect(throws: WorkspaceIndexSettingsError.self) {
            try await WorkspaceIndexSettingsWorker().prepare(snapshot, replicas: replicas, interval: "1s")
        }
    }
    @Test(arguments: [WorkspaceDatabaseObjectKind.elasticsearchAlias, .elasticsearchDataStream])
    func aggregateTargetsAreNeverEditable(kind: WorkspaceDatabaseObjectKind) async throws {
        let snapshot = try await settingsSnapshot(kind: kind)
        #expect(snapshot.editableIndex == nil)
        await #expect(throws: WorkspaceIndexSettingsError.self) {
            try await WorkspaceIndexSettingsWorker().prepare(snapshot, replicas: "1", interval: "5s")
        }
    }
    @Test func partialPermissionFailureKeepsSettingsAndCount() async throws {
        let snapshot = try await WorkspaceIndexSettingsWorker().load(indexSelection("logs")) { request in
            if request.path.contains("_settings") { return settingsResponse() }
            if request.path.contains("_count") { return indexDeletionResponse(200, #"{"count":2}"#) }
            return indexDeletionResponse(403, #"{"error":"denied"}"#)
        }
        #expect(snapshot.documentCount == 2 && snapshot.editableIndex != nil)
        #expect(snapshot.storeBytes == nil && snapshot.health == nil && snapshot.warnings.count == 2)
    }
    @Test func preflightChecksIdentityAndOnlyEditedKeys() async throws {
        let worker = WorkspaceIndexSettingsWorker()
        let snapshot = try await settingsSnapshot()
        let prepared = try await worker.prepare(snapshot, replicas: "2", interval: "1s")
        try await worker.validateBaseline(prepared, response: settingsResponse(interval: "5s"))
        for response in [settingsResponse(uuid: "recreated"), settingsResponse(replicas: "3")] {
            await #expect(throws: WorkspaceIndexSettingsError.self) { try await worker.validateBaseline(prepared, response: response) }
        }
        #expect(try await worker.matches(prepared, response: settingsResponse(replicas: "2")))
        #expect(try await !worker.matches(prepared, response: settingsResponse(replicas: "2", uuid: "recreated")))
    }
    @Test @MainActor func staleLoadNeverOverwritesCurrentSnapshot() async throws {
        let editor = WorkspaceElasticsearchIndexInspectorModel()
        let delayed = SettingsReadBarrier()
        let first = Task { await editor.load { await delayed.wait(); return try await settingsSnapshot(replicas: "7") } }
        await delayed.waitUntilStarted()
        let latest = try await settingsSnapshot(replicas: "0")
        await editor.load { latest }
        await delayed.release()
        await first.value
        #expect(editor.replicas == "0" && !editor.isLoading)
        #expect(editor.rawSettingsText == String(decoding: latest.rawJSON, as: UTF8.self))
    }
    @Test @MainActor func cancellationPreservesLoadedPanel() async throws {
        let editor = WorkspaceElasticsearchIndexInspectorModel()
        await editor.load { try await settingsSnapshot() }
        let baseline = editor.snapshot
        let task = Task {
            await editor.load { withUnsafeCurrentTask { $0?.cancel() }; return try await settingsSnapshot(replicas: "7") }
        }
        await task.value
        #expect(editor.snapshot == baseline && !editor.isLoading)
    }
    @Test @MainActor func editingUsesLockAndToolbarDraftSurvivesInvalidInputAndDiscard() async throws {
        let (workspace, _) = await indexSettingsFixture()
        let editor = WorkspaceElasticsearchIndexInspectorModel()
        await editor.load { try await settingsSnapshot() }
        workspace.safetyLock.enable()
        editor.requestEdit(workspace: workspace)
        #expect(editor.showsUnlockConfirmation && !editor.isEditing)
        editor.cancelUnlock()
        #expect(!editor.isEditing && !editor.hasChanges)
        editor.requestEdit(workspace: workspace)
        editor.confirmUnlock(workspace: workspace)
        editor.update(replicas: "2", interval: "bad", workspace: workspace)
        await waitForSettings { editor.errorMessage != nil }
        #expect(editor.hasChanges && !editor.canCommit && editor.interval == "bad")
        editor.discard()
        #expect(!editor.hasChanges && !editor.isEditing && editor.interval == "1s" && editor.replicas == "0")
        workspace.elasticsearchHasPendingChanges = { true }
        editor.requestEdit(workspace: workspace)
        #expect(!editor.isEditing && editor.errorMessage != nil)
        // Pending settings never change the independent REST console's authorization.
        _ = try await workspace.executeElasticsearchRequest(.init(method: .post, path: "/logs/_refresh"))
        await workspace.disconnect()
    }
    @Test @MainActor func lockChangedDuringPreflightPreventsWrite() async throws {
        let (workspace, session) = await indexSettingsFixture()
        workspace.safetyLock.disable()
        await session.setReadHook { workspace.safetyLock.enable() }
        let prepared = try await WorkspaceIndexSettingsWorker().prepare(settingsSnapshot(), replicas: "2", interval: "1s")
        await #expect(throws: WorkspaceIndexSettingsNotSentError.self) { try await workspace.commitElasticsearchIndexSettings(prepared) }
        #expect(await session.requests.allSatisfy { $0.method == .get })
        await workspace.disconnect()
    }
    @Test(arguments: ["success", "conflict", "denied", "ack-timeout", "uncertain", "cancel", "complete-cancel"])
    @MainActor func commitPreservesDraftOrConfirmsExactPreparedRequest(mode: String) async throws {
        let (workspace, session) = await indexSettingsFixture(mode: mode)
        workspace.safetyLock.disable()
        let editor = WorkspaceElasticsearchIndexInspectorModel()
        await editor.load { try await settingsSnapshot() }
        editor.requestEdit(workspace: workspace)
        editor.update(replicas: "2", interval: "5s", workspace: workspace)
        await waitForSettings { editor.prepared != nil }
        let prepared = try #require(editor.prepared)
        editor.requestCommit(workspace: workspace)
        editor.requestCommit(workspace: workspace)
        editor.discard() // Must not discard an in-flight write.
        #expect(editor.hasChanges)
        await waitForSettings { !editor.isCommitting }
        let writes = await session.requests.filter { $0.method == .put }
        #expect(writes == (mode == "conflict" ? [] : [prepared.request]))
        let success = ["success", "ack-timeout", "complete-cancel"].contains(mode)
        #expect(editor.hasChanges == !success)
        #expect(editor.isBlocked == ["conflict", "uncertain", "cancel"].contains(mode))
        if !success { #expect(editor.replicas == "2" && editor.interval == "5s" && editor.errorMessage != nil) }
        await workspace.disconnect()
    }
    @Test func bilingualValidationErrors() {
        for error in [WorkspaceIndexSettingsError.unavailable, .invalidReplicas, .invalidInterval, .conflict, .uncertain] {
            #expect(error.message(copy: AppCopy(language: .english)) != error.message(copy: AppCopy(language: .simplifiedChinese)))
        }
    }
}

func settingsResponse(replicas: String = "0", interval: String? = nil, uuid: String = "uuid-logs") -> WorkspaceRequestExecutionResult {
    var settings = ["index.uuid": uuid, "index.number_of_shards": "1", "index.number_of_replicas": replicas]
    settings["index.refresh_interval"] = interval
    let body = try! JSONSerialization.data(withJSONObject: ["logs": ["settings": settings, "defaults": ["index.refresh_interval": "1s", "index.blocks.write": "false"]]])
    return .init(statusCode: 200, contentType: "application/json", body: body)
}
func settingsSnapshot(replicas: String = "0", kind: WorkspaceDatabaseObjectKind = .elasticsearchIndex) async throws -> WorkspaceIndexSettingsSnapshot {
    .init(selection: .init(databaseName: "Elasticsearch", objectName: "logs", kind: kind),
        indices: try await WorkspaceIndexSettingsWorker().parseSettings(settingsResponse(replicas: replicas)),
        documentCount: 2, storeBytes: 1234, health: "green", warnings: [], rawJSON: settingsResponse(replicas: replicas).body)
}
@MainActor func waitForSettings(_ done: () -> Bool) async {
    for _ in 0..<2000 {
        if done() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Settings operation did not complete")
}
private actor SettingsReadBarrier {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private func indexSettingsFixture(mode: String = "success") async -> (WorkspaceModel, IndexSettingsTestSession) {
    let session = IndexSettingsTestSession(mode: mode)
    let profile = ConnectionProfile(id: UUID(), name: "Index settings test", groupID: nil,
        databaseProduct: .elasticsearch, host: "127.0.0.1", port: 9200, username: "", defaultDatabase: nil,
        tlsMode: .disabled, storesCredential: false, createdAt: .now)
    let workspace = WorkspaceModel(profileID: profile.id, repository: InMemoryConnectionProfileRepository(profiles: [profile]),
        credentialStore: InMemoryCredentialStore(), sessionFactory: IndexSettingsTestFactory(session: session))
    _ = await workspace.connect()
    return (workspace, session)
}
private struct IndexSettingsTestFactory: WorkspaceSessionFactory {
    let session: IndexSettingsTestSession
    func makeSession(configuration: DatabaseConnectionConfiguration) async -> any WorkspaceSession { session }
}
private actor IndexSettingsTestSession: WorkspaceSession, WorkspaceRequestExecutingSession {
    let mode: String
    var didWrite = false
    private(set) var requests: [WorkspaceRequest] = []
    private var readHook: (@MainActor @Sendable () -> Void)?
    init(mode: String) { self.mode = mode }
    func setReadHook(_ hook: @escaping @MainActor @Sendable () -> Void) { readHook = hook }
    func connect() async throws {}
    func close() async {}
    func fetchDatabases() async throws -> [String] { ["Elasticsearch"] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { throw WorkspaceSessionError.queryUnavailable }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort,
                      onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult { throw WorkspaceSessionError.queryUnavailable }
    func executeRequest(_ request: WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult { try await executeRequest(request, policy: .readOnly) }
    func executeRequest(_ request: WorkspaceRequest, policy: WorkspaceRequestExecutionPolicy) async throws -> WorkspaceRequestExecutionResult {
        try WorkspaceRequestClassifier.validate(request, policy: policy)
        requests.append(request)
        if request.method == .put {
            didWrite = true
            switch mode {
            case "denied": return indexDeletionResponse(403, #"{"error":"denied"}"#)
            case "ack-timeout", "uncertain": return indexDeletionResponse(200, #"{"acknowledged":false}"#)
            case "cancel": throw CancellationError()
            case "complete-cancel": withUnsafeCurrentTask { $0?.cancel() }
            default: break
            }
            return indexDeletionResponse(200, #"{"acknowledged":true}"#)
        }
        if request.path.contains("_settings") {
            await readHook?()
            if mode == "conflict" { return settingsResponse(replicas: "8") }
            if didWrite && mode == "ack-timeout" { return settingsResponse(replicas: "2", interval: "5s") }
            return settingsResponse()
        }
        return indexDeletionResponse(200, #"{"acknowledged":true}"#)
    }
}
