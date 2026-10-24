import Foundation
import Observation
import QueryCraftMobileCore

struct MobileElasticsearchConsoleResult: Identifiable {
    let id = UUID()
    let request: WorkspaceRequest
    let response: WorkspaceRequestExecutionResult
    let output: WorkspaceElasticsearchConsoleOutput?
    let details: WorkspaceElasticsearchResponseDetails
    let sourceID: UUID?
}
struct MobileElasticsearchCompletion: Identifiable {
    let label: String
    let insertion: String
    let range: NSRange
    let selection: NSRange?
    var id: String { label + "\(range.location):\(range.length)" }
}
@MainActor @Observable final class MobileElasticsearchConsole {
    unowned let owner: MobileElasticsearchWorkspace
    var source = "GET /_cluster/health" { didSet { if oldValue != source { sourceID = UUID() }; invalidate(); scheduleCompletion() } }
    var selection = NSRange(location: 0, length: 0) { didSet { if oldValue != selection { invalidate() }; scheduleCompletion() } }
    var markedText = false
    var scope = "current" { didSet { invalidate() } }
    private(set) var results: [MobileElasticsearchConsoleResult] = []
    var selectedResult = 0
    var showsJSON = false
    private(set) var preview: String?
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var isWriting = false
    private(set) var needsVerification = false
    private(set) var verified = false
    private(set) var verificationText = ""
    private(set) var message: String?
    private(set) var completions: [MobileElasticsearchCompletion] = []
    private(set) var history: [String] = []
    private(set) var isBackgrounded = false
    @ObservationIgnored private var sourceID = UUID()
    @ObservationIgnored private var preparedParsed: [ElasticsearchConsoleParsedRequest]?
    @ObservationIgnored private var preparedText: String?
    @ObservationIgnored private var prepared: [WorkspaceRequest]?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var preparedRevision: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var completionID = UUID()
    @ObservationIgnored private var lastRead: [WorkspaceRequest]?
    private let worker = WorkspaceElasticsearchConsoleWorker()
    private let dsl = WorkspaceElasticsearchDSLCompletionWorker()
    var hasPendingChanges: Bool { isRunning || needsVerification || prepared != nil }
    var canRun: Bool { owner.action == nil && !owner.cellChanges.hasChanges && !isRunning && !isPreparing && !needsVerification && !isBackgrounded && !markedText }
    var currentResult: MobileElasticsearchConsoleResult? { results.indices.contains(selectedResult) ? results[selectedResult] : results.last }
    private var historyKey: String { "querycraft.es.history." + owner.profile.id.uuidString }
    init(owner: MobileElasticsearchWorkspace) {
        self.owner = owner
        history = UserDefaults.standard.stringArray(forKey: "querycraft.es.history." + owner.profile.id.uuidString) ?? []
    }
    func invalidate() { revision = UUID(); prepared = nil; preparedParsed = nil; preparedText = nil; preview = nil; preparedRevision = nil }
    @discardableResult func prepare() -> Task<Void, Never>? {
        guard canRun, source.utf8.count <= 1_048_576 else { message = "输入最多 1 MiB，且需结束输入法组合。"; return nil }
        invalidate(); let token = revision; let text = source; let selection = selection; let scope = scope
        isPreparing = true; message = nil
        return Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            do {
                let parsed = try await worker.requests(source: text, selection: scope == "all" ? nil : selection)
                let requests = parsed.map(\.request)
                let rendered = try await worker.previewSource(requests)
                try Task.checkCancellation(); guard token == revision, !isBackgrounded else { throw MobileElasticsearchFailure.stale }
                prepared = requests; preparedParsed = parsed; preparedText = text; preview = rendered; preparedRevision = token
            } catch { message = error.localizedDescription }
            isPreparing = false
        }
    }
    @discardableResult func run() -> Task<Void, Never>? {
        guard canRun, let prepared, preparedRevision == revision else { message = "请先预览当前请求。"; return nil }
        let writes = prepared.contains(where: WorkspaceRequestClassifier.requiresWriteAccess)
        guard !writes || !owner.safetyLock.isEnabled else { message = "请先解锁写入。"; return nil }
        let parsed = preparedParsed, text = preparedText, id = sourceID
        self.prepared = nil; preparedParsed = nil; preparedText = nil; preview = nil; preparedRevision = nil
        return execute(prepared, parsed: parsed, text: text, sourceID: id)
    }
    private func execute(_ requests: [WorkspaceRequest], verification: Bool = false, parsed: [ElasticsearchConsoleParsedRequest]? = nil, text: String? = nil, sourceID: UUID? = nil) -> Task<Void, Never>? {
        guard !isRunning, !isBackgrounded, (!needsVerification || verification), owner.action == nil, !owner.cellChanges.hasChanges else { return nil }
        guard !verification || requests.allSatisfy({ !WorkspaceRequestClassifier.requiresWriteAccess($0) }) else { return nil }
        let writes = requests.contains(where: WorkspaceRequestClassifier.requiresWriteAccess)
        if !writes { lastRead = requests }
        isRunning = true; isWriting = writes; message = nil
        let task = Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            var next: [MobileElasticsearchConsoleResult] = []
            var bytes = 0
            do {
                let service = try await owner.ready()
                for (index, request) in requests.enumerated() {
                    try Task.checkCancellation()
                    guard !isBackgrounded else { throw CancellationError() }
                    let writing = WorkspaceRequestClassifier.requiresWriteAccess(request)
                    guard !writing || !owner.safetyLock.isEnabled else { throw MobileElasticsearchFailure.rejected("安全锁已开启，后续请求未发送。") }
                    let response: WorkspaceRequestExecutionResult
                    do { response = try await service.executeRequest(request, policy: writing ? .writesAllowed : .readOnly) }
                    catch {
                        if writing, !MobileElasticsearchFailure.isDefinite(error) { needsVerification = true }
                        throw error
                    }
                    if writing { owner.didWrite(); if response.statusCode == 408 || response.statusCode >= 500 { needsVerification = true } }
                    let details = try WorkspaceElasticsearchResponseDetails.read(response: response, displayedRows: nil, parsed: parsed.flatMap { $0.indices.contains(index) ? $0[index] : nil }, source: text)
                    let output = try? ElasticsearchConsoleResponseConverter.output(from: response, maximumRows: 1_000)
                    bytes += response.body.count
                    guard bytes <= 33_554_432 else { throw MobileElasticsearchFailure.rejected("保留回复已达 32 MiB，后续请求未发送；已收到的结果保留。") }
                    next.append(.init(request: request, response: response, output: output, details: details, sourceID: sourceID))
                    results = next; selectedResult = next.count - 1
                    if !(200..<300).contains(response.statusCode) || details.failureMessage != nil {
                        message = details.failureMessage ?? "HTTP \(response.statusCode)，后续请求已停止。"; break
                    }
                }
                if verification, !next.isEmpty, next.allSatisfy({ (200..<300).contains($0.response.statusCode) && $0.details.failureMessage == nil }) { verified = true }
                if !next.isEmpty {
                    let text = try await worker.previewSource(requests)
                    history.removeAll { $0 == text }; history.insert(text, at: 0)
                    var budget = 0; history = Array(history.prefix(50).prefix { value in budget += value.utf8.count; return budget <= 1_048_576 })
                    UserDefaults.standard.set(history, forKey: historyKey)
                }
            } catch { message = needsVerification ? MobileElasticsearchFailure.uncertain.localizedDescription : error.localizedDescription }
            isRunning = false; isWriting = false; self.task = nil
            if isBackgrounded { owner.cancel() }
        }
        self.task = task; return task
    }
    func refresh() {
        guard !needsVerification else { verify(); return }
        guard let lastRead, !isRunning else { message = "刷新只重读已执行的读取请求。"; return }
        _ = execute(lastRead)
    }
    @discardableResult func format() -> Task<Void, Never>? {
        guard canRun, !markedText, source.utf8.count <= 1_048_576 else { return nil }
        let text = source, token = revision
        return Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            do { let result = try await worker.formatted(text); guard token == revision else { throw MobileElasticsearchFailure.stale }; source = result; selection = .init(location: 0, length: 0) }
            catch { message = error.localizedDescription }
        }
    }
    @discardableResult func verify() -> Task<Void, Never>? {
        guard needsVerification, !isRunning, !isBackgrounded else { return nil }
        isRunning = true; verified = false; let token = revision
        let pending = Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            do {
                let service = try await owner.ready()
                let response = try await service.executeRequest(.init(method: .get, path: "/_cluster/health"))
                try MobileElasticsearchFailure.accepted(response); try Task.checkCancellation()
                guard !isBackgrounded, token == revision else { throw CancellationError() }
                verificationText = String(decoding: response.body, as: UTF8.self)
                verified = true; message = "连接已核实；请用读取请求核对原操作影响后明确结束。连接正常不证明原写入成功。"
            } catch { message = error.localizedDescription }
            isRunning = false; task = nil
        }
        task = pending; return pending
    }
    @discardableResult func verifyCurrentRead() -> Task<Void, Never>? {
        guard needsVerification, !isRunning, !isPreparing, !isBackgrounded, !markedText else { return nil }
        let text = source, selection = selection, scope = scope, token = revision
        return Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            do {
                let parsed = try await worker.requests(source: text, selection: scope == "all" ? nil : selection)
                let requests = parsed.map(\.request)
                for request in requests { try WorkspaceRequestClassifier.validate(request, policy: .readOnly) }
                guard source == text, self.selection == selection, token == revision, !isBackgrounded else { throw MobileElasticsearchFailure.stale }
                await execute(requests, verification: true)?.value
            } catch { message = error.localizedDescription }
        }
    }
    func finishVerification() { guard verified, !isRunning else { return }; needsVerification = false; verified = false; invalidate(); owner.didWrite() }
    func cancel() { completionTask?.cancel(); completions = []; invalidate(); if !isWriting { task?.cancel() } }
    func waitForReadCancellation() async { await completionTask?.value; if !isWriting { await task?.value } }
    func setBackgrounded(_ value: Bool) { isBackgrounded = value; if value { cancel(); owner.safetyLock.enable() } }
    func scheduleCompletion() {
        completionTask?.cancel(); completionID = UUID(); let id = completionID
        guard !isBackgrounded, !markedText, !isRunning, source.utf8.count <= 1_048_576 else { completions = []; return }
        let text = source, range = selection
        completionTask = Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard !isBackgrounded else { return }
                let items = try await dsl.completions(source: text, cursor: range.location, fields: owner.mapping?.fieldCapabilities.map(\.path) ?? [], resources: (owner.catalog ?? []).map { .init(name: $0.name, kind: $0.kind) }, indentationUnit: "  ")
                try Task.checkCancellation(); guard id == completionID, source == text, selection == range else { return }
                completions = items.prefix(30).map { .init(label: $0.label, insertion: $0.insertionText, range: $0.replacementRange, selection: $0.selectedRangeInInsertion) }
                if completions.isEmpty { completions = requestCompletions(text: text, cursor: range.location) }
            } catch { if id == completionID { completions = [] } }
        }
    }
    func requestCompletions(text: String, cursor: Int) -> [MobileElasticsearchCompletion] {
        WorkspaceElasticsearchRequestCompletion.suggestions(source: text, cursor: cursor, resources: (owner.catalog ?? []).map { .init(name: $0.name, kind: $0.kind) })
            .map { .init(label: $0.label, insertion: $0.insertionText, range: $0.range, selection: $0.selection) }
    }
    func locate(_ diagnostic: WorkspaceElasticsearchConsoleDiagnostic) {
        guard currentResult?.sourceID == sourceID, let range = diagnostic.documentRange, NSMaxRange(range) <= source.utf16.count else { return }
        selection = range
    }
    func canLocate(_ diagnostic: WorkspaceElasticsearchConsoleDiagnostic) -> Bool { currentResult?.sourceID == sourceID && diagnostic.documentRange != nil }
    func openTask(_ id: String) { guard canRun else { return }; source = "GET /_tasks/" + MobileResourceService.pathComponent(id); selection = .init(location: 0, length: 0) }
    func accept(_ item: MobileElasticsearchCompletion) {
        guard !markedText, let range = Range(item.range, in: source) else { return }
        source.replaceSubrange(range, with: item.insertion)
        selection = item.selection.map { .init(location: item.range.location + $0.location, length: $0.length) } ?? .init(location: item.range.location + (item.insertion as NSString).length, length: 0)
    }
}
