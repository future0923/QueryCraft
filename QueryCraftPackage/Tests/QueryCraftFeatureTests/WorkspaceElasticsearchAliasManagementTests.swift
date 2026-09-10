import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceElasticsearchAliasManagementTests {
    @Test func readPathsUseResourceKindAndEncodeUnicode() async throws {
        let worker = WorkspaceElasticsearchAliasWorker()
        let index = WorkspaceDatabaseObjectSelection(databaseName: "Elasticsearch",
            objectName: "logs%&测试", kind: .elasticsearchIndex)
        let alias = WorkspaceDatabaseObjectSelection(databaseName: "Elasticsearch",
            objectName: "current%&测试", kind: .elasticsearchAlias)
        let indexRequest = try await worker.readRequest(index)
        let aliasRequest = try await worker.readRequest(alias)
        #expect(indexRequest.method == .get)
        #expect(indexRequest.path.removingPercentEncoding == "/logs%&测试/_alias?expand_wildcards=all")
        #expect(aliasRequest.path.removingPercentEncoding == "/_alias/current%&测试?expand_wildcards=all")
    }

    @Test func parsingRetainsOptionsAndWriteIndexStates() async throws {
        let worker = WorkspaceElasticsearchAliasWorker()
        let selection = aliasSelection("current")
        let response = aliasResponse(#"""
        {
          "logs-a":{"aliases":{"current":{"filter":{"term":{"tenant":"a"}},"index_routing":"1","future":{"enabled":true},"is_write_index":true}}},
          "logs-b":{"aliases":{"current":{"search_routing":"2","is_write_index":false}}},
          "logs-c":{"aliases":{"current":{}}}
        }
        """#)
        let snapshot = try await worker.snapshot(selection: selection, response: response, purpose: .baseline)
        #expect(snapshot.bindings.map(\.indexName) == ["logs-a", "logs-b", "logs-c"])
        #expect(snapshot.bindings.map(\.isWriteIndex) == [true, false, nil])
        let firstOptions = try #require(JSONSerialization.jsonObject(with: snapshot.bindings[0].optionsJSON) as? [String: Any])
        #expect(firstOptions["index_routing"] as? String == "1")
        #expect(firstOptions["filter"] != nil && firstOptions["future"] != nil)
        #expect(firstOptions["is_write_index"] == nil)
    }

    @Test func switchingWriteIndexProducesMinimalActionsAndPreservesUnknownOptions() async throws {
        let worker = WorkspaceElasticsearchAliasWorker()
        let selection = aliasSelection("current")
        let snapshot = try await worker.snapshot(selection: selection, response: aliasResponse(#"""
        {
          "logs-a":{"aliases":{"current":{"filter":{"term":{"tenant":"a"}},"future_setting":7,"is_write_index":true}}},
          "logs-b":{"aliases":{"current":{}}}
        }
        """#), purpose: .baseline)
        var rows = await worker.rows(snapshot)
        rows[0].binding.isWriteIndex = false
        rows[1].binding.isWriteIndex = true
        let prepared = try await worker.prepare(snapshot: snapshot, rows: rows)
        try await worker.validatePrepared(prepared)
        #expect(prepared.request.method == .post && prepared.request.path == "/_aliases")
        let actions = try aliasActions(prepared.request)
        #expect(actions.count == 2)
        let first = try #require(actions[0]["add"] as? [String: Any])
        let second = try #require(actions[1]["add"] as? [String: Any])
        #expect(first["index"] as? String == "logs-a" && first["is_write_index"] as? Bool == false)
        #expect(first["filter"] != nil && first["future_setting"] as? Int == 7)
        #expect(second["index"] as? String == "logs-b" && second["is_write_index"] as? Bool == true)
    }

    @Test func additionAndRemovalAreOneAtomicAliasesRequest() async throws {
        let worker = WorkspaceElasticsearchAliasWorker()
        let selection = aliasSelection("current")
        let snapshot = try await worker.snapshot(selection: selection,
            response: aliasResponse(#"{"logs-a":{"aliases":{"current":{}}}}"#), purpose: .baseline)
        var rows = await worker.rows(snapshot)
        rows[0].isRemoved = true
        rows.append(.init(id: UUID(), original: nil,
            binding: .init(indexName: "logs-b", aliasName: "current", isWriteIndex: true,
                optionsJSON: Data("{}".utf8)), isRemoved: false))
        let prepared = try await worker.prepare(snapshot: snapshot, rows: rows)
        let actions = try aliasActions(prepared.request)
        #expect(actions.count == 2)
        #expect((actions[0]["remove"] as? [String: String]) == ["index": "logs-a", "alias": "current"])
        let add = try #require(actions[1]["add"] as? [String: Any])
        #expect(add["index"] as? String == "logs-b" && add["alias"] as? String == "current")
        #expect(add["is_write_index"] as? Bool == true)
    }

    @Test func preparedRequestAndBaselineCannotBeChanged() async throws {
        let worker = WorkspaceElasticsearchAliasWorker()
        let selection = indexAliasSelection("logs")
        let snapshot = try await worker.snapshot(selection: selection,
            response: aliasResponse(#"{"logs":{"aliases":{}}}"#), purpose: .baseline)
        let row = WorkspaceElasticsearchAliasEditorRow(id: UUID(), original: nil,
            binding: .init(indexName: "logs", aliasName: "current", isWriteIndex: nil,
                optionsJSON: Data("{}".utf8)), isRemoved: false)
        let prepared = try await worker.prepare(snapshot: snapshot, rows: [row])
        try await worker.validatePrepared(prepared)
        await #expect(throws: WorkspaceElasticsearchAliasError.self) {
            try await worker.validatePrepared(.init(baseline: prepared.baseline,
                desiredBindings: prepared.desiredBindings,
                request: .init(method: .delete, path: "/logs")))
        }
        await #expect(throws: WorkspaceElasticsearchAliasError.self) {
            try await worker.validateBaseline(prepared,
                response: aliasResponse(#"{"logs":{"aliases":{"external":{}}}}"#))
        }
    }

    @Test func removingLastAliasBindingCanBeVerifiedFrom404() async throws {
        let worker = WorkspaceElasticsearchAliasWorker()
        let selection = aliasSelection("current")
        let snapshot = try await worker.snapshot(selection: selection,
            response: aliasResponse(#"{"logs":{"aliases":{"current":{}}}}"#), purpose: .baseline)
        var rows = await worker.rows(snapshot)
        rows[0].isRemoved = true
        let prepared = try await worker.prepare(snapshot: snapshot, rows: rows)
        #expect(try await worker.matches(prepared,
            response: .init(statusCode: 404, contentType: "application/json",
                body: Data(#"{"error":"alias missing"}"#.utf8))))
    }

    @Test @MainActor func commitChecksBaselineThenSendsExactPreparedRequest() async throws {
        let (workspace, session) = await aliasWorkspaceFixture()
        workspace.safetyLock.disable()
        let worker = WorkspaceElasticsearchAliasWorker()
        let selection = aliasSelection("current")
        let snapshot = try await worker.snapshot(selection: selection,
            response: aliasResponse(#"{"logs-a":{"aliases":{"current":{}}}}"#), purpose: .baseline)
        var rows = await worker.rows(snapshot)
        rows.append(.init(id: UUID(), original: nil,
            binding: .init(indexName: "logs-b", aliasName: "current", isWriteIndex: true,
                optionsJSON: Data("{}".utf8)), isRemoved: false))
        let prepared = try await worker.prepare(snapshot: snapshot, rows: rows)
        let response = try await workspace.commitElasticsearchAliases(prepared)
        #expect(await worker.acknowledged(response))
        let requests = await session.requests
        #expect(requests.last == prepared.request)
        #expect(requests.filter { $0.method == .post } == [prepared.request])
        await workspace.disconnect()
    }

    @Test @MainActor func editorKeepsOneExplicitWriteIndexAndDiscardRestoresServerState() async throws {
        let (workspace, _) = await aliasWorkspaceFixture()
        workspace.safetyLock.disable()
        let editor = WorkspaceElasticsearchAliasEditor()
        let worker = WorkspaceElasticsearchAliasWorker()
        let selection = aliasSelection("current")
        let snapshot = try await worker.snapshot(selection: selection, response: aliasResponse(#"""
        {
          "logs-a":{"aliases":{"current":{"is_write_index":true}}},
          "logs-b":{"aliases":{"current":{}}}
        }
        """#), purpose: .baseline)
        await editor.load { snapshot }
        let second = editor.rows[1].id
        editor.setWriteIndex(rowID: second, isWriteIndex: true, workspace: workspace)
        await waitForSettings { editor.prepared != nil }
        #expect(editor.rows.map(\.binding.isWriteIndex) == [false, true])
        #expect(editor.hasChanges && editor.canCommit)
        editor.discard()
        #expect(editor.rows.map(\.binding.isWriteIndex) == [true, nil])
        #expect(!editor.hasChanges && !editor.canCommit)
        await workspace.disconnect()
    }

    @Test @MainActor func externalChangeOrRelockedSafetyLockPreventsAliasWrite() async throws {
        let worker = WorkspaceElasticsearchAliasWorker()
        for mode in ["external", "relock"] {
            let (workspace, session) = await aliasWorkspaceFixture(mode: mode)
            workspace.safetyLock.disable()
            let selection = aliasSelection("current")
            let snapshot = try await worker.snapshot(selection: selection,
                response: aliasResponse(#"{"logs-a":{"aliases":{"current":{}}}}"#), purpose: .baseline)
            var rows = await worker.rows(snapshot)
            rows[0].binding.isWriteIndex = true
            let prepared = try await worker.prepare(snapshot: snapshot, rows: rows)
            if mode == "relock" {
                await session.setReadHook { workspace.safetyLock.enable() }
            } else {
                await session.setAliasBody(#"{"logs-a":{"aliases":{"current":{}}},"logs-b":{"aliases":{"current":{}}}}"#)
            }
            await #expect(throws: WorkspaceElasticsearchAliasNotSentError.self) {
                try await workspace.commitElasticsearchAliases(prepared)
            }
            #expect(await session.requests.allSatisfy { $0.method == .get })
            await workspace.disconnect()
        }
    }

    @Test func bilingualAliasErrors() {
        for error in [WorkspaceElasticsearchAliasError.unsupportedResource, .invalidName,
                      .duplicateBinding, .noChanges, .conflict, .uncertain] {
            #expect(error.message(copy: AppCopy(language: .english))
                != error.message(copy: AppCopy(language: .simplifiedChinese)))
        }
    }
}

private func aliasSelection(_ name: String) -> WorkspaceDatabaseObjectSelection {
    .init(databaseName: "Elasticsearch", objectName: name, kind: .elasticsearchAlias)
}

private func indexAliasSelection(_ name: String) -> WorkspaceDatabaseObjectSelection {
    .init(databaseName: "Elasticsearch", objectName: name, kind: .elasticsearchIndex)
}

private func aliasResponse(_ text: String) -> WorkspaceRequestExecutionResult {
    .init(statusCode: 200, contentType: "application/json", body: Data(text.utf8))
}

private func aliasActions(_ request: WorkspaceRequest) throws -> [[String: Any]] {
    let body = try #require(request.body)
    let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require(root["actions"] as? [[String: Any]])
}

@MainActor private func aliasWorkspaceFixture(mode: String = "success") async
    -> (WorkspaceModel, AliasManagementTestSession) {
    let session = AliasManagementTestSession(mode: mode)
    let profile = ConnectionProfile(id: UUID(), name: "Alias test", groupID: nil,
        databaseProduct: .elasticsearch, host: "127.0.0.1", port: 9200, username: "",
        defaultDatabase: nil, tlsMode: .disabled, storesCredential: false, createdAt: .now)
    let workspace = WorkspaceModel(profileID: profile.id,
        repository: InMemoryConnectionProfileRepository(profiles: [profile]),
        credentialStore: InMemoryCredentialStore(),
        sessionFactory: AliasManagementTestFactory(session: session))
    _ = await workspace.connect()
    return (workspace, session)
}

private struct AliasManagementTestFactory: WorkspaceSessionFactory {
    let session: AliasManagementTestSession
    func makeSession(configuration: DatabaseConnectionConfiguration) async -> any WorkspaceSession { session }
}

private actor AliasManagementTestSession: WorkspaceSession, WorkspaceRequestExecutingSession {
    let mode: String
    private(set) var requests: [WorkspaceRequest] = []
    private var aliasBody = #"{"logs-a":{"aliases":{"current":{}}}}"#
    private var readHook: (@MainActor @Sendable () -> Void)?
    init(mode: String) { self.mode = mode }
    func setAliasBody(_ body: String) { aliasBody = body }
    func setReadHook(_ hook: @escaping @MainActor @Sendable () -> Void) { readHook = hook }
    func connect() async throws {}
    func close() async {}
    func fetchDatabases() async throws -> [String] { ["Elasticsearch"] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws
        -> WorkspaceDatabaseObjectDetails { throw WorkspaceSessionError.queryUnavailable }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws
        -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int,
        limit: Int, sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws
        -> WorkspaceDatabaseDataFetchResult { throw WorkspaceSessionError.queryUnavailable }
    func executeRequest(_ request: WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult {
        try await executeRequest(request, policy: .readOnly)
    }
    func executeRequest(_ request: WorkspaceRequest, policy: WorkspaceRequestExecutionPolicy) async throws
        -> WorkspaceRequestExecutionResult {
        try WorkspaceRequestClassifier.validate(request, policy: policy)
        requests.append(request)
        if request.method == .get {
            await readHook?()
            return aliasResponse(aliasBody)
        }
        return aliasResponse(#"{"acknowledged":true}"#)
    }
}
