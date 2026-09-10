import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceElasticsearchIndexTemplateTests {
    @Test func parsesComposableTemplatesAndSummaryMetadata() async throws {
        let worker = WorkspaceElasticsearchIndexTemplateWorker()
        let templates = try await worker.templates(from: response(200, #"""
        {
          "index_templates": [
            {
              "name": "logs-template",
              "index_template": {
                "index_patterns": ["logs-*"],
                "priority": 200,
                "data_stream": {},
                "template": {"mappings":{"properties":{"message":{"type":"text"}}}}
              }
            },
            {
              "name": "archive-template",
              "index_template": {"index_patterns":["archive-*"]}
            }
          ]
        }
        """#))
        #expect(templates.map(\.name) == ["archive-template", "logs-template"])
        #expect(templates[0].indexPatterns == ["archive-*"])
        #expect(templates[0].priority == nil && !templates[0].isDataStream)
        #expect(templates[1].indexPatterns == ["logs-*"])
        #expect(templates[1].priority == 200 && templates[1].isDataStream)
        #expect(templates[1].source.contains("\"message\""))
    }

    @Test func savePreservesExactJSONBytesAndEncodesOnePathComponent() async throws {
        let worker = WorkspaceElasticsearchIndexTemplateWorker()
        let source = #"{"priority":18446744073709551615,"_meta":{"escaped":"\u0041\/"},"index_patterns":["日志-*"]}"#
        let prepared = try await worker.prepareSave(
            input: .init(name: "模板-v1", source: source),
            baseline: nil
        )
        #expect(prepared.request.method == .put)
        #expect(prepared.request.path.removingPercentEncoding == "/_index_template/模板-v1")
        #expect(prepared.request.body == Data(source.utf8))
        #expect(prepared.verificationRequest.method == .get)
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) {
            try WorkspaceRequestClassifier.validate(prepared.request, policy: .readOnly)
        }
    }

    @Test(arguments: ["", "a b", "a/b", "a\\b", "a*b", "a?b", "a,b", "a#b", "a\nb", String(repeating: "a", count: 256)])
    func rejectsUnsafeTemplateNames(name: String) async {
        await #expect(throws: WorkspaceElasticsearchIndexTemplateError.self) {
            try await WorkspaceElasticsearchIndexTemplateWorker().prepareSave(
                input: .init(name: name, source: "{}"), baseline: nil
            )
        }
    }

    @Test(arguments: ["", "[]", "null", "true", "1", #""text""#, "{"])
    func requiresACompleteJSONObject(source: String) async {
        await #expect(throws: WorkspaceElasticsearchIndexTemplateError.self) {
            try await WorkspaceElasticsearchIndexTemplateWorker().prepareSave(
                input: .init(name: "valid", source: source), baseline: nil
            )
        }
    }

    @Test func baselineValidationSeparatesCreateUpdateAndConflict() async throws {
        let worker = WorkspaceElasticsearchIndexTemplateWorker()
        let originalResponse = response(200, #"{"index_templates":[{"name":"logs","index_template":{"index_patterns":["logs-*"]}}]}"#)
        let baseline = try #require(try await worker.template(named: "logs", from: originalResponse))
        let update = try await worker.prepareSave(
            input: .init(name: "logs", source: #"{"index_patterns":["new-*"]}"#),
            baseline: baseline
        )
        try await worker.validateBaseline(update, response: originalResponse)
        await #expect(throws: WorkspaceElasticsearchIndexTemplateError.self) {
            try await worker.validateBaseline(update, response: response(200,
                #"{"index_templates":[{"name":"logs","index_template":{"index_patterns":["external-*"]}}]}"#))
        }

        let creation = try await worker.prepareSave(
            input: .init(name: "new", source: "{}"), baseline: nil
        )
        try await worker.validateBaseline(creation, response: response(404))
        await #expect(throws: WorkspaceElasticsearchIndexTemplateError.self) {
            try await worker.validateBaseline(creation, response: response(200,
                #"{"index_templates":[{"name":"new","index_template":{}}]}"#))
        }
    }

    @Test func deletionUsesExactBaselinePathAndNoBody() async throws {
        let worker = WorkspaceElasticsearchIndexTemplateWorker()
        let baseline = try #require(try await worker.template(named: "logs-v1", from: response(200,
            #"{"index_templates":[{"name":"logs-v1","index_template":{"index_patterns":["logs-*"]}}]}"#)))
        let prepared = try await worker.prepareDeletion(baseline)
        #expect(prepared.operation == .delete)
        #expect(prepared.request == .init(method: .delete, path: "/_index_template/logs-v1"))
        try await worker.validatePrepared(prepared)
    }

    @Test func acknowledgementAndErrorsHaveDefinedBehavior() async {
        let worker = WorkspaceElasticsearchIndexTemplateWorker()
        #expect(await worker.outcome(response(200, #"{"acknowledged":true}"#)) == .acknowledged)
        #expect(await worker.outcome(response(200, #"{"acknowledged":false}"#)) == .uncertain)
        #expect(await worker.outcome(response(503, "{}")) == .uncertain)
        #expect(await worker.outcome(response(400, #"{"error":"bad"}"#)) == .rejected)

        for error in [
            WorkspaceElasticsearchIndexTemplateError.invalidName,
            .invalidBody, .conflict, .pendingChanges, .unsupportedResponse, .uncertain,
        ] {
            let chinese = error.message(copy: AppCopy(language: .simplifiedChinese))
            let english = error.message(copy: AppCopy(language: .english))
            #expect(!chinese.isEmpty && !english.isEmpty && chinese != english)
        }
    }

    @Test @MainActor func loadingDoesNotSelectByDefaultAndSearchMatchesPatterns() async {
        let editor = WorkspaceElasticsearchIndexTemplateEditor()
        await editor.load { _ in response(200, #"""
        {"index_templates":[
          {"name":"logs-template","index_template":{"index_patterns":["production-events-*"]}},
          {"name":"archive","index_template":{"index_patterns":["archive-*"]}}
        ]}
        """#) }
        #expect(editor.templates.count == 2)
        #expect(!editor.hasSelection && editor.selectedName == nil)
        editor.searchText = "events"
        #expect(editor.visibleTemplates.map(\.name) == ["logs-template"])
    }

    @Test @MainActor func discardRestoresAuthoritativeTemplateBody() async throws {
        let editor = WorkspaceElasticsearchIndexTemplateEditor()
        await editor.load { _ in response(200,
            #"{"index_templates":[{"name":"logs","index_template":{"index_patterns":["logs-*"]}}]}"#) }
        editor.select(try #require(editor.templates.first))
        await editor.validate()
        let original = editor.input
        editor.input.source = #"{"index_patterns":["changed-*"]}"#
        await editor.validate()
        #expect(editor.hasChanges && editor.canSave)
        editor.discard()
        #expect(editor.input == original)
        #expect(!editor.hasChanges)
    }

    @Test(arguments: [1, 2]) @MainActor
    func updatingPriorityPreservesTheExplicitVersion(version: Int) async throws {
        let editor = WorkspaceElasticsearchIndexTemplateEditor()
        await editor.load { _ in response(200,
            #"{"index_templates":[{"name":"version-test","index_template":{"index_patterns":["version-test-*"],"priority":60,"version":1}}]}"#) }
        editor.select(try #require(editor.templates.first))
        editor.input.source = "{\"index_patterns\":[\"version-test-*\"],\"priority\":70,\"version\":\(version)}"
        await editor.formatSource()
        await editor.validate()
        let prepared = try #require(editor.preparedSave)
        let body = try #require(prepared.request.body)
        let submitted = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(submitted["priority"] as? Int == 70)
        #expect(submitted["version"] as? Int == version)
        await editor.submit(prepared, commit: { mutation in
            #expect(mutation == prepared)
            return response(200, #"{"acknowledged":true}"#)
        }, execute: { _ in
            response(200, "{\"index_templates\":[{\"name\":\"version-test\",\"index_template\":\(String(decoding: body, as: UTF8.self))}]}")
        })
        let loaded = try #require(JSONSerialization.jsonObject(with: Data(editor.input.source.utf8)) as? [String: Any])
        #expect(loaded["priority"] as? Int == 70)
        #expect(loaded["version"] as? Int == version)
        #expect(!editor.hasChanges)
    }

    @Test @MainActor func editingInvalidatesThePreviousPreparedBodyBeforeValidation() async throws {
        let editor = WorkspaceElasticsearchIndexTemplateEditor()
        editor.beginCreating()
        editor.input = .init(name: "version-test", source: #"{"index_patterns":["version-test-*"],"version":1}"#)
        await editor.validate()
        let previous = try #require(editor.preparedSave)
        editor.input.source = #"{"index_patterns":["version-test-*"],"version":2}"#
        #expect(editor.preparedSave == nil)
        #expect(!editor.canSave)
        var didCommit = false
        await editor.submit(previous, commit: { _ in
            didCommit = true
            return response(200, #"{"acknowledged":true}"#)
        }, execute: { _ in response(200, #"{"index_templates":[]}"#) })
        #expect(!didCommit)
        await editor.validate()
        #expect(editor.canSave)
        #expect(editor.preparedSave?.request.body == Data(editor.input.source.utf8))
    }

    @Test @MainActor func acknowledgedSaveReloadsAndKeepsTheSavedSelection() async throws {
        let editor = WorkspaceElasticsearchIndexTemplateEditor()
        editor.beginCreating()
        editor.input = .init(name: "new-template", source: #"{"index_patterns":["new-*"]}"#)
        await editor.validate()
        let prepared = try #require(editor.preparedSave)
        var committed: [WorkspaceRequest] = []
        await editor.submit(prepared, commit: { request in
            committed.append(request.request)
            return response(200, #"{"acknowledged":true}"#)
        }, execute: { request in
            #expect(request.method == .get && request.path == "/_index_template")
            return response(200,
                #"{"index_templates":[{"name":"new-template","index_template":{"index_patterns":["new-*"]}}]}"#)
        })
        #expect(committed == [prepared.request])
        #expect(editor.selectedName == "new-template")
        #expect(!editor.hasChanges && !editor.isBusy)
        #expect(editor.message?.contains("保存") == true || editor.message?.contains("saved") == true)
    }
}

private func response(_ status: Int, _ body: String = "{}") -> WorkspaceRequestExecutionResult {
    .init(statusCode: status, contentType: "application/json", body: Data(body.utf8))
}
