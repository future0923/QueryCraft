import Foundation
import Observation

@MainActor @Observable
final class WorkspaceElasticsearchTemplateSimulationModel {
    private(set) var result: WorkspaceElasticsearchTemplateSimulationResult?
    private(set) var isLoading = false
    private(set) var error: String?
    private var revision = UUID()
    private let worker = WorkspaceElasticsearchTemplateSimulationWorker()

    func cancel() {
        revision = UUID()
        isLoading = false
    }

    func load(indexName: String,
              execute: @MainActor (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult) async {
        let current = UUID()
        revision = current
        isLoading = true
        error = nil
        defer { if revision == current { isLoading = false } }
        do {
            let request = try await worker.request(indexName: indexName)
            try Task.checkCancellation()
            guard revision == current else { return }
            // Candidate names need only patterns and priority, not every template's Mapping.
            let templates = try await execute(.init(method: .get, path:
                "/_index_template?filter_path=index_templates.name,index_templates.index_template.index_patterns,index_templates.index_template.priority"))
            try Task.checkCancellation()
            guard revision == current else { return }
            let response = try await execute(request)
            try Task.checkCancellation()
            guard revision == current else { return }
            let loaded = try await worker.result(indexName: indexName, response: response, templates: templates)
            try Task.checkCancellation()
            guard revision == current else { return }
            result = loaded
            error = loaded.error
        } catch is CancellationError {
        } catch {
            guard revision == current, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
