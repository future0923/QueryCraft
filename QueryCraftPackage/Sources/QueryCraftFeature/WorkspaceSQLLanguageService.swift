import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Observation
import OSLog

@MainActor
@Observable
final class WorkspaceSQLLanguageService: HighlightProviding {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "QueryCraft",
        category: "SQLLanguageService"
    )
    private let parser: SQLStructuralParser?
    private let completionWorker = SQLCompletionWorker()
    private let formattingWorker = SQLFormattingWorker()

    private(set) var selectionOrCurrentStatementAvailability =
        SQLExecutionTargetAvailability.unavailable(
            reason: SQLExecutionTargetError.editorUnavailable.localizedDescription
        )
    private(set) var runAllAvailability =
        SQLExecutionTargetAvailability.unavailable(
            reason: SQLExecutionTargetError.editorUnavailable.localizedDescription
        )

    @ObservationIgnored private weak var textView: TextView?
    @ObservationIgnored private var revisionCounter: UInt64 = 0
    @ObservationIgnored private var currentRevision: SQLSourceRevision?
    @ObservationIgnored private var currentSource: SQLSourceSnapshot?
    @ObservationIgnored private var latestParseSnapshot: SQLParseSnapshot?
    @ObservationIgnored private var parseTask: Task<SQLParseSnapshot, Error>?
    @ObservationIgnored private var parseObserverTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        parser = try? SQLStructuralParser()
    }

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        cancelPendingWork()
        self.textView = textView

        let revision = nextRevision()
        currentRevision = revision
        let source = SQLSourceSnapshot(
            revision: revision,
            text: textView.string
        )
        currentSource = source
        latestParseSnapshot = nil
        updateExecutionAvailability()
        scheduleParse(
            source,
            edit: nil,
            completion: nil
        )
    }

    func willApplyEdit(textView: TextView, range: NSRange) {}

    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor @Sendable (Result<IndexSet, Error>) -> Void
    ) {
        let source = textView.string
        let sourceLength = (source as NSString).length
        let replacementLength = range.length + delta
        guard let baseRevision = currentRevision,
              replacementLength >= 0,
              range.location >= 0,
              range.location + replacementLength <= sourceLength
        else {
            completion(.success(IndexSet(integersIn: 0..<sourceLength)))
            return
        }

        let replacementRange = NSRange(
            location: range.location,
            length: replacementLength
        )
        let replacement = (source as NSString).substring(with: replacementRange)
        let revision = nextRevision()
        currentRevision = revision
        let sourceSnapshot = SQLSourceSnapshot(
            revision: revision,
            text: source
        )
        currentSource = sourceSnapshot
        latestParseSnapshot = nil
        updateExecutionAvailability()

        scheduleParse(
            sourceSnapshot,
            edit: SQLSourceEdit(
                baseRevision: baseRevision,
                replacedRange: SQLSourceRange(range),
                replacement: replacement
            )
        ) { result in
            switch result {
            case .success(let snapshot):
                completion(
                    .success(
                        Self.invalidatedSet(
                            snapshot: snapshot,
                            editedLocation: range.location,
                            editedLength: replacementLength,
                            documentLength: sourceLength
                        )
                    )
                )
            case .failure(let error):
                if error is CancellationError
                    || (error as? SQLStructuralParserError) == .staleRevision {
                    completion(.failure(HighlightProvidingError.operationCancelled))
                } else {
                    completion(.success(IndexSet(integersIn: 0..<sourceLength)))
                }
            }
        }
    }

    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor @Sendable (Result<[HighlightRange], Error>) -> Void
    ) {
        guard let parser, let parseTask, let revision = currentRevision else {
            completion(.success([]))
            return
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            let result: Result<[HighlightRange], Error>
            do {
                let snapshot = try await parseTask.value
                try Task.checkCancellation()
                guard let self,
                      self.currentRevision == revision,
                      snapshot.revision == revision
                else {
                    throw CancellationError()
                }

                if textView.hasMarkedText() {
                    result = .success([])
                } else {
                    let highlights = try await parser.highlights(
                        in: SQLSourceRange(range),
                        revision: revision
                    )
                    try Task.checkCancellation()
                    guard self.currentRevision == revision else {
                        throw CancellationError()
                    }
                    result = .success(
                        highlights.map { highlight in
                            HighlightRange(
                                range: highlight.range.nsRange,
                                capture: Self.captureName(for: highlight.kind)
                            )
                        }
                    )
                }
            } catch is CancellationError {
                result = .failure(HighlightProvidingError.operationCancelled)
            } catch SQLStructuralParserError.staleRevision {
                result = .failure(HighlightProvidingError.operationCancelled)
            } catch {
                self?.logger.error("SQL highlight query failed: \(error.localizedDescription)")
                result = .success([])
            }

            self?.highlightTasks[requestID] = nil
            completion(result)
        }
        highlightTasks[requestID] = task
    }

    func executionTarget(
        for request: SQLExecutionTargetRequest
    ) async throws -> SQLExecutionTarget {
        guard let textView,
              let source = currentSource,
              let revision = currentRevision,
              source.revision == revision,
              source.text == textView.string
        else {
            throw SQLExecutionTargetError.editorUnavailable
        }
        guard !textView.hasMarkedText() else {
            throw SQLExecutionTargetError.textCompositionActive
        }

        let selectedRange = textView.selectedRange()
        if request == .all || hasMeaningfulSelection(
            selectedRange,
            in: source.text
        ) {
            return try SQLExecutionTargetResolver.resolve(
                request,
                source: source,
                selectedRange: selectedRange,
                parseSnapshot: nil
            )
        }

        guard let parseTask else {
            throw SQLExecutionTargetError.parserUnavailable
        }

        let snapshot: SQLParseSnapshot
        do {
            snapshot = try await parseTask.value
        } catch is CancellationError {
            throw SQLExecutionTargetError.sourceChanged
        } catch SQLStructuralParserError.staleRevision {
            throw SQLExecutionTargetError.sourceChanged
        } catch {
            throw SQLExecutionTargetError.parserUnavailable
        }

        guard currentRevision == revision,
              currentSource == source,
              textView.string == source.text
        else {
            throw SQLExecutionTargetError.sourceChanged
        }
        return try SQLExecutionTargetResolver.resolve(
            request,
            source: source,
            selectedRange: selectedRange,
            parseSnapshot: snapshot
        )
    }

    func executionPlan(
        for request: SQLExecutionTargetRequest
    ) async throws -> SQLExecutionBatchPlan {
        guard let textView,
              let source = currentSource,
              let revision = currentRevision,
              source.revision == revision,
              source.text == textView.string,
              let parseTask
        else {
            throw SQLExecutionTargetError.editorUnavailable
        }
        guard !textView.hasMarkedText() else {
            throw SQLExecutionTargetError.textCompositionActive
        }
        let selectedRange = textView.selectedRange()

        let snapshot: SQLParseSnapshot
        do {
            snapshot = try await parseTask.value
        } catch is CancellationError {
            throw SQLExecutionTargetError.sourceChanged
        } catch SQLStructuralParserError.staleRevision {
            throw SQLExecutionTargetError.sourceChanged
        } catch {
            throw SQLExecutionTargetError.parserUnavailable
        }

        guard currentRevision == revision,
              currentSource == source,
              textView.string == source.text,
              textView.selectedRange() == selectedRange,
              !textView.hasMarkedText()
        else {
            throw SQLExecutionTargetError.sourceChanged
        }
        let target = try SQLExecutionTargetResolver.resolve(
            request,
            source: source,
            selectedRange: selectedRange,
            parseSnapshot: snapshot
        )
        return try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )
    }

    func formattingEdit(
        for request: SQLFormattingRequest
    ) async throws -> SQLFormattingEdit? {
        guard let textView,
              let source = currentSource,
              let revision = currentRevision,
              source.revision == revision,
              source.text == textView.string
        else {
            throw SQLFormattingError.editorUnavailable
        }
        guard !textView.hasMarkedText() else {
            throw SQLFormattingError.textCompositionActive
        }
        guard let parseTask else {
            throw SQLFormattingError.parserUnavailable
        }

        let snapshot: SQLParseSnapshot
        do {
            snapshot = try await parseTask.value
        } catch is CancellationError {
            throw SQLFormattingError.sourceChanged
        } catch SQLStructuralParserError.staleRevision {
            throw SQLFormattingError.sourceChanged
        } catch {
            throw SQLFormattingError.parserUnavailable
        }

        guard currentRevision == revision,
              currentSource == source,
              textView.string == source.text
        else {
            throw SQLFormattingError.sourceChanged
        }
        guard !textView.hasMarkedText() else {
            throw SQLFormattingError.textCompositionActive
        }

        let selectedRange = textView.selectedRange()
        let preferences = ApplicationPreferences.shared
        let options = SQLFormattingOptions(
            keywordCase: preferences.sqlKeywordCase,
            indentationUnit: preferences.editorIndentationStyle == .spaces
                ? String(
                    repeating: " ",
                    count: preferences.editorIndentationWidth
                )
                : "\t"
        )
        let edit = try await formattingWorker.formattingEdit(
            for: request,
            source: source,
            selectedRange: selectedRange,
            parseSnapshot: snapshot,
            options: options
        )
        try Task.checkCancellation()
        guard currentRevision == revision,
              currentSource == source,
              textView.string == source.text,
              textView.selectedRange() == selectedRange,
              !textView.hasMarkedText()
        else {
            throw SQLFormattingError.sourceChanged
        }
        return edit
    }

    func completions(
        at cursorLocation: Int,
        schemaCatalog: WorkspaceSchemaCatalogSnapshot,
        defaultDatabase: String?,
        databaseType: DatabaseType = .mysql
    ) async -> SQLCompletionResult? {
        guard let textView,
              let source = currentSource,
              let revision = currentRevision,
              source.revision == revision,
              source.text == textView.string,
              textView.selectedRange() == NSRange(location: cursorLocation, length: 0),
              !textView.hasMarkedText(),
              let parseTask
        else {
            return nil
        }

        let snapshot: SQLParseSnapshot
        do {
            snapshot = try await parseTask.value
            try Task.checkCancellation()
        } catch {
            return nil
        }
        guard currentRevision == revision,
              currentSource == source,
              textView.string == source.text,
              textView.selectedRange() == NSRange(location: cursorLocation, length: 0),
              !textView.hasMarkedText(),
              snapshot.revision == revision
        else {
            return nil
        }
        do {
            return try await completionWorker.completions(
                for: SQLCompletionEngine.Request(
                    source: source,
                    cursorLocation: cursorLocation,
                    parseSnapshot: snapshot,
                    schemaCatalog: schemaCatalog,
                    defaultDatabase: defaultDatabase,
                    databaseType: databaseType
                )
            )
        } catch {
            return nil
        }
    }

    func matchesCurrentSource(
        revision: SQLSourceRevision,
        text: String
    ) -> Bool {
        currentRevision == revision
            && currentSource?.revision == revision
            && currentSource?.text == text
            && textView?.string == text
            && textView?.hasMarkedText() == false
    }

    func selectionDidChange() {
        updateExecutionAvailability()
    }

    private func scheduleParse(
        _ source: SQLSourceSnapshot,
        edit: SQLSourceEdit?,
        completion: (@MainActor (Result<SQLParseSnapshot, Error>) -> Void)?
    ) {
        parseTask?.cancel()
        parseObserverTask?.cancel()
        highlightTasks.values.forEach { $0.cancel() }
        highlightTasks.removeAll()

        guard let parser else {
            completion?(.failure(SQLStructuralParserError.languageUnavailable))
            return
        }

        let task = Task {
            try await parser.parse(source, applying: edit)
        }
        parseTask = task
        parseObserverTask = Task { @MainActor [weak self] in
            let result = await task.result
            guard let self, self.currentRevision == source.revision else {
                completion?(.failure(CancellationError()))
                return
            }

            if case .success(let snapshot) = result {
                self.latestParseSnapshot = snapshot
            }
            self.updateExecutionAvailability()
            completion?(result)
        }
    }

    private func updateExecutionAvailability() {
        guard let textView,
              let source = currentSource,
              source.text == textView.string
        else {
            let reason = SQLExecutionTargetError.editorUnavailable.localizedDescription
            selectionOrCurrentStatementAvailability = .unavailable(reason: reason)
            runAllAvailability = .unavailable(reason: reason)
            return
        }
        guard !textView.hasMarkedText() else {
            let reason = SQLExecutionTargetError.textCompositionActive.localizedDescription
            selectionOrCurrentStatementAvailability = .unavailable(reason: reason)
            runAllAvailability = .unavailable(reason: reason)
            return
        }

        selectionOrCurrentStatementAvailability = availability(
            for: .selectionOrCurrentStatement,
            source: source,
            selectedRange: textView.selectedRange()
        )
        runAllAvailability = availability(
            for: .all,
            source: source,
            selectedRange: textView.selectedRange()
        )
    }

    private func availability(
        for request: SQLExecutionTargetRequest,
        source: SQLSourceSnapshot,
        selectedRange: NSRange
    ) -> SQLExecutionTargetAvailability {
        if request == .selectionOrCurrentStatement,
           !hasMeaningfulSelection(selectedRange, in: source.text),
           latestParseSnapshot == nil
        {
            let error = parser == nil
                ? SQLExecutionTargetError.parserUnavailable
                : SQLExecutionTargetError.currentStatementPending
            return .unavailable(reason: error.localizedDescription)
        }
        do {
            _ = try SQLExecutionTargetResolver.resolve(
                request,
                source: source,
                selectedRange: selectedRange,
                parseSnapshot: latestParseSnapshot
            )
            return .available
        } catch let error as SQLExecutionTargetError {
            return .unavailable(reason: error.localizedDescription)
        } catch {
            return .unavailable(
                reason: SQLExecutionTargetError.parserUnavailable.localizedDescription
            )
        }
    }

    private func hasMeaningfulSelection(
        _ range: NSRange,
        in source: String
    ) -> Bool {
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= (source as NSString).length
        else {
            return false
        }
        return !(source as NSString)
            .substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func nextRevision() -> SQLSourceRevision {
        revisionCounter &+= 1
        return SQLSourceRevision(revisionCounter)
    }

    private func cancelPendingWork() {
        parseTask?.cancel()
        parseObserverTask?.cancel()
        highlightTasks.values.forEach { $0.cancel() }
        highlightTasks.removeAll()
    }

    private static func invalidatedSet(
        snapshot: SQLParseSnapshot,
        editedLocation: Int,
        editedLength: Int,
        documentLength: Int
    ) -> IndexSet {
        var set = IndexSet()
        for range in snapshot.changedRanges where range.length > 0 {
            set.insert(integersIn: range.location..<range.upperBound)
        }
        if documentLength > 0 {
            let location = min(max(0, editedLocation), documentLength - 1)
            let length = min(max(1, editedLength), documentLength - location)
            set.insert(integersIn: location..<(location + length))
        }
        return set
    }

    private static func captureName(for kind: SQLSyntaxHighlight.Kind) -> CaptureName {
        switch kind {
        case .keyword, .boolean: return .keyword
        case .comment: return .comment
        case .variable: return .variable
        case .property: return .property
        case .function: return .function
        case .number: return .number
        case .string: return .string
        case .type: return .type
        case .parameter: return .parameter
        case .attribute: return .typeAlternate
        }
    }

    deinit {
        parseTask?.cancel()
        parseObserverTask?.cancel()
        highlightTasks.values.forEach { $0.cancel() }
    }
}
