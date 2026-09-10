import Foundation
import Observation

@MainActor @Observable
final class WorkspaceElasticsearchIndexTemplateEditor {
    private(set) var templates: [WorkspaceElasticsearchIndexTemplateSnapshot] = []
    private(set) var baseline: WorkspaceElasticsearchIndexTemplateSnapshot?
    private(set) var isCreating = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var preparedSave: WorkspacePreparedElasticsearchIndexTemplateMutation?
    private(set) var preparedDeletion: WorkspacePreparedElasticsearchIndexTemplateMutation?
    private(set) var validationMessage: String?
    private(set) var message: String?
    private(set) var responseText = ""
    private(set) var lastSubmissionMayHaveReachedServer = false
    var input = WorkspaceElasticsearchIndexTemplateInput() {
        didSet {
            guard input != oldValue else { return }
            // Validation is asynchronous. Never let Save/Preview use the
            // previous body in the interval before the new revision validates.
            preparedSave = nil
            preparedDeletion = nil
            validationMessage = nil
        }
    }
    var searchText = ""

    private let worker = WorkspaceElasticsearchIndexTemplateWorker()

    var isBusy: Bool { isLoading || isSaving }
    var selectedName: String? { baseline?.name }
    var hasSelection: Bool { baseline != nil || isCreating }
    var hasChanges: Bool {
        if isCreating { return !input.name.isEmpty || input.source != Self.newTemplateSource }
        guard let baseline else { return false }
        return input.name != baseline.name || input.source != baseline.source
    }
    var canSave: Bool { !isBusy && preparedSave != nil }
    var canDelete: Bool { !isBusy && baseline != nil && preparedDeletion != nil && !hasChanges }
    var visibleTemplates: [WorkspaceElasticsearchIndexTemplateSnapshot] {
        guard !searchText.isEmpty else { return templates }
        return templates.filter {
            CompletionLabelMatcher.match(label: $0.name, query: searchText) != nil
                || $0.indexPatterns.contains {
                    CompletionLabelMatcher.match(label: $0, query: searchText) != nil
                }
        }
    }

    func load(
        preferredName: String? = nil,
        execute: @MainActor (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult
    ) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await execute(await worker.listRequest)
            let loaded = try await worker.templates(from: response)
            try Task.checkCancellation()
            templates = loaded
            if let preferredName, let selected = loaded.first(where: { $0.name == preferredName }) {
                applySelection(selected)
            } else if let name = baseline?.name, let refreshed = loaded.first(where: { $0.name == name }), !hasChanges {
                applySelection(refreshed)
            } else if baseline != nil, !hasChanges {
                clearSelectionForReload()
            }
        } catch is CancellationError {
        } catch {
            message = error.localizedDescription
        }
    }

    func select(_ template: WorkspaceElasticsearchIndexTemplateSnapshot) {
        guard !isBusy else { return }
        applySelection(template)
    }

    private func applySelection(_ template: WorkspaceElasticsearchIndexTemplateSnapshot) {
        baseline = template
        isCreating = false
        input = .init(name: template.name, source: template.source)
        validationMessage = nil
        preparedSave = nil
        preparedDeletion = nil
        message = nil
        responseText = ""
    }

    func beginCreating() {
        guard !isBusy else { return }
        baseline = nil
        isCreating = true
        input = .init(source: Self.newTemplateSource)
        preparedSave = nil
        preparedDeletion = nil
        validationMessage = nil
        message = nil
        responseText = ""
    }

    func discard() {
        guard !isBusy else { return }
        if let baseline { select(baseline) } else { clearSelection() }
    }

    func clearSelection() {
        guard !isBusy else { return }
        baseline = nil
        isCreating = false
        input = .init()
        preparedSave = nil
        preparedDeletion = nil
        validationMessage = nil
        message = nil
        responseText = ""
    }

    func validate() async {
        guard hasSelection else { return }
        let capturedInput = input
        let capturedBaseline = baseline
        do {
            let prepared = try await worker.prepareSave(input: capturedInput, baseline: capturedBaseline)
            try Task.checkCancellation()
            guard input == capturedInput, baseline == capturedBaseline else { return }
            preparedSave = prepared
            validationMessage = nil
        } catch is CancellationError {
        } catch WorkspaceElasticsearchIndexTemplateError.noChanges {
            guard input == capturedInput, baseline == capturedBaseline else { return }
            let deletion: WorkspacePreparedElasticsearchIndexTemplateMutation? = if let capturedBaseline {
                try? await worker.prepareDeletion(capturedBaseline)
            } else { nil }
            guard !Task.isCancelled, input == capturedInput, baseline == capturedBaseline else { return }
            if let capturedBaseline { input.source = capturedBaseline.source }
            preparedSave = nil
            preparedDeletion = deletion
            validationMessage = nil
        } catch {
            guard input == capturedInput, baseline == capturedBaseline else { return }
            preparedSave = nil
            validationMessage = error.localizedDescription
        }
    }

    func formatSource() async {
        guard hasSelection, !isBusy else { return }
        let source = input.source
        do {
            let formatted = try await worker.formatted(source)
            try Task.checkCancellation()
            guard input.source == source else { return }
            input.source = formatted
        } catch is CancellationError {
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    func submit(
        _ prepared: WorkspacePreparedElasticsearchIndexTemplateMutation,
        commit: @MainActor (WorkspacePreparedElasticsearchIndexTemplateMutation) async throws
            -> WorkspaceRequestExecutionResult,
        execute: @MainActor (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult
    ) async {
        guard !isBusy else { return }
        if prepared.operation == .save {
            guard preparedSave == prepared else { return }
        } else {
            guard preparedDeletion == prepared else { return }
        }
        isSaving = true
        message = nil
        responseText = ""
        lastSubmissionMayHaveReachedServer = false
        defer { isSaving = false }
        do {
            let response = try await commit(prepared)
            lastSubmissionMayHaveReachedServer = true
            responseText = await worker.responseText(response)
            switch await worker.outcome(response) {
            case .acknowledged:
                await reloadAfterAcknowledgement(prepared, execute: execute)
            case .rejected:
                message = AppCopy.current.text(
                    "服务器拒绝了请求（HTTP \(response.statusCode)），输入已保留。",
                    "The server rejected the request (HTTP \(response.statusCode)); your input is preserved."
                )
            case .uncertain:
                await reconcile(prepared, execute: execute)
            }
        } catch let error as WorkspaceElasticsearchIndexTemplateNotSentError {
            message = error.localizedDescription
        } catch is CancellationError {
            lastSubmissionMayHaveReachedServer = true
            await reconcile(prepared, execute: execute)
        } catch {
            lastSubmissionMayHaveReachedServer = true
            message = error.localizedDescription
            await reconcile(prepared, execute: execute)
        }
    }

    private func reloadAfterAcknowledgement(
        _ prepared: WorkspacePreparedElasticsearchIndexTemplateMutation,
        execute: @MainActor (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult
    ) async {
        isLoading = false
        switch prepared.operation {
        case .save:
            await load(preferredName: prepared.input.name, execute: execute)
            message = AppCopy.current.text("索引模板已保存。", "Index template saved.")
        case .delete:
            clearSelectionForReload()
            await load(execute: execute)
            message = AppCopy.current.text("索引模板已删除。", "Index template deleted.")
        }
    }

    private func reconcile(
        _ prepared: WorkspacePreparedElasticsearchIndexTemplateMutation,
        execute: @MainActor (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult
    ) async {
        isLoading = false
        let originalInput = input
        let originalBaseline = baseline
        clearSelectionForReload()
        await load(execute: execute)
        let server = templates.first(where: { $0.name == prepared.input.name })
        let completed: Bool
        switch prepared.operation {
        case .save:
            completed = if let server {
                (try? await worker.bodyMatches(server, input: prepared.input)) == true
            } else { false }
        case .delete:
            completed = server == nil
        }
        if completed {
            if let server { applySelection(server) }
            message = prepared.operation == .save
                ? AppCopy.current.text("已核实索引模板保存成功。", "Index template save was verified.")
                : AppCopy.current.text("已核实索引模板已删除。", "Index template deletion was verified.")
        } else {
            baseline = originalBaseline
            isCreating = originalBaseline == nil
            input = originalInput
            preparedSave = prepared.operation == .save ? prepared : nil
            preparedDeletion = prepared.operation == .delete ? prepared : preparedDeletion
            message = WorkspaceElasticsearchIndexTemplateError.uncertain.localizedDescription
        }
    }

    private func clearSelectionForReload() {
        baseline = nil
        isCreating = false
        input = .init()
        preparedSave = nil
        preparedDeletion = nil
        validationMessage = nil
    }

    private static let newTemplateSource = """
        {
          "index_patterns" : [
            "logs-*"
          ],
          "template" : {
            "settings" : {},
            "mappings" : {
              "properties" : {}
            },
            "aliases" : {}
          }
        }
        """
}
