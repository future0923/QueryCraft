import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceElasticsearchTemplateSimulationTests {
    private let catalog = #"""
    {"index_templates":[
      {"name":"low","index_template":{"index_patterns":["qc-*"]}},
      {"name":"winner","index_template":{"index_patterns":["qc-prod-*"],"priority":100}},
      {"name":"other","index_template":{"index_patterns":["unrelated-*"]}},
      {"name":"not-a-regex","index_template":{"index_patterns":["qc.prod-*"]}}
    ]}
    """#
    private let simulated = #"""
    {"template":{"settings":{"index":{"number_of_replicas":"0"}},
      "mappings":{"properties":{"count":{"type":"integer"}}},
      "aliases":{"qc-read":{}}},"overlapping":[{"name":"low","index_patterns":["qc-*"]}]}
    """#

    @Test func onlyTheExactSimulationPOSTIsReadOnly() throws {
        let request = WorkspaceRequest(method: .post, path: "/_index_template/_simulate_index/qc-prod-1")
        try WorkspaceRequestClassifier.validate(request, policy: .readOnly)
        #expect(!WorkspaceRequestClassifier.requiresWriteAccess(request))
        #expect(!WorkspaceRequestClassifier.requiresDangerousConfirmation(request))
        for path in ["/_index_template/foo", "/_index_template/_simulate_index/", "/_index_template/_simulate_index/x/_delete",
                     "/admin/_index_template/_simulate_index/x", "/_index_template/_simulate_index/a%2Fb",
                     "https://example.com/_index_template/_simulate_index/x"] {
            #expect(throws: WorkspaceReadOnlyRequestValidationError.self) {
                try WorkspaceRequestClassifier.validate(.init(method: .post, path: path), policy: .readOnly)
            }
        }
        // A POST-only simulation route does not become a GET-body compatibility route.
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) {
            try WorkspaceRequestClassifier.validate(.init(method: .get, path: request.path, body: Data("{}".utf8)), policy: .writesAllowed)
        }
        #expect(WorkspaceRequestClassifier.requiresWriteAccess(.init(method: .put, path: "/_index_template/x")))
    }

    @Test func constructsOneEncodedConcreteIndexPath() async throws {
        let request = try await WorkspaceElasticsearchTemplateSimulationWorker().request(indexName: "日志-2026.09")
        #expect(request.method == .post && request.body == nil)
        #expect(request.path.removingPercentEncoding == "/_index_template/_simulate_index/日志-2026.09")
    }

    @Test(arguments: ["", "Logs", "logs-*", "logs/a", "a b", "a,b", "..", "_x", "+x", "-x", "a?b", "a#b", "a:b", String(repeating: "a", count: 256)])
    func rejectsNamesThatAreNotConcreteIndices(_ name: String) async {
        await #expect(throws: (any Error).self) {
            try await WorkspaceElasticsearchTemplateSimulationWorker().request(indexName: name)
        }
    }

    @Test func showsServerMergedSectionsAndPrioritizedMatches() async throws {
        let result = try await WorkspaceElasticsearchTemplateSimulationWorker().result(indexName: "qc-prod-1",
            response: response(simulated), templates: response(catalog))
        #expect(result.hasTemplate)
        #expect(result.matchedTemplates == ["winner", "low"])
        #expect(result.settings.contains("number_of_replicas"))
        #expect(result.mappings.contains("integer"))
        #expect(result.aliases.contains("qc-read"))
        #expect(result.response.contains("overlapping"))
    }

    @Test func emptyResponseMeansNoComposableMatch() async throws {
        let result = try await WorkspaceElasticsearchTemplateSimulationWorker().result(indexName: "none-1",
            response: response("{}"), templates: response(catalog))
        #expect(!result.hasTemplate && result.matchedTemplates.isEmpty)
        #expect(result.settings == "{}" && result.error == nil)
    }

    @Test func preservesHTTPErrorDetails() async throws {
        let result = try await WorkspaceElasticsearchTemplateSimulationWorker().result(indexName: "qc-prod-1",
            response: response(#"{"error":{"reason":"missing manage_index_templates"}}"#, status: 403), templates: response(catalog))
        #expect(result.error?.contains("403") == true)
        #expect(result.response.contains("missing manage_index_templates"))
        #expect(!result.hasTemplate)
    }

    @Test func formatsLargeServerMappingAndEmptyFilteredCatalog() async throws {
        let fields = (0..<10_000).map { "\"field\($0)\":{\"type\":\"keyword\"}" }.joined(separator: ",")
        let body = "{\"template\":{\"mappings\":{\"properties\":{\(fields)}}}}"
        let result = try await WorkspaceElasticsearchTemplateSimulationWorker().result(indexName: "qc-prod-1",
            response: response(body), templates: response(catalog))
        #expect(result.mappings.contains("field9999"))
        #expect(result.mappings.contains("\n"))
        let unmatched = try await WorkspaceElasticsearchTemplateSimulationWorker().result(indexName: "none-1",
            response: response("{}"), templates: response("{}"))
        #expect(!unmatched.hasTemplate && unmatched.matchedTemplates.isEmpty)
    }

    @Test(arguments: [false, true]) @MainActor
    func cancelledAndSupersededResponsesCannotReplaceTheCurrentResult(cancelTask: Bool) async {
        let model = WorkspaceElasticsearchTemplateSimulationModel()
        let gate = SimulationResponseGate()
        let old = Task { await model.load(indexName: "qc-old-1") { request in
            if request.method == .get { return response(catalog) }
            await gate.suspend()
            return response(simulated)
        } }
        await gate.waitUntilRequested()
        #expect(model.isLoading)
        model.cancel()
        if cancelTask { old.cancel() }
        await model.load(indexName: "qc-prod-1") { request in
            response(request.method == .get ? catalog : simulated)
        }
        gate.release()
        await old.value
        #expect(model.result?.indexName == "qc-prod-1")
        #expect(model.error == nil && !model.isLoading)
    }

    @Test @MainActor func invalidInputDoesNotSendRequestsAndKeepsThePreviousResult() async {
        let model = WorkspaceElasticsearchTemplateSimulationModel()
        await model.load(indexName: "qc-prod-1") { request in response(request.method == .get ? catalog : simulated) }
        let original = model.result
        var sent = false
        await model.load(indexName: "BAD*") { _ in sent = true; return response("{}") }
        #expect(!sent)
        #expect(model.result == original && model.error != nil && !model.isLoading)
    }

    private func response(_ body: String, status: Int = 200) -> WorkspaceRequestExecutionResult {
        .init(statusCode: status, contentType: "application/json", body: Data(body.utf8))
    }
}

@MainActor private final class SimulationResponseGate {
    private var responseContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var requested = false

    func suspend() async {
        await withCheckedContinuation { continuation in
            responseContinuation = continuation
            requested = true
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func release() {
        responseContinuation?.resume()
        responseContinuation = nil
    }
}
