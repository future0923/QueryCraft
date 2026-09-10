import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceElasticsearchIndexDeletionTests {
    @Test(arguments: ["logs", "测试_索引", "a%value", "a&b", ".hidden"])
    func requestEncodesOneExactIndexWithoutBody(name: String) async throws {
        let prepared = try await WorkspaceIndexDeletionWorker().prepare(indexSelection(name))
        #expect(prepared.request.method == .delete)
        #expect(prepared.request.body == nil)
        #expect(prepared.request.path.removingPercentEncoding == "/" + name)
        #expect(prepared.verificationRequest == .init(method: .head, path: prepared.request.path))
        #expect(prepared.resolutionRequest.path == "/_resolve/index" + prepared.request.path + "?expand_wildcards=all")
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) {
            try WorkspaceRequestClassifier.validate(prepared.request, policy: .readOnly)
        }
    }

    @Test(arguments: ["*", "_all", "a,b", "a/b", "//other", "https://host", "a?x=y", "a#fragment", "", ".ds-logs-000001"])
    func unsafeTargetsNeverProduceADelete(name: String) async {
        await #expect(throws: (any Error).self) { try await WorkspaceIndexDeletionWorker().prepare(indexSelection(name)) }
    }

    @Test(arguments: [WorkspaceDatabaseObjectKind.table, .view, .elasticsearchAlias, .elasticsearchDataStream])
    func deletionIsNotOfferedForOtherKinds(kind: WorkspaceDatabaseObjectKind) async {
        let selection = WorkspaceDatabaseObjectSelection(databaseName: "Elasticsearch", objectName: "logs", kind: kind)
        #expect(!WorkspaceIndexDeletionWorker.offersDeletion(selection))
        await #expect(throws: WorkspaceIndexDeletionError.self) { try await WorkspaceIndexDeletionWorker().prepare(selection) }
    }

    @Test(arguments: [#"{"indices":[],"aliases":[{"name":"logs"}]}"#,
                      #"{"indices":[],"data_streams":[{"name":"logs"}]}"#,
                      #"{"indices":[{"name":"logs","data_stream":"stream"}]}"#,
                      #"{"indices":[{"name":"other"}]}"#,
                      #"{"indices":[{"name":"logs"},{"name":"other"}]}"#, "{}"])
    func staleResourceResolutionFailsClosed(body: String) async throws {
        let worker = WorkspaceIndexDeletionWorker()
        let prepared = try await worker.prepare(indexSelection("logs"))
        await #expect(throws: WorkspaceIndexDeletionNotSentError.self) {
            try await worker.validateResolution(indexDeletionResponse(200, body), for: prepared)
        }
    }

    @Test @MainActor func exactTypedConfirmationAndSingleSubmission() async throws {
        let editor = await readyEditor()
        for text in ["", "log", "LOGS", "logs ", " logs", "*"] {
            editor.confirmation = text
            #expect(!editor.canDelete)
        }
        editor.confirmation = "logs"
        let expected = try #require(editor.prepared)
        var sent: [WorkspacePreparedIndexDeletion] = []
        await editor.submit { prepared in
            sent.append(prepared)
            #expect(!editor.canDelete && editor.isBusy)
            await editor.submit { _ in Issue.record("Duplicate deletion"); return indexDeletionResponse(200) }
            return indexDeletionResponse(200, #"{"acknowledged":true}"#)
        }
        #expect(sent == [expected])
        #expect(editor.isAbsent && !editor.canDelete && !editor.isBusy)
    }

    @Test(arguments: [401, 403, 429, 400, 404]) @MainActor
    func httpRejectionPreservesConfirmationAndFullResponse(status: Int) async {
        let editor = await readyEditor()
        let body = #"{"error":{"type":"security_exception","reason":"denied"}}"#
        await editor.submit { _ in indexDeletionResponse(status, body) }
        #expect(!editor.isAbsent && !editor.mustVerify && editor.canDelete)
        #expect(editor.confirmation == "logs" && editor.responseText == body)
    }

    @Test @MainActor func authoritativeNotFoundAllowsPageCleanup() async {
        let editor = await readyEditor()
        await editor.submit { _ in indexDeletionResponse(404, #"{"error":{"type":"index_not_found_exception"}}"#) }
        #expect(editor.isAbsent && !editor.mustVerify)
    }

    @Test(arguments: [indexDeletionResponse(200, #"{"acknowledged":false}"#), indexDeletionResponse(200, "invalid"), indexDeletionResponse(408), indexDeletionResponse(503)])
    @MainActor func uncertainResponsesRequireVerificationAndAnotherExactConfirmation(response: WorkspaceRequestExecutionResult) async {
        let editor = await readyEditor()
        await editor.submit { _ in response }
        #expect(editor.mustVerify && !editor.canDelete && !editor.isAbsent)
        await editor.submit { _ in Issue.record("Blind retry"); return indexDeletionResponse(200) }
        await editor.verify { request in
            #expect(request == .init(method: .head, path: "/logs"))
            return indexDeletionResponse(200)
        }
        #expect(!editor.mustVerify && !editor.isAbsent && !editor.canDelete)
        #expect(editor.confirmation.isEmpty)
        editor.confirmation = "logs"
        #expect(editor.canDelete)
    }

    @Test @MainActor func timeoutAndVerificationFailureKeepPagesUntilConfirmedAbsent() async {
        let editor = await readyEditor()
        await editor.submit { _ in throw URLError(.timedOut) }
        await editor.verify { _ in indexDeletionResponse(403) }
        #expect(editor.mustVerify && !editor.isAbsent)
        await editor.verify { _ in indexDeletionResponse(404) }
        #expect(editor.isAbsent && !editor.canDelete && !editor.mustVerify)
    }

    @Test @MainActor func cancellationKeepsCompleteAcknowledgementAndOtherwiseRequiresVerification() async {
        for complete in [true, false] {
            let editor = await readyEditor()
            let task = Task { @MainActor in
                await editor.submit { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    if !complete { throw CancellationError() }
                    return indexDeletionResponse(200, #"{"acknowledged":true}"#)
                }
            }
            await task.value
            #expect(editor.isAbsent == complete)
            #expect(editor.mustVerify == !complete)
        }
    }

    @Test @MainActor func preflightFailureDoesNotPretendAWriteWasSent() async {
        let editor = await readyEditor()
        let response = indexDeletionResponse(403, "full metadata error")
        await editor.submit { _ in throw WorkspaceIndexDeletionNotSentError(message: "Not sent", response: response) }
        #expect(!editor.didAttemptWrite && !editor.mustVerify && editor.canDelete)
        #expect(editor.responseText == "full metadata error")
    }

    @Test @MainActor func workspaceChecksLockAndDraftsBeforeTransport() async throws {
        let (model, session) = await indexDeletionFixture()
        let prepared = try await WorkspaceIndexDeletionWorker().prepare(indexSelection("logs"))
        model.safetyLock.enable()
        await #expect(throws: WorkspaceIndexDeletionNotSentError.self) { try await model.deleteElasticsearchIndex(prepared) }
        model.safetyLock.disable()
        model.elasticsearchHasPendingChanges = { true }
        await #expect(throws: WorkspaceIndexDeletionNotSentError.self) { try await model.deleteElasticsearchIndex(prepared) }
        #expect(await session.requests.isEmpty)
        // Console remains independent of staged changes.
        _ = try await model.executeElasticsearchRequest(.init(method: .post, path: "/logs/_refresh"))
        model.elasticsearchHasPendingChanges = { false }
        let response = try await model.deleteElasticsearchIndex(prepared)
        #expect(response.statusCode == 200)
        #expect(await session.requests.suffix(2).map(\.0) == [prepared.resolutionRequest, prepared.request])
        await model.disconnect()
    }

    @Test(arguments: [true, false]) @MainActor
    func lockOrDraftAppearingDuringResolutionPreventsDelete(lock: Bool) async throws {
        let (model, session) = await indexDeletionFixture()
        model.safetyLock.disable()
        await session.setResolutionHook {
            if lock { model.safetyLock.enable() }
            else { model.elasticsearchHasPendingChanges = { true } }
        }
        let prepared = try await WorkspaceIndexDeletionWorker().prepare(indexSelection("logs"))
        await #expect(throws: WorkspaceIndexDeletionNotSentError.self) { try await model.deleteElasticsearchIndex(prepared) }
        #expect(await session.requests.map(\.0) == [prepared.resolutionRequest])
        await model.disconnect()
    }

    @Test @MainActor func closingDeletedObjectPreservesQueriesAndOtherObjects() {
        let tabs = WorkspaceContentTabsModel()
        let deleted = indexSelection("logs")
        let other = indexSelection("other")
        let query = WorkspaceElasticsearchRequestDocumentModel(title: "Request", source: "GET /logs/_search") { _ in indexDeletionResponse(200) }
        tabs.open(deleted)
        tabs.append(query)
        tabs.open(other)
        tabs.select(.elasticsearchRequest(query.id))
        tabs.removeContent(.databaseObject(deleted))
        #expect(tabs.contentItems.map(\.id) == [.elasticsearchRequest(query.id), .databaseObject(other)])
        #expect(tabs.selectedContentID == .elasticsearchRequest(query.id))
        #expect(query.source == "GET /logs/_search")
    }

    @Test func messagesHaveBothLanguages() {
        for error in [WorkspaceIndexDeletionError.ordinaryIndexRequired, .pendingChanges] {
            #expect(error.message(copy: AppCopy(language: .english)) != error.message(copy: AppCopy(language: .simplifiedChinese)))
        }
    }

    @MainActor private func readyEditor() async -> WorkspaceElasticsearchIndexDeletionEditor {
        let editor = WorkspaceElasticsearchIndexDeletionEditor(selection: indexSelection("logs"))
        await editor.prepare()
        editor.confirmation = "logs"
        return editor
    }
}

func indexSelection(_ name: String) -> WorkspaceDatabaseObjectSelection {
    .init(databaseName: "Elasticsearch", objectName: name, kind: .elasticsearchIndex)
}

func indexDeletionResponse(_ status: Int, _ body: String = "{}") -> WorkspaceRequestExecutionResult {
    .init(statusCode: status, contentType: "application/json", body: Data(body.utf8))
}

@MainActor func indexDeletionFixture(port: Int? = nil) async -> (WorkspaceModel, IndexDeletionTestSession) {
    let session = IndexDeletionTestSession(port: port)
    let profile = ConnectionProfile(id: UUID(), name: "Index deletion test", groupID: nil,
        databaseProduct: .elasticsearch, host: "127.0.0.1", port: port ?? 9200,
        username: "", defaultDatabase: nil, tlsMode: .disabled, storesCredential: false, createdAt: .now)
    let model = WorkspaceModel(profileID: profile.id,
        repository: InMemoryConnectionProfileRepository(profiles: [profile]),
        credentialStore: InMemoryCredentialStore(), sessionFactory: IndexDeletionTestFactory(session: session))
    _ = await model.connect()
    return (model, session)
}

private struct IndexDeletionTestFactory: WorkspaceSessionFactory {
    let session: IndexDeletionTestSession
    func makeSession(configuration: DatabaseConnectionConfiguration) async -> any WorkspaceSession { session }
}

actor IndexDeletionTestSession: WorkspaceSession, WorkspaceRequestExecutingSession {
    let port: Int?
    private(set) var requests: [(WorkspaceRequest, WorkspaceRequestExecutionPolicy)] = []
    private var resolutionHook: (@MainActor @Sendable () -> Void)?
    init(port: Int?) { precondition(port == nil || [19280, 19290].contains(port!)); self.port = port }
    func setResolutionHook(_ hook: @escaping @MainActor @Sendable () -> Void) { resolutionHook = hook }
    func connect() async throws {}
    func close() async {}
    func fetchDatabases() async throws -> [String] { ["Elasticsearch"] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { throw WorkspaceSessionError.queryUnavailable }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort,
                      onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult { throw WorkspaceSessionError.queryUnavailable }
    func executeRequest(_ request: WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult {
        try await executeRequest(request, policy: .readOnly)
    }
    func executeRequest(_ request: WorkspaceRequest, policy: WorkspaceRequestExecutionPolicy) async throws -> WorkspaceRequestExecutionResult {
        try WorkspaceRequestClassifier.validate(request, policy: policy)
        requests.append((request, policy))
        if let port {
            var urlRequest = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)" + request.path)), timeoutInterval: 40)
            urlRequest.httpMethod = request.method.rawValue
            urlRequest.httpBody = request.body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (body, response) = try await URLSession.shared.data(for: urlRequest)
            return .init(statusCode: try #require(response as? HTTPURLResponse).statusCode, contentType: "application/json", body: body)
        }
        if request.path.hasPrefix("/_resolve/index/") {
            await resolutionHook?()
            return indexDeletionResponse(200, #"{"indices":[{"name":"logs","attributes":["open"]}]}"#)
        }
        return indexDeletionResponse(200, #"{"acknowledged":true}"#)
    }
}
