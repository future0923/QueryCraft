import Foundation
import Testing
@testable import QueryCraftFeature

@Suite(.serialized, .timeLimit(.minutes(1)))
struct WorkspaceElasticsearchConsoleWriteTests {
    @Test @MainActor func workspaceDraftsDoNotBlockConsoleButSafetyLockStillDoes() async throws {
        let profile = ConnectionProfile(id: UUID(), name: "Elasticsearch", groupID: nil,
            databaseProduct: .elasticsearch, host: "127.0.0.1", port: 9200,
            username: "elastic", defaultDatabase: nil, tlsMode: .disabled,
            storesCredential: false, createdAt: .now)
        let workspace = WorkspaceModel(profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["Elasticsearch"]))
        let read = WorkspaceRequest(method: .get, path: "/logs/_count")
        #expect(throws: WorkspaceSessionError.self) { try workspace.authorizeElasticsearchRequests([read]) }
        _ = await workspace.connect()
        #expect(workspace.connectionState == .connected)
        var draftChecks = 0
        workspace.elasticsearchHasPendingChanges = { draftChecks += 1; return true }
        try workspace.authorizeElasticsearchRequests([read])
        for method: WorkspaceRequestMethod in [.put, .post, .delete] {
            let write = WorkspaceRequest(method: method, path: "/logs/_doc/1")
            workspace.safetyLock.enable()
            #expect(throws: WorkspaceDatabaseDataCellEditError.safetyLockEnabled) {
                try workspace.authorizeElasticsearchRequests([read, write])
            }
            workspace.safetyLock.disable()
            try workspace.authorizeElasticsearchRequests([read, write])
        }
        #expect(draftChecks == 0)
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) {
            try workspace.authorizeElasticsearchRequests([.init(method: .put, path: "https://example.com/logs")])
        }
        await workspace.disconnect()
    }

    @Test func requestPreviewFormatsMappingWithoutChangingPreparedBytes() async throws {
        let original = Data(#"{"properties":{"name":{"fields":{"keyword":{"type":"keyword"}},"type":"text"}},"number":18446744073709551615,"escape":"\u0041\/"}"#.utf8)
        let request = WorkspaceRequest(method: .put, path: "/logs/_mapping", body: original)
        let bulk = Data("{\"index\":{}}\n{\"value\":1}\n".utf8)
        let bodies = try await WorkspaceElasticsearchConsoleWorker().previewBodies([
            request,
            .init(method: .delete, path: "/logs/_doc/1"),
            .init(method: .post, path: "/_bulk", body: bulk)
        ])
        let text = try #require(bodies[0])
        #expect(text.contains("\n  \"properties\" : {\n    \"name\" : {\n      \"fields\" : {"))
        #expect(text.contains("18446744073709551615"))
        #expect(text.contains(#"\u0041\/"#))
        #expect(request.body == original)
        #expect(bodies[1] == nil)
        #expect(bodies[2] == String(decoding: bulk, as: UTF8.self))
    }

    @Test func formattingNeverReencodesNumbersOrEscapes() throws {
        let body = #"{"number":18446744073709551615,"tiny":1.234567890123456789e-12,"escape":"\u0041\/","empty":{},"array":[1,2]}"#
        let formatted = try ElasticsearchConsoleParser().formatted("PUT /logs/_doc/1\n" + body)
        #expect(formatted.contains("18446744073709551615"))
        #expect(formatted.contains("1.234567890123456789e-12"))
        #expect(formatted.contains(#"\u0041\/"#))
        let bulk = try ElasticsearchConsoleParser().formatted("POST /_bulk\n{\"index\":{}}\n" + body)
        #expect(bulk.split(separator: "\n").last == Substring(body))
    }

    @Test @MainActor func confirmationKeepsOriginalSnapshotAndRechecksPermission() async throws {
        let preferences = ApplicationPreferences.shared
        let original = preferences.confirmsDangerousSQL
        preferences.confirmsDangerousSQL = true
        defer { preferences.confirmsDangerousSQL = original }
        let captured = CapturedRequests()
        let document = WorkspaceElasticsearchRequestDocumentModel(title: "test", source: "DELETE /old-index") { request in
            await captured.append(request)
            return .init(statusCode: 200, contentType: "application/json", body: Data("{}".utf8))
        }
        document.authorize = { _ in }
        document.runAll()
        while document.isExecuting { await Task.yield() }
        #expect(document.pendingConfirmation != nil)
        document.source = "DELETE /new-index"
        document.confirmExecution()
        while document.isExecuting { await Task.yield() }
        #expect(await captured.requests.map(\.path) == ["/old-index"])
        document.runAll()
        while document.isExecuting { await Task.yield() }
        document.authorize = { _ in throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled }
        document.confirmExecution()
        #expect(await captured.requests.count == 1)
    }

    @Test @MainActor func completedWriteSurvivesStopAndReconciles() async {
        let responseGate = ResponseGate()
        let document = WorkspaceElasticsearchRequestDocumentModel(title: "test", source: "PUT /logs/_doc/1\n{}\nGET /logs/_search") { _ in
            await responseGate.response()
        }
        var refreshed = false
        document.authorize = { _ in }
        document.batchDidWrite = { refreshed = !Task.isCancelled }
        document.runAll()
        while !(await responseGate.waiting) { await Task.yield() }
        document.stop()
        await responseGate.finish()
        while document.isExecuting { await Task.yield() }
        #expect(document.results.first?.statusCode == 201)
        #expect(document.results.first?.output != nil)
        #expect(document.results.count == 2)
        #expect(document.results[1].statusCode == nil)
        #expect(refreshed)
    }

    @Test func writeBodyCompletionUsesMappingAndNDJSONContexts() async throws {
        let worker = WorkspaceElasticsearchDSLCompletionWorker()
        for (source, expected) in [
            ("PUT /logs/_mapping\n{\"properties\":{\"name\":{", "type"),
            ("POST /_bulk\n{", "create"),
            ("POST /_bulk\n{\"delete\":{\"_index\":\"logs\",\"_id\":\"1\"}}\n{", "index"),
            ("POST /_bulk\n{\"create\":{\"_index\":\"logs\"}}\n{", "areaName"),
            ("POST /_aliases\n{\"actions\":[{", "add")
        ] {
            let completions = try await worker.completions(source: source, cursor: (source as NSString).length, fields: ["areaName"], resources: [], indentationUnit: "  ")
            #expect(completions.contains { $0.label == expected })
        }
    }
    @Test(arguments: [WorkspaceRequestMethod.put, .delete, .post])
    func requiresExplicitWritePolicy(method: WorkspaceRequestMethod) throws {
        let request = WorkspaceRequest(method: method, path: "/logs/_unknown_write", body: Data("{}".utf8))
        #expect(WorkspaceRequestClassifier.requiresWriteAccess(request))
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) { try WorkspaceRequestClassifier.validate(request, policy: .readOnly) }
        try WorkspaceRequestClassifier.validate(request, policy: .writesAllowed)
    }

    @Test(arguments: ["https://example.com/logs", "//example.com/logs", "/a/../logs", "/a/%2E%2E/logs", "/logs#fragment", "/\\example.com/logs"])
    func unlockedStillRejectsForeignOrAmbiguousPaths(path: String) {
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) { try WorkspaceRequestClassifier.validate(.init(method: .put, path: path), policy: .writesAllowed) }
    }

    @Test func postClassificationUsesWholeRoutes() throws {
        #expect(!WorkspaceRequestClassifier.requiresWriteAccess(.init(method: .post, path: "/logs/_search")))
        #expect(WorkspaceRequestClassifier.requiresWriteAccess(.init(method: .post, path: "/admin/nested/_search")))
        #expect(!WorkspaceRequestClassifier.requiresWriteAccess(.init(method: .post, path: "/logs/_msearch/template")))
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) { try WorkspaceRequestClassifier.validate(.init(method: .get, path: "/_bulk", body: Data("{}".utf8)), policy: .writesAllowed) }
    }

    @Test func parsingPreservesWriteBytesAndBulkNewline() async throws {
        let source = "PUT /logs/_doc/a%2Fb?routing=t%2F1\n {\"number\":18446744073709551615,\"escaped\":\"\\u0041\"} \n"
        let requests = try await WorkspaceElasticsearchConsoleWorker().requests(source: source, selection: nil)
        #expect(requests[0].request.body == Data(" {\"number\":18446744073709551615,\"escaped\":\"\\u0041\"} \n".utf8))
        let bulk = try await WorkspaceElasticsearchConsoleWorker().requests(source: "POST /_bulk\n{\"index\":{\"_index\":\"logs\"}}\n{\"name\":\"x\"}", selection: nil)
        #expect(String(decoding: bulk[0].request.body!, as: UTF8.self).hasSuffix("\n"))
    }

    @Test func responseFailuresAndAsyncAcceptance() throws {
        for body in [#"{"errors":true,"items":[]}"#, #"{"failures":[{}]}"#, #"{"acknowledged":false}"#] {
            #expect(try WorkspaceElasticsearchResponseDetails.read(
                response: .init(statusCode: 200, contentType: "application/json", body: Data(body.utf8)),
                displayedRows: nil, parsed: nil, source: nil).failureMessage != nil)
        }
        #expect(try WorkspaceElasticsearchResponseDetails.read(
            response: .init(statusCode: 200, contentType: "application/json", body: Data(#"{"task":"node:42"}"#.utf8)),
            displayedRows: nil, parsed: nil, source: nil).acceptedTask == "node:42")
    }

    @Test @MainActor func preflightRejectsWholeBatchAndFailureStopsRemainder() async {
        let counter = RequestCounter()
        let document = WorkspaceElasticsearchRequestDocumentModel(title: "test", source: "GET /\n\nPUT /logs/_doc/1\n{}\n\nGET /logs/_search") { request in
            await counter.record(request)
            return .init(statusCode: request.method == .put ? 409 : 200, contentType: "application/json", body: Data("{}".utf8))
        }
        document.runAll()
        while document.isExecuting { await Task.yield() }
        #expect(await counter.count == 0)
        document.authorize = { _ in }
        document.runAll()
        while document.isExecuting { await Task.yield() }
        if document.pendingConfirmation != nil { document.confirmExecution() }
        while document.isExecuting { await Task.yield() }
        #expect(await counter.count == 2)
        #expect(document.results.count == 3)
        #expect(document.results[1].statusCode == 409)
        #expect(document.results[1].output != nil)
        #expect(document.results[2].statusCode == nil)
    }
}

private actor RequestCounter {
    private(set) var count = 0
    func record(_ request: WorkspaceRequest) { count += 1 }
}

private actor CapturedRequests {
    private(set) var requests: [WorkspaceRequest] = []
    func append(_ request: WorkspaceRequest) { requests.append(request) }
}
private actor ResponseGate {
    private var continuation: CheckedContinuation<WorkspaceRequestExecutionResult, Never>?
    var waiting: Bool { continuation != nil }
    func response() async -> WorkspaceRequestExecutionResult {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: .init(statusCode: 201, contentType: "application/json", body: Data(#"{"result":"created"}"#.utf8)))
        continuation = nil
    }
}
