import Foundation
import Observation

struct WorkspaceElasticsearchConsoleResult: Identifiable, Sendable {
    let id = UUID()
    let request: WorkspaceRequest
    let statusCode: Int?
    let output: WorkspaceElasticsearchConsoleOutput?
    let errorMessage: String?
    let elapsedSeconds: Double
    let details: WorkspaceElasticsearchResponseDetails?
    let sourceRevision: UUID?

    init(request: WorkspaceRequest, statusCode: Int?, output: WorkspaceElasticsearchConsoleOutput?,
         errorMessage: String?, elapsedSeconds: Double,
         details: WorkspaceElasticsearchResponseDetails? = nil, sourceRevision: UUID? = nil) {
        self.request = request
        self.statusCode = statusCode
        self.output = output
        self.errorMessage = errorMessage
        self.elapsedSeconds = elapsedSeconds
        self.details = details
        self.sourceRevision = sourceRevision
    }

    var requestSummary: String {
        let isAdapted = request.method == .get && request.body?.isEmpty == false
            && (try? WorkspaceReadOnlyRequestValidator.validate(request)) != nil
        let method = isAdapted ? "GET → POST" : request.method.rawValue
        return "\(method) \(request.path)"
    }
}

@MainActor
@Observable
final class WorkspaceElasticsearchRequestDocumentModel: Identifiable {
    typealias Executor = @Sendable (WorkspaceRequest) async throws
        -> WorkspaceRequestExecutionResult

    let id: UUID
    private(set) var title: String
    var source: String { didSet { sourceRevision = UUID() } }
    private(set) var sourceRevision = UUID()
    private(set) var navigationRequest: WorkspaceElasticsearchEditorNavigationRequest?
    var selectedRange = NSRange(location: 0, length: 0)
    var resultRowLimit = QueryResultRowLimit.rows1_000
    private(set) var results: [WorkspaceElasticsearchConsoleResult] = []
    private(set) var isExecuting = false
    private(set) var isSaving = false
    private(set) var savedQueryID: SavedQuery.ID?
    var selectedResultIndex = 0
    private(set) var editorErrorMessage: String?
    private(set) var pendingConfirmation: [ElasticsearchConsoleParsedRequest]?
    @ObservationIgnored private var pendingSource: (text: String, revision: UUID)?
    @ObservationIgnored var authorize: @MainActor ([WorkspaceRequest]) throws -> Void = { requests in
        for request in requests { try WorkspaceReadOnlyRequestValidator.validate(request) }
    }
    @ObservationIgnored var batchDidWrite: @MainActor () async -> Void = {}
    @ObservationIgnored private let worker = WorkspaceElasticsearchConsoleWorker()

    @ObservationIgnored private let execute: Executor
    @ObservationIgnored private let completionFields: @MainActor (String?) async
        -> [String]
    @ObservationIgnored private let completionResources: @MainActor ()
        -> [WorkspaceElasticsearchCompletionResource]
    @ObservationIgnored private var saveAction: @MainActor @Sendable () -> Void = {}
    @ObservationIgnored private var persistedSource: String
    @ObservationIgnored private var formatTask: Task<Void, Never>?
    @ObservationIgnored private let responseConversionWorker =
        WorkspaceElasticsearchResponseConversionWorker()
    @ObservationIgnored private var executionTask: Task<Void, Never>?

    init(
        id: UUID = UUID(),
        title: String,
        source: String = "GET /_cluster/health",
        savedQueryID: SavedQuery.ID? = nil,
        persistedSource: String = "",
        completionFields: @escaping @MainActor (String?) async -> [String] = {
            _ in []
        },
        completionResources: @escaping @MainActor ()
            -> [WorkspaceElasticsearchCompletionResource] = { [] },
        execute: @escaping Executor
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.savedQueryID = savedQueryID
        self.persistedSource = persistedSource
        self.completionFields = completionFields
        self.completionResources = completionResources
        self.execute = execute
    }

    func completionFieldNames(for resourceName: String?) async -> [String] {
        await completionFields(resourceName)
    }
    func completionResourceNames() -> [WorkspaceElasticsearchCompletionResource] {
        completionResources()
    }

    var isDirty: Bool { source != persistedSource }
    var canSave: Bool { !isSaving && !isExecuting && isDirty }

    func configureSaveAction(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        saveAction = action
    }

    func requestSave() { saveAction() }

    func beginSaving() -> Bool {
        guard canSave else { return false }
        isSaving = true
        return true
    }

    func finishSaving(_ query: SavedQuery?) {
        defer { isSaving = false }
        guard let query else { return }
        title = query.name
        savedQueryID = query.id
        persistedSource = query.sql
    }

    func detachFromSavedQuery() {
        savedQueryID = nil
        persistedSource = ""
    }

    var restorationState: WorkspaceElasticsearchRequestRestorationState {
        WorkspaceElasticsearchRequestRestorationState(
            id: id,
            title: title,
            source: source,
            resultRowLimit: resultRowLimit,
            savedQueryID: savedQueryID,
            persistedSource: persistedSource
        )
    }

    func runCurrent() {
        prepareRun(selection: selectedRange)
    }

    func runAll() {
        prepareRun(selection: nil)
    }

    func stop() {
        executionTask?.cancel()
        formatTask?.cancel()
        pendingConfirmation = nil
        pendingSource = nil
    }

    func format() {
        formatTask?.cancel()
        let original = source
        formatTask = Task { [weak self] in
            guard let self else { return }
            do {
                let formatted = try await worker.formatted(original)
                try Task.checkCancellation()
                guard source == original else { return }
                source = formatted
                selectedRange = NSRange(location: min(selectedRange.location, (formatted as NSString).length), length: 0)
                editorErrorMessage = nil
            } catch is CancellationError {} catch {
                if source == original { editorErrorMessage = error.localizedDescription }
            }
        }
    }

    func dismissEditorError() {
        editorErrorMessage = nil
    }

    func confirmExecution() {
        guard let requests = pendingConfirmation, let snapshot = pendingSource else { return }
        pendingConfirmation = nil
        pendingSource = nil
        run(requests, source: snapshot.text, revision: snapshot.revision)
    }

    func cancelConfirmation() { pendingConfirmation = nil; pendingSource = nil }

    func canLocateError(in result: WorkspaceElasticsearchConsoleResult) -> Bool {
        result.sourceRevision == sourceRevision
            && result.details?.diagnostics.contains(where: { $0.documentRange != nil }) == true
    }

    func locateError(in result: WorkspaceElasticsearchConsoleResult) {
        guard canLocateError(in: result),
              let range = result.details?.diagnostics.compactMap(\.documentRange).first else { return }
        selectedRange = range
        navigationRequest = .init(range: range)
    }

    private func prepareRun(selection: NSRange?) {
        guard !isExecuting, pendingConfirmation == nil else { return }
        let source = source
        let revision = sourceRevision
        isExecuting = true
        editorErrorMessage = nil
        executionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let requests = try await worker.requests(source: source, selection: selection)
                try Task.checkCancellation()
                try authorize(requests.map(\.request))
                isExecuting = false
                executionTask = nil
                if ApplicationPreferences.shared.confirmsDangerousSQL,
                   requests.contains(where: { WorkspaceRequestClassifier.requiresDangerousConfirmation($0.request) }) {
                    pendingConfirmation = requests
                    pendingSource = (source, revision)
                } else { run(requests, source: source, revision: revision) }
            } catch {
                if !(error is CancellationError) { editorErrorMessage = error.localizedDescription }
                isExecuting = false
                executionTask = nil
            }
        }
    }

    private func run(_ requests: [ElasticsearchConsoleParsedRequest], source: String, revision: UUID) {
        guard !isExecuting, !requests.isEmpty else { return }
        do { try authorize(requests.map(\.request)) }
        catch { editorErrorMessage = error.localizedDescription; return }
        executionTask?.cancel()
        editorErrorMessage = nil
        isExecuting = true
        let maximumRows = resultRowLimit.maximumRows ?? 100_000
        let execute = self.execute
        let responseConversionWorker = self.responseConversionWorker
        executionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isExecuting = false
                executionTask = nil
            }
            var attemptedWrite = false
            var completed = 0
            var receivedResults: [WorkspaceElasticsearchConsoleResult] = []
            @MainActor func appendResult(_ result: WorkspaceElasticsearchConsoleResult) {
                receivedResults.append(result)
                results = receivedResults
                if receivedResults.count == 1 { selectedResultIndex = 0 }
            }
            for parsed in requests {
                if Task.isCancelled { break }
                let clock = ContinuousClock()
                let start = clock.now
                var sentWrite = false
                do {
                    try authorize([parsed.request])
                    let isWrite = WorkspaceRequestClassifier.requiresWriteAccess(parsed.request)
                    attemptedWrite = attemptedWrite || isWrite
                    sentWrite = isWrite
                    let response = try await execute(parsed.request)
                    // Own and await conversion of an acknowledged write even after Stop.
                    let conversion = Task {
                        try await responseConversionWorker.analyze(from: response, maximumRows: maximumRows,
                            parsed: parsed, source: source)
                    }
                    let analyzed = try await withTaskCancellationHandler {
                        try await conversion.value
                    } onCancel: { if !isWrite { conversion.cancel() } }
                    let failure = analyzed.details.failureMessage
                    let accepted = analyzed.details.acceptedTask.map {
                        AppCopy.current.text("已接受，任务 \($0)", "Accepted, task \($0)")
                    }
                    appendResult(
                        WorkspaceElasticsearchConsoleResult(
                            request: parsed.request,
                            statusCode: response.statusCode,
                            output: analyzed.output,
                            errorMessage: failure ?? accepted,
                            elapsedSeconds: Self.elapsed(from: start, clock: clock),
                            details: analyzed.details,
                            sourceRevision: revision
                        )
                    )
                    completed += 1
                    if failure != nil { break }
                } catch is CancellationError {
                    if sentWrite {
                        appendResult(.init(request: parsed.request, statusCode: nil, output: nil,
                            errorMessage: AppCopy.current.text("请求已停止，写入结果不确定；请检查服务器状态，不要直接重复执行。", "Stopped; write outcome is uncertain. Check server state before running again."), elapsedSeconds: Self.elapsed(from: start, clock: clock)))
                        completed += 1
                    }
                    break
                } catch {
                    appendResult(
                        WorkspaceElasticsearchConsoleResult(
                            request: parsed.request,
                            statusCode: nil,
                            output: nil,
                            errorMessage: error.localizedDescription + (sentWrite && !(error is WorkspaceElasticsearchRequestNotSentError)
                                ? AppCopy.current.text(" 写入结果可能不确定，请核对服务器状态。", " Write outcome may be uncertain; check server state.") : ""),
                            elapsedSeconds: Self.elapsed(from: start, clock: clock)
                        )
                    )
                    completed += 1
                    break
                }
            }
            for parsed in requests.dropFirst(completed) {
                appendResult(.init(request: parsed.request, statusCode: nil, output: nil,
                    errorMessage: AppCopy.current.text("未执行", "Not Executed"), elapsedSeconds: 0))
            }
            if attemptedWrite {
                // Reconciliation must finish even if Stop canceled the sending task.
                let refresh = Task { await batchDidWrite() }
                await refresh.value
            }
        }
    }

    private static func elapsed(
        from start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> Double {
        let components = start.duration(to: clock.now).components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
