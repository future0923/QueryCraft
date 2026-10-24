import Foundation
import Observation
import QueryCraftMobileCore

@MainActor @Observable final class MobileRedisEditor {
    let key: String
    let database: Int
    let safetyLock = WorkspaceSafetyLock()
    private let service: any MobileRedisMutating
    private(set) var snapshot: MobileRedisSnapshot?
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    private(set) var hasSubmittedAttempt = false
    private(set) var needsVerification = false
    private(set) var isBackgrounded = false
    private(set) var hasLoaded = false
    private(set) var message: String?
    private(set) var preview: String?
    var text = ""
    var usesHex = false
    private(set) var isValidatingString = false
    @ObservationIgnored private var stringTask: Task<Void, Never>?
    @ObservationIgnored private var stringGeneration = UUID()
    @ObservationIgnored private var cachedStringText: String?
    @ObservationIgnored private var cachedStringHex = false
    @ObservationIgnored private var cachedStringValue: RedisBinaryValue?
    private(set) var jsonPresentation: String?
    private(set) var isFormattingString = false
    var stringPresentation: String { jsonPresentation ?? text }
    private(set) var stringPageOffset = 0
    @ObservationIgnored private var stringPageHistory: [Int] = []
    private let stringSegmentBytes = 32_768
    var usesStringSegments: Bool { stringPresentation.utf8.count > 65_536 }
    var canGoToPreviousStringSegment: Bool { !stringPageHistory.isEmpty }
    var canGoToNextStringSegment: Bool { segmentRange(in: stringPresentation).end != stringPresentation.utf8.endIndex }
    private func segmentRange(in source: String) -> MobileTextSegment {
        .range(in: source, offset: stringPageOffset, maximumBytes: stringSegmentBytes)
    }
    var stringEditorText: String {
        let source = stringPresentation
        guard usesStringSegments else { return source }
        let range = segmentRange(in: source)
        return range.text(in: source)
    }
    func updateStringEditorText(_ value: String) {
        guard canEdit else { return }
        let source = stringPresentation
        guard usesStringSegments else { updateStringPresentation(value); return }
        let range = segmentRange(in: source)
        let updated = range.replacing(in: source, with: value)
        updateStringPresentation(updated)
    }
    func nextStringSegment() {
        guard canEdit, canGoToNextStringSegment else { return }
        let source = stringPresentation, range = segmentRange(in: stringPresentation)
        stringPageHistory.append(range.offset)
        stringPageOffset = source.utf8.distance(from: source.utf8.startIndex, to: range.end)
    }
    func previousStringSegment() {
        guard canEdit, let offset = stringPageHistory.popLast() else { return }
        stringPageOffset = offset
    }
    private func resetStringSegments() { stringPageOffset = 0; stringPageHistory = [] }
    func updateStringPresentation(_ value: String) {
        guard canEdit else { return }
        let wasSegmented = usesStringSegments
        text = value
        if jsonPresentation != nil { jsonPresentation = value }
        if !wasSegmented || !usesStringSegments { resetStringSegments() }
    }
    var stringExportData: Data? { try? currentString().data }
    func rawStringExport() async -> Data? {
        guard canEdit, !isValidatingString, snapshot?.stringData != nil else { return nil }
        if let cached = try? currentString() { return cached.data }
        let source = text, sourceHex = usesHex, token = generation, stringToken = UUID()
        stringGeneration = stringToken; isValidatingString = true
        do {
            let value = try await MobileRedisStringWorker().value(text: source, hex: sourceHex)
            try Task.checkCancellation()
            guard generation == token, stringGeneration == stringToken else { return nil }
            isValidatingString = false
            guard text == source, usesHex == sourceHex else { message = "草稿已改变，请重新导出。"; return nil }
            cachedStringText = source; cachedStringHex = sourceHex; cachedStringValue = value
            return value.data
        } catch {
            guard generation == token, stringGeneration == stringToken else { return nil }
            isValidatingString = false; message = error.localizedDescription; return nil
        }
    }
    @discardableResult func toggleJSONPresentation() -> Task<Void, Never>? {
        guard canEdit, !usesHex, !isFormattingString, !isValidatingString else { return nil }
        if jsonPresentation != nil { jsonPresentation = nil; resetStringSegments(); return nil }
        let source = text, token = generation
        isFormattingString = true
        return Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isFormattingString = false } }
            guard await self.rawStringExport() != nil else { return }
            let formatted = await RedisValueFormatter().formattedJSON(from: source, maximumOutputBytes: RedisStringEditingLimit.maximumBytes)
            guard !Task.isCancelled, self.generation == token, self.canEdit, self.text == source else { return }
            guard let formatted else { self.message = "当前内容不是 JSON 对象/数组，或格式化展示超出 100 MiB 上限。"; return }
            self.jsonPresentation = formatted; self.resetStringSegments()
        }
    }
    var rows: [RedisKeyEditableRow] = []
    private(set) var selectedRowIDs: Set<UUID> = []
    private(set) var isPreparingExport = false
    func selectAllRows() { guard canEdit else { return }; selectedRowIDs = Set(rows.filter { !$0.isDeleted }.map(\.id)) }
    func clearSelection() { selectedRowIDs = [] }
    func toggleSelection(_ id: UUID) {
        guard canEdit else { return }
        if !selectedRowIDs.insert(id).inserted { selectedRowIDs.remove(id) }
    }
    func removeSelectedRows() {
        guard canEdit else { return }
        let ids = rows.filter { selectedRowIDs.contains($0.id) && !$0.isDeleted && !$0.isBinaryReadOnly }.map(\.id)
        for id in ids { removeRow(id) }; selectedRowIDs = []
    }
    func commandExport(selectedOnly: Bool) async -> Data? {
        guard canEdit, let snapshot else { return nil }
        if !selectedOnly && (snapshot.isPartial || activeSearch != nil) { return nil }
        let selected = selectedOnly ? rows.filter { selectedRowIDs.contains($0.id) } : rows
        let data: RedisBinaryValue?
        if snapshot.stringData != nil {
            guard let bytes = await rawStringExport() else { return nil }
            data = .init(data: bytes)
        } else { data = nil }
        let token = generation; isPreparingExport = true
        let result = await RedisKeyCommandExportWorker().export(details: snapshot.details, stringData: data, rows: selected, wholeKey: !selectedOnly)
        guard generation == token, !Task.isCancelled else { isPreparingExport = false; return nil }
        isPreparingExport = false
        if result == nil { message = "没有可导出的有效成员。" }
        return result.map { Data($0.utf8) }
    }
    func exportFailed(_ error: Error) {
        if (error as? CocoaError)?.code != .userCancelled { message = error.localizedDescription }
    }
    var expirationMode = RedisKeyExpirationMode.persistent
    var ttl = ""
    var deleteKey = false
    let searchState = RedisCollectionRemoteSearchState()
    private(set) var activeSearch: RedisCollectionSearch?
    private(set) var isSearchPending = false
    @ObservationIgnored private var requestedSearch: RedisCollectionSearch?
    var canSearch: Bool {
        guard let type = snapshot?.details.reference.type else { return false }
        return !searchState.availableFields(for: type).isEmpty && !hasChanges && !needsVerification && !isSubmitting && !isBackgrounded
    }
    @discardableResult func applySearch(clear: Bool = false) -> Task<Void, Never>? {
        guard canSearch, let type = snapshot?.details.reference.type else { return nil }
        searchState.configure(for: type)
        if clear { searchState.clear() } else { searchState.submit() }
        requestedSearch = searchState.submittedSearch; isSearchPending = true
        return reload()
    }
    private(set) var pageNumber = 1
    @ObservationIgnored private var pageCursor: RedisCollectionContinuation?
    @ObservationIgnored private var pageHistory: [RedisCollectionContinuation?] = []
    var canTurnPage: Bool { canEdit && !hasChanges && !needsVerification && !isSearchPending }
    @discardableResult func nextPage() -> Task<Void, Never>? {
        guard canTurnPage, let cursor = snapshot?.continuation else { return nil }
        return reload(page: true, cursor: cursor, direction: 1)
    }
    @discardableResult func previousPage() -> Task<Void, Never>? {
        guard canTurnPage, !pageHistory.isEmpty else { return nil }
        return reload(page: true, cursor: pageHistory[pageHistory.count - 1], direction: -1)
    }
    @ObservationIgnored private var prepared: RedisOptimisticMutationRequest?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored var didWrite: (() -> Void)?

    init(key: String, database: Int, service: any MobileRedisMutating) {
        self.key = key; self.database = database; self.service = service
    }
    var hasChanges: Bool {
        guard let snapshot else { return false }
        let changedString = snapshot.stringData.map { original in
            if text.utf8.count > 65_536 && (cachedStringText != text || cachedStringHex != usesHex) { return true }
            return (try? currentString()) != original
        } ?? false
        return deleteKey || changedString || rows.contains { $0.changeState != .unchanged }
            || expirationMode != (snapshot.details.ttlMilliseconds == nil ? .persistent : .expires)
            || (expirationMode == .expires && ttl != snapshot.details.ttlMilliseconds.map(String.init) ?? "")
    }
    var canClose: Bool { !isSubmitting && !needsVerification }
    var canEdit: Bool { snapshot != nil && !isPreparingExport && !isSearchPending && !isLoading && !isSubmitting && !needsVerification && !isBackgrounded }
    var canSubmit: Bool { canEdit && !safetyLock.isEnabled && prepared != nil }

    // Only an explicit discard/verification action may replace a draft.
    @discardableResult func reload(discard: Bool = false, page: Bool = false, cursor: RedisCollectionContinuation? = nil, direction: Int = 0) -> Task<Void, Never>? {
        guard !isSubmitting, !isBackgrounded, discard || !hasChanges && !needsVerification else { return nil }
        stringTask?.cancel(); stringGeneration = UUID(); isValidatingString = false; isFormattingString = false
        task?.cancel(); generation = UUID(); let token = generation
        isLoading = true; message = nil; preview = nil; prepared = nil
        let resetSearch = isSearchPending
        let query = requestedSearch
        let usePage = page || snapshot?.isPartial == true || resetSearch || query != nil
        let targetCursor = resetSearch ? nil : (page ? cursor : pageCursor)
        let expectedType = snapshot?.details.reference.type
        let task = Task { [weak self, service, key, database] in
            do {
                let fresh = try await (usePage ? service.searchPage(key: key, database: database, continuation: targetCursor, search: query) : service.load(key: key, database: database))
                let presentation = try await MobileRedisStringWorker().presentation(value: fresh?.stringData)
                try Task.checkCancellation()
                if usePage, let fresh, let expectedType, fresh.details.reference.type != expectedType { throw RedisWorkspaceError.mutationConflict(key) }
                guard let self, self.generation == token else { return }
                if resetSearch { self.pageHistory = []; self.pageNumber = 1 }
                self.activeSearch = query; self.isSearchPending = false
                if direction > 0 { self.pageHistory.append(self.pageCursor); self.pageNumber += 1 }
                if direction < 0 { self.pageHistory.removeLast(); self.pageNumber -= 1 }
                self.pageCursor = targetCursor
                if let type = fresh?.details.reference.type { self.searchState.configure(for: type) }
                self.jsonPresentation = nil
                self.selectedRowIDs = []
                self.snapshot = fresh; self.hasLoaded = true; self.rows = fresh?.rows ?? []
                self.usesHex = presentation.hex; self.text = presentation.text
                self.cachedStringText = presentation.text; self.cachedStringHex = presentation.hex; self.cachedStringValue = fresh?.stringData
                self.expirationMode = fresh?.details.ttlMilliseconds == nil ? .persistent : .expires
                self.ttl = fresh?.details.ttlMilliseconds.map(String.init) ?? ""
                self.deleteKey = false; self.needsVerification = false; self.isLoading = false; self.task = nil
                if fresh == nil { self.message = "键已不存在。" }
            } catch {
                guard let self, self.generation == token else { return }
                self.isLoading = false; self.task = nil
                if !(error is CancellationError) { self.message = error.localizedDescription }
            }
        }
        self.task = task; return task
    }
    @discardableResult func switchFormat(_ hex: Bool) -> Task<Void, Never>? {
        guard canEdit, !isValidatingString, usesHex != hex else { return nil }
        let source = text, sourceHex = usesHex, token = generation, stringToken = UUID()
        stringGeneration = stringToken
        isValidatingString = true; prepared = nil; preview = nil
        let task = Task { [weak self] in
            do {
                let worker = MobileRedisStringWorker()
                let value = try await worker.value(text: source, hex: sourceHex)
                let presentation = try await worker.presentation(value: value, hex: hex)
                try Task.checkCancellation()
                guard let self, self.generation == token, self.stringGeneration == stringToken else { return }
                guard self.text == source, self.usesHex == sourceHex else { self.isValidatingString = false; return }
                self.usesHex = hex; self.text = presentation.text
                self.cachedStringText = self.text; self.cachedStringHex = hex; self.cachedStringValue = value
                self.jsonPresentation = nil; self.resetStringSegments(); self.message = nil; self.isValidatingString = false
            } catch {
                guard let self, self.generation == token, self.stringGeneration == stringToken else { return }
                self.isValidatingString = false; self.message = error.localizedDescription
            }
        }
        stringTask = task; return task
    }
    private func currentString() throws -> RedisBinaryValue {
        if cachedStringText == text, cachedStringHex == usesHex, let cachedStringValue { return cachedStringValue }
        guard text.utf8.count <= 65_536 else { throw RedisKeyEditError.unavailable }
        if usesHex {
            guard let data = RedisHexCodec.parse(text) else { throw RedisKeyEditError.invalidHex }
            return .init(data: data)
        }
        return .init(utf8: text)
    }
    func addRow(head: Bool = false) {
        guard canEdit, snapshot?.details.reference.type != .string else { return }
        rows.append(.init(isNew: true, firstValue: "", secondValue: snapshot?.details.reference.type == .sortedSet ? "0" : "", insertionEdge: head ? .head : .tail))
    }
    func removeRow(_ id: UUID) {
        guard canEdit, let index = rows.firstIndex(where: { $0.id == id }), !rows[index].isBinaryReadOnly else { return }
        if rows[index].isNew { rows.remove(at: index) } else { rows[index].isDeleted.toggle() }
    }
    private func request() throws -> RedisOptimisticMutationRequest {
        guard let snapshot else { throw RedisKeyEditError.unavailable }
        let reference = snapshot.details.reference
        if snapshot.isPartial {
            guard !deleteKey, expirationMode == (snapshot.details.ttlMilliseconds == nil ? .persistent : .expires),
                  ttl == (snapshot.details.ttlMilliseconds.map(String.init) ?? "") else { throw RedisKeyEditError.unavailable }
        }
        if deleteKey {
            let args = ["DEL", key]
            let source = RedisCommandPreviewFormatter.source(for: .init(source: "", arguments: args))
            return .init(reference: reference, assertions: snapshot.assertions, operations: [.command(.init(source: source, utf8Arguments: args))])
        }
        guard rows.allSatisfy({ !$0.isBinaryReadOnly || $0.changeState == .unchanged }) else { throw RedisKeyEditError.unavailable }
        if snapshot.details.reference.type == .hash, snapshot.hashFieldExpirationSupport != true,
           rows.contains(where: { $0.isThirdValueModified || $0.isNew && !$0.thirdValue.isEmpty }) {
            throw RedisKeyEditError.unavailable
        }
        let value = snapshot.stringData == nil ? nil : try currentString()
        guard (value?.data.count ?? 0) + rows.reduce(0, { $0 + $1.firstValue.utf8.count + $1.secondValue.utf8.count }) <= (reference.type == .string ? RedisStringEditingLimit.maximumBytes : 1_048_576), rows.count <= 1_000 else { throw MobileRedisMutationError.tooLarge }
        let plan = try RedisKeyMutationPlan.make(details: snapshot.details, stringValue: text, rows: rows, expirationMode: expirationMode, ttlMillisecondsText: ttl, expectedElementCount: snapshot.count, stringData: value, originalStringData: snapshot.stringData, previewByteLimit: 4_096)
        let operations = plan.optimisticRequest?.operations ?? plan.commands.map { RedisMutationOperation.command(.init(source: $0.source, utf8Arguments: $0.arguments)) }
        return .init(reference: reference, assertions: plan.optimisticRequest?.assertions ?? snapshot.assertions, operations: operations)
    }
    @discardableResult func prepare() -> Task<Void, Never>? {
        guard canEdit, !isValidatingString else { return nil }
        if snapshot?.stringData != nil, text.utf8.count > 65_536, cachedStringText != text || cachedStringHex != usesHex {
            let source = text, sourceHex = usesHex, token = generation, stringToken = UUID()
            stringGeneration = stringToken
            isValidatingString = true; prepared = nil; preview = nil; message = nil
            let task = Task { [weak self] in
                do {
                    let value = try await MobileRedisStringWorker().value(text: source, hex: sourceHex)
                    try Task.checkCancellation()
                    guard let self, self.generation == token, self.stringGeneration == stringToken else { return }
                    guard self.text == source, self.usesHex == sourceHex else { self.isValidatingString = false; return }
                    self.cachedStringText = source; self.cachedStringHex = sourceHex; self.cachedStringValue = value
                    self.isValidatingString = false; self.prepare()
                } catch {
                    guard let self, self.generation == token, self.stringGeneration == stringToken else { return }
                    self.isValidatingString = false; self.message = error.localizedDescription
                }
            }
            stringTask = task; return task
        }
        prepared = nil; preview = nil; message = nil
        do {
            guard !safetyLock.isEnabled else { throw RedisKeyEditError.safetyLockEnabled }
            let request = try request()
            guard !request.operations.isEmpty else { message = "没有待提交的改动。"; return nil }
            prepared = request
            preview = request.operations.map { operation in
                switch operation {
                case .command(let invocation): invocation.arguments.map { RedisBinaryCommandPreviewFormatter.preview($0) }.joined(separator: " ")
                case .deleteListElement(let index, _): "LSET \(RedisBinaryCommandPreviewFormatter.escaped(.init(utf8: key))) \(index) <unique-marker>\nLREM \(RedisBinaryCommandPreviewFormatter.escaped(.init(utf8: key))) 1 <unique-marker>"
                }
            }.joined(separator: "\n")
        } catch { message = error.localizedDescription }
        return nil
    }
    @discardableResult func submit() -> Task<Void, Never>? {
        guard canSubmit, let prepared else { return nil }
        do {
            guard try request() == prepared else { self.prepared = nil; preview = nil; message = "草稿已改变，请重新预览。"; return nil }
        } catch { self.prepared = nil; preview = nil; message = error.localizedDescription; return nil }
        isSubmitting = true; hasSubmittedAttempt = true; self.prepared = nil; preview = nil; message = nil
        let task = Task { [weak self, service] in
            do {
                try await service.apply(prepared)
                guard let self else { return }
                self.isSubmitting = false; self.needsVerification = true
                self.message = "提交成功；请重新读取核实。"; self.didWrite?()
                // This read is never a replay, even if the server reply was lost.
                await self.reload(discard: true)?.value
            } catch {
                guard let self else { return }
                self.isSubmitting = false; self.task = nil; self.message = error.localizedDescription
                if case MobileRedisMutationError.unverified = error { self.needsVerification = true }
            }
        }
        self.task = task; return task
    }
    func setBackgrounded(_ value: Bool) {
        isBackgrounded = value
        if value {
            stringTask?.cancel(); stringGeneration = UUID(); isValidatingString = false; isFormattingString = false
            safetyLock.enable(); prepared = nil; preview = nil
            // Once submitted, wait for the actual outcome; cancelling does not undo EXEC.
            if !isSubmitting { generation = UUID(); task?.cancel(); task = nil; isLoading = false }
        } else if !hasLoaded && !needsVerification && !isSubmitting {
            reload()
        }
    }
    func close() { if canClose { generation = UUID(); task?.cancel(); stringTask?.cancel(); stringGeneration = UUID(); task = nil; isLoading = false; isValidatingString = false; isFormattingString = false } }
}
