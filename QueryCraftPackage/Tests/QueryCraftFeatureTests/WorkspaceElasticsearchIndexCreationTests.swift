import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceElasticsearchIndexCreationTests {
    @Test func leavesUnspecifiedSettingsToServerAndPreservesMappingBytes() async throws {
        let mapping = #"{"_meta":{"id":18446744073709551615,"text":"\u0041\/"},"properties":{"name":{"type":"keyword"}}}"#
        let prepared = try await WorkspaceIndexCreationWorker().prepare(.init(name: "qc_new", mapping: mapping))
        #expect(prepared.request.method == .put)
        #expect(prepared.request.path == "/qc_new")
        #expect(prepared.request.body == Data(("{\"mappings\":" + mapping + "}").utf8))
        #expect(prepared.verificationRequest == WorkspaceRequest(method: .head, path: "/qc_new"))
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) {
            try WorkspaceRequestClassifier.validate(prepared.request, policy: .readOnly)
        }
    }

    @Test func sendsOnlyExplicitSettings() async throws {
        let worker = WorkspaceIndexCreationWorker()
        let prepared = try await worker.prepare(.init(name: "qc_new", shards: "1", replicas: "0"))
        #expect(prepared.request.body == Data(#"{"settings":{"number_of_shards":1,"number_of_replicas":0},"mappings":{}}"#.utf8))
        let replicasOnly = try await worker.prepare(.init(name: "qc_new", replicas: "2"))
        #expect(replicasOnly.request.body == Data(#"{"settings":{"number_of_replicas":2},"mappings":{}}"#.utf8))
    }

    @Test(arguments: ["", "Upper", ".", "..", "_a", "-a", "+a", "a/b", "a\\b", "a*b", "a?b", "a#b", "a:b", "a b", "a\nb", "a\u{0000}b", "a,b", "a|b", "a<b", "a>b", "a\"b", "https://host", String(repeating: "a", count: 256), String(repeating: "中", count: 86)])
    func invalidNamesNeverProduceARequest(name: String) async {
        await #expect(throws: WorkspaceIndexCreationError.self) {
            try await WorkspaceIndexCreationWorker().prepare(.init(name: name))
        }
    }

    @Test(arguments: ["qc_new-2026.09", "测试_索引", "a%value", "a&b", ".hidden", String(repeating: "中", count: 85)])
    func legalNamesRemainASingleEncodedPathComponent(name: String) async throws {
        let prepared = try await WorkspaceIndexCreationWorker().prepare(.init(name: name))
        let url = try #require(URL(string: "http://localhost:9200" + prepared.request.path))
        #expect(url.path == "/" + name)
        #expect(url.query == nil)
        #expect(url.fragment == nil)
    }

    @Test(arguments: ["0", "-1", "1.5", "x", "99999999999999999999999"])
    func invalidShardCountsAreRejected(value: String) async {
        await #expect(throws: WorkspaceIndexCreationError.self) {
            try await WorkspaceIndexCreationWorker().prepare(.init(name: "qc_new", shards: value))
        }
    }

    @Test(arguments: ["-1", "1.5", "x", "99999999999999999999999"])
    func invalidReplicaCountsAreRejected(value: String) async {
        await #expect(throws: WorkspaceIndexCreationError.self) {
            try await WorkspaceIndexCreationWorker().prepare(.init(name: "qc_new", replicas: value))
        }
    }

    @Test(arguments: ["", "[]", "null", "true", "1", #""string""#, #"{"properties":"#, "{} trailing"])
    func mappingMustBeACompleteObject(mapping: String) async {
        await #expect(throws: WorkspaceIndexCreationError.self) {
            try await WorkspaceIndexCreationWorker().prepare(.init(name: "qc_new", mapping: mapping))
        }
    }

    @Test func cancellationDoesNotPublishPreparedRequest() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorkspaceIndexCreationWorker().prepare(.init(name: "qc_new"))
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test @MainActor func exactSnapshotIsSentAndDuplicateSubmissionIsIgnored() async throws {
        let editor = await validEditor()
        let prepared = try #require(editor.currentPrepared)
        var requests: [WorkspaceRequest] = []
        await editor.submit(prepared) { request in
            requests.append(request)
            #expect(editor.isBusy && !editor.canEdit && !editor.canSubmit)
            await editor.submit(prepared) { _ in Issue.record("Duplicate send"); return response(200) }
            return response(200, #"{"acknowledged":true,"shards_acknowledged":true,"index":"qc_new"}"#)
        }
        #expect(requests == [prepared.request])
        #expect(editor.indexExists && editor.wasCreated && !editor.canSubmit)
        #expect(!editor.isBusy)
        #expect(editor.input == prepared.input)
    }

    @Test @MainActor func changedInputInvalidatesOldPreviewBeforeValidationFinishes() async throws {
        let editor = await validEditor()
        let old = try #require(editor.currentPrepared)
        editor.input.name = "qc_changed"
        #expect(editor.currentPrepared == nil && !editor.canSubmit)
        await editor.submit(old) { _ in Issue.record("Stale request sent"); return response(200) }
        await editor.validate()
        #expect(editor.currentPrepared?.request.path == "/qc_changed")
        editor.input.mapping = "{"
        await editor.validate()
        #expect(editor.currentPrepared == nil)
        #expect(editor.validationMessage != nil)
        #expect(editor.input.mapping == "{")
    }

    @Test @MainActor func httpRejectionRetainsInputAndCompleteResponse() async throws {
        let editor = await validEditor()
        let prepared = try #require(editor.currentPrepared)
        let body = #"{"error":{"type":"resource_already_exists_exception","reason":"exists"},"status":400}"#
        await editor.submit(prepared) { _ in response(400, body) }
        #expect(editor.canSubmit && !editor.mustVerify && !editor.indexExists)
        #expect(editor.input == prepared.input)
        #expect(editor.responseText == body)
        #expect(editor.message?.contains("400") == true)
    }

    @Test @MainActor func notSentFailureDoesNotRequireServerVerification() async throws {
        let editor = await validEditor()
        await editor.submit(try #require(editor.currentPrepared)) { _ in
            throw WorkspaceElasticsearchRequestNotSentError(message: "Not sent")
        }
        #expect(editor.canSubmit && !editor.mustVerify)
        #expect(editor.message == "Not sent")
    }

    @Test @MainActor func shardAcknowledgementTimeoutStillMeansIndexCreated() async throws {
        let editor = await validEditor()
        await editor.submit(try #require(editor.currentPrepared)) { _ in
            response(200, #"{"acknowledged":true,"shards_acknowledged":false,"index":"qc_new"}"#)
        }
        #expect(editor.indexExists && editor.wasCreated && !editor.mustVerify)
        #expect(editor.message?.contains("shards") == true || editor.message?.contains("分片") == true)
    }

    @Test(arguments: [response(200, #"{"acknowledged":false}"#), response(200, "invalid"), response(503), response(408)])
    @MainActor func uncertainResponsesBlockRetryAndMissingIndexAllowsOnlyManualRetry(result: WorkspaceRequestExecutionResult) async throws {
        let editor = await validEditor()
        let prepared = try #require(editor.currentPrepared)
        var sends = 0
        await editor.submit(prepared) { _ in sends += 1; return result }
        #expect(editor.mustVerify && !editor.canSubmit && !editor.canEdit)
        await editor.submit(prepared) { _ in sends += 1; return response(200) }
        await editor.verify { request in
            #expect(request == prepared.verificationRequest)
            return response(404)
        }
        #expect(sends == 1)
        #expect(editor.canSubmit && !editor.mustVerify && !editor.indexExists)
        #expect(editor.input == prepared.input)
    }

    @Test @MainActor func verificationPreservesUncertaintyOnDeniedReadAndRecognizesExistingResource() async throws {
        let editor = await validEditor()
        await editor.submit(try #require(editor.currentPrepared)) { _ in throw URLError(.timedOut) }
        await editor.verify { _ in response(403) }
        #expect(editor.mustVerify && !editor.canSubmit)
        await editor.verify { _ in response(200) }
        #expect(editor.indexExists && !editor.wasCreated && !editor.mustVerify && !editor.canSubmit)
    }

    @Test @MainActor func cancellationBeforeResponseIsUncertainButCompletedResponseIsRetained() async throws {
        for completes in [false, true] {
            let editor = await validEditor()
            let prepared = try #require(editor.currentPrepared)
            let task = Task { @MainActor in
                await editor.submit(prepared) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    if !completes { throw CancellationError() }
                    return response(200, #"{"acknowledged":true,"index":"qc_new"}"#)
                }
            }
            await task.value
            #expect(editor.indexExists == completes)
            #expect(editor.mustVerify == !completes)
            #expect(!editor.isBusy)
        }
    }

    @Test func validationErrorsHaveBothLanguages() {
        for error in [WorkspaceIndexCreationError.name, .shards, .replicas, .mapping] {
            let chinese = error.message(copy: AppCopy(language: .simplifiedChinese))
            let english = error.message(copy: AppCopy(language: .english))
            #expect(!chinese.isEmpty && !english.isEmpty && chinese != english)
        }
    }

    @MainActor private func validEditor() async -> WorkspaceElasticsearchIndexCreationEditor {
        let editor = WorkspaceElasticsearchIndexCreationEditor()
        editor.input = .init(name: "qc_new", shards: "1", replicas: "0")
        await editor.validate()
        return editor
    }
}

private func response(_ status: Int, _ body: String = "{}") -> WorkspaceRequestExecutionResult {
    .init(statusCode: status, contentType: "application/json", body: Data(body.utf8))
}
