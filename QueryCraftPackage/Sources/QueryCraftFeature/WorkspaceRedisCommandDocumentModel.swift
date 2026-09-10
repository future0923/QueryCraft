import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceRedisCommandDocumentModel: Identifiable {
    typealias Executor = @Sendable (RedisCommandInvocation, Int) async throws
        -> RedisCommandResult
    typealias SuggestionLoader = @Sendable (
        RedisCommandSuggestionRequest
    ) async throws -> [String]

    let id: UUID
    let title: String
    private(set) var source = ""
    private(set) var transcriptEntries: [RedisCommandTranscriptEntry] = []
    private(set) var isExecuting = false
    private(set) var executionRevision = 0
    private(set) var transcriptRevision = 0
    private(set) var selectedCandidateIndex = 0

    @ObservationIgnored private let databaseIndex: @MainActor () -> Int
    @ObservationIgnored private let availableKeys:
        @MainActor () -> [RedisKeyReference]
    @ObservationIgnored private let availableHashFields:
        @MainActor (RedisKeyReference) -> [String]
    @ObservationIgnored private let isSafetyLockEnabled: @MainActor () -> Bool
    @ObservationIgnored private let executeCommand: Executor
    @ObservationIgnored private let loadSuggestions: SuggestionLoader
    @ObservationIgnored private let parser = RedisCommandParser()
    @ObservationIgnored private var executionTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var activeSuggestionRequest:
        RedisCommandSuggestionRequest?
    @ObservationIgnored private var suggestionLoadID: UUID?
    @ObservationIgnored private var commandHistory: [String] = []
    @ObservationIgnored private var historyCursor: Int?
    @ObservationIgnored private var historyDraft = ""
    private var suggestionCache: [RedisCommandSuggestionRequest: [String]] = [:]
    private var suggestionCacheOrder: [RedisCommandSuggestionRequest] = []
    private var suppressesCandidates = false

    init(
        id: UUID = UUID(),
        title: String,
        databaseIndex: @escaping @MainActor () -> Int,
        availableKeys: @escaping @MainActor () -> [RedisKeyReference] = { [] },
        availableHashFields: @escaping @MainActor (
            RedisKeyReference
        ) -> [String] = { _ in [] },
        isSafetyLockEnabled: @escaping @MainActor () -> Bool,
        loadSuggestions: @escaping SuggestionLoader = { _ in [] },
        executeCommand: @escaping Executor
    ) {
        self.id = id
        self.title = title
        self.databaseIndex = databaseIndex
        self.availableKeys = availableKeys
        self.availableHashFields = availableHashFields
        self.isSafetyLockEnabled = isSafetyLockEnabled
        self.loadSuggestions = loadSuggestions
        self.executeCommand = executeCommand
    }

    var commandLineSnapshot: RedisCommandLineSnapshot {
        RedisCommandLineSnapshot(source: source)
    }

    var activeCommand: RedisCommandCatalogEntry? {
        commandLineSnapshot.entry
    }

    var activeArgumentIndex: Int? {
        commandLineSnapshot.activeArgumentIndex
    }

    var activeArgument: RedisCommandArgument? {
        guard let activeArgumentIndex else { return nil }
        return activeCommand?.argument(at: activeArgumentIndex)
    }

    var completions: [RedisCommandCatalogEntry] {
        guard !suppressesCandidates else { return [] }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              commandLineSnapshot.isEditingCommandName
        else { return [] }
        return RedisCommandCatalog.matching(trimmed)
    }

    var argumentSuggestions: [RedisCommandArgumentSuggestion] {
        guard !suppressesCandidates, let activeArgument else { return [] }
        let token = commandLineSnapshot.currentToken
        switch activeArgument.kind {
        case .key:
            return keySuggestions(matching: token)
        case let .keyword(values):
            guard !token.isEmpty || !activeArgument.isOptional else { return [] }
            return values
                .filter { token.isEmpty || $0.localizedStandardContains(token) }
                .prefix(Self.maximumCandidateCount)
                .map {
                    RedisCommandArgumentSuggestion(
                        value: $0,
                        detail: AppCopy.current.text("关键字", "Keyword")
                    )
                }
        case .field:
            return loadedSuggestions(matching: token)
        case .value:
            return loadedSuggestions(matching: token)
        case .integer, .cursor, .pattern, .other:
            return []
        }
    }

    var hasOpenCandidates: Bool {
        !completions.isEmpty || !argumentSuggestions.isEmpty
    }

    var requiresSafetyLockDisable: Bool {
        guard let name = source.split(whereSeparator: { $0.isWhitespace }).first
        else { return false }
        return RedisCommandCatalog.entry(named: String(name))?.isReadOnly != true
    }

    func updateSource(_ value: String) {
        guard source != value else { return }
        source = value
        selectedCandidateIndex = 0
        suppressesCandidates = false
        historyCursor = nil
        historyDraft = ""
        refreshSuggestionRequest()
    }

    func acceptCompletion(_ entry: RedisCommandCatalogEntry) {
        source = "\(entry.name) "
        selectedCandidateIndex = 0
        suppressesCandidates = false
        historyCursor = nil
        historyDraft = ""
        refreshSuggestionRequest()
    }

    @discardableResult
    func acceptSelectedCandidate() -> Bool {
        let entries = completions
        if !entries.isEmpty {
            acceptCompletion(
                entries[min(selectedCandidateIndex, entries.count - 1)]
            )
            return true
        }
        let suggestions = argumentSuggestions
        guard !suggestions.isEmpty else { return false }
        acceptArgumentSuggestion(
            suggestions[min(selectedCandidateIndex, suggestions.count - 1)]
        )
        return true
    }

    func acceptArgumentSuggestion(_ suggestion: RedisCommandArgumentSuggestion) {
        source = commandLineSnapshot.replacingCurrentToken(with: suggestion.value)
        selectedCandidateIndex = 0
        suppressesCandidates = false
        historyCursor = nil
        historyDraft = ""
        refreshSuggestionRequest()
    }

    @discardableResult
    func selectPreviousCandidate() -> Bool {
        let count = candidateCount
        guard count > 0 else { return false }
        selectedCandidateIndex = max(0, selectedCandidateIndex - 1)
        return true
    }

    @discardableResult
    func selectNextCandidate() -> Bool {
        let count = candidateCount
        guard count > 0 else { return false }
        selectedCandidateIndex = min(count - 1, selectedCandidateIndex + 1)
        return true
    }

    @discardableResult
    func dismissCandidates() -> Bool {
        guard hasOpenCandidates else { return false }
        suppressesCandidates = true
        return true
    }

    @discardableResult
    func showPreviousCommand() -> Bool {
        guard !commandHistory.isEmpty else { return false }
        if let historyCursor {
            self.historyCursor = max(0, historyCursor - 1)
        } else {
            historyDraft = source
            historyCursor = commandHistory.count - 1
        }
        guard let historyCursor else { return false }
        source = commandHistory[historyCursor]
        selectedCandidateIndex = 0
        suppressesCandidates = true
        refreshSuggestionRequest()
        return true
    }

    @discardableResult
    func showNextCommand() -> Bool {
        guard let historyCursor else { return false }
        if historyCursor + 1 < commandHistory.count {
            self.historyCursor = historyCursor + 1
            source = commandHistory[historyCursor + 1]
        } else {
            self.historyCursor = nil
            source = historyDraft
            historyDraft = ""
        }
        selectedCandidateIndex = 0
        suppressesCandidates = true
        refreshSuggestionRequest()
        return true
    }

    @discardableResult
    func run(allowingChanges: Bool = false) -> Task<Void, Never>? {
        guard !isExecuting else { return nil }
        let command = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        if requiresSafetyLockDisable,
           isSafetyLockEnabled(),
           !allowingChanges
        {
            return nil
        }

        let index = databaseIndex()
        let entryID = UUID()
        appendTranscriptEntry(
            RedisCommandTranscriptEntry(
                id: entryID,
                databaseIndex: index,
                command: command,
                outcome: .executing
            )
        )
        remember(command)
        source = ""
        selectedCandidateIndex = 0
        suppressesCandidates = true
        historyCursor = nil
        historyDraft = ""
        refreshSuggestionRequest()
        isExecuting = true

        executionTask?.cancel()
        let task = Task { [weak self, parser, executeCommand] in
            guard let self else { return }
            defer {
                isExecuting = false
                executionTask = nil
                executionRevision &+= 1
            }
            do {
                let invocation = try await parser.parse(command)
                try Task.checkCancellation()
                let result = try await executeCommand(invocation, index)
                try Task.checkCancellation()
                completeTranscriptEntry(
                    entryID,
                    outcome: .success(
                        reply: result.reply,
                        elapsedSeconds: result.elapsedSeconds
                    )
                )
            } catch is CancellationError {
                completeTranscriptEntry(entryID, outcome: .cancelled)
            } catch {
                completeTranscriptEntry(
                    entryID,
                    outcome: .failure(error.localizedDescription)
                )
            }
        }
        executionTask = task
        return task
    }

    func stop() {
        executionTask?.cancel()
        cancelSuggestionLoading()
    }

    func refreshSuggestionLoading() {
        refreshSuggestionRequest()
    }

    func waitForSuggestionLoading() async {
        let task = suggestionTask
        await task?.value
    }

    private func appendTranscriptEntry(_ entry: RedisCommandTranscriptEntry) {
        transcriptEntries.append(entry)
        if transcriptEntries.count > Self.maximumTranscriptEntries {
            transcriptEntries.removeFirst(
                transcriptEntries.count - Self.maximumTranscriptEntries
            )
        }
        transcriptRevision &+= 1
    }

    private func completeTranscriptEntry(
        _ id: UUID,
        outcome: RedisCommandTranscriptEntry.Outcome
    ) {
        guard let index = transcriptEntries.firstIndex(where: { $0.id == id })
        else { return }
        transcriptEntries[index].outcome = outcome
        transcriptRevision &+= 1
    }

    private func remember(_ command: String) {
        if commandHistory.last != command {
            commandHistory.append(command)
        }
        if commandHistory.count > Self.maximumHistoryEntries {
            commandHistory.removeFirst(
                commandHistory.count - Self.maximumHistoryEntries
            )
        }
    }

    private var candidateCount: Int {
        if !completions.isEmpty { return completions.count }
        return argumentSuggestions.count
    }

    private func keySuggestions(
        matching token: String
    ) -> [RedisCommandArgumentSuggestion] {
        var seen = Set<RedisKeyReference>()
        var uniqueKeys = availableKeys().filter { seen.insert($0).inserted }
        if let compatibleTypes = activeCommand?.compatibleKeyTypes {
            uniqueKeys = uniqueKeys.filter {
                $0.type == .unknown || compatibleTypes.contains($0.type)
            }
        }
        let matches: [RedisKeyReference]
        if token.isEmpty {
            matches = uniqueKeys
        } else {
            let prefixMatches = uniqueKeys.filter {
                $0.name.range(
                    of: token,
                    options: [.anchored, .caseInsensitive]
                ) != nil
            }
            let remainingMatches = uniqueKeys.filter {
                !prefixMatches.contains($0)
                    && $0.name.localizedStandardContains(token)
            }
            matches = prefixMatches + remainingMatches
        }
        return matches.prefix(Self.maximumCandidateCount).map { reference in
            RedisCommandArgumentSuggestion(
                value: reference.name,
                detail: reference.type == .unknown
                    ? AppCopy.current.text(
                        "当前数据库 Key",
                        "Current database key"
                    )
                    : "\(reference.type.rawValue) Key"
            )
        }
    }

    private func loadedSuggestions(
        matching token: String
    ) -> [RedisCommandArgumentSuggestion] {
        guard let request = commandLineSnapshot.suggestionRequest(
            databaseIndex: databaseIndex()
        ) else { return [] }
        let candidates = suggestionCache[request] ?? []
        let matches: [String]
        if token.isEmpty {
            matches = candidates
        } else {
            let prefixMatches = candidates.filter {
                $0.range(of: token, options: [.anchored, .caseInsensitive]) != nil
            }
            let remainingMatches = candidates.filter {
                !prefixMatches.contains($0)
                    && $0.localizedStandardContains(token)
            }
            matches = prefixMatches + remainingMatches
        }
        return matches.prefix(Self.maximumCandidateCount).map {
            RedisCommandArgumentSuggestion(
                value: $0,
                detail: request.domain.suggestionDetail
            )
        }
    }

    private func refreshSuggestionRequest() {
        let request = commandLineSnapshot.suggestionRequest(
            databaseIndex: databaseIndex()
        )
        guard request != activeSuggestionRequest else { return }

        suggestionTask?.cancel()
        suggestionTask = nil
        suggestionLoadID = nil
        activeSuggestionRequest = request
        guard let request else { return }

        if suggestionCache[request] != nil { return }
        if request.domain == .hashField {
            let reference = RedisKeyReference(
                databaseIndex: request.databaseIndex,
                name: request.key,
                type: .hash
            )
            let cachedFields = availableHashFields(reference)
            if !cachedFields.isEmpty {
                storeSuggestions(cachedFields, for: request)
                return
            }
        }

        let loadID = UUID()
        suggestionLoadID = loadID
        suggestionTask = Task { [weak self, loadSuggestions] in
            do {
                try Task.checkCancellation()
                let candidates = try await loadSuggestions(request)
                try Task.checkCancellation()
                guard let self,
                      suggestionLoadID == loadID,
                      activeSuggestionRequest == request
                else { return }
                storeSuggestions(candidates, for: request)
                selectedCandidateIndex = 0
                suggestionTask = nil
                suggestionLoadID = nil
            } catch is CancellationError {
                guard let self, suggestionLoadID == loadID else { return }
                suggestionTask = nil
                suggestionLoadID = nil
            } catch {
                guard let self, suggestionLoadID == loadID else { return }
                suggestionTask = nil
                suggestionLoadID = nil
            }
        }
    }

    private func storeSuggestions(
        _ candidates: [String],
        for request: RedisCommandSuggestionRequest
    ) {
        var seen = Set<String>()
        suggestionCache[request] = candidates.filter {
            seen.insert($0).inserted
        }
        suggestionCacheOrder.removeAll { $0 == request }
        suggestionCacheOrder.append(request)
        if suggestionCacheOrder.count > Self.maximumSuggestionCacheEntries {
            let overflow = suggestionCacheOrder.count
                - Self.maximumSuggestionCacheEntries
            let expired = Array(suggestionCacheOrder.prefix(overflow))
            suggestionCacheOrder.removeFirst(overflow)
            for request in expired {
                suggestionCache.removeValue(forKey: request)
            }
        }
    }

    private func cancelSuggestionLoading() {
        suggestionTask?.cancel()
        suggestionTask = nil
        activeSuggestionRequest = nil
        suggestionLoadID = nil
    }

    private static let maximumTranscriptEntries = 300
    private static let maximumHistoryEntries = 100
    private static let maximumCandidateCount = 7
    private static let maximumSuggestionCacheEntries = 100
}
