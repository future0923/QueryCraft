import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceGridSearchController {
    var isPresented = false
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }
    var selectedDataColumnIndex: Int? {
        didSet {
            guard selectedDataColumnIndex != oldValue else { return }
            scheduleSearch()
        }
    }
    var searchOperator = WorkspaceGridSearchOperator.contains {
        didSet {
            guard searchOperator != oldValue else { return }
            scheduleSearch()
        }
    }
    var isCaseSensitive = false {
        didSet {
            guard isCaseSensitive != oldValue else { return }
            scheduleSearch()
        }
    }

    private(set) var columns: [WorkspaceDatabaseDataColumn] = []
    private(set) var sourceRowCount = 0
    private(set) var matches: [WorkspaceGridSearchMatch] = []
    private(set) var currentMatchIndex: Int?
    private(set) var hasAdditionalMatches = false
    private(set) var isSearching = false
    private(set) var focusRequest = 0

    @ObservationIgnored private let worker = WorkspaceGridSearchWorker()
    @ObservationIgnored private var source: WorkspaceGridSearchSource?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var selectionHandler:
        (@MainActor (WorkspaceGridSearchMatch) -> Void)?

    deinit {
        searchTask?.cancel()
    }

    var canSearch: Bool {
        sourceRowCount > 0
    }

    var matchStatus: String {
        if isSearching {
            return AppCopy.current.text("正在查找…", "Searching...")
        }
        guard !query.isEmpty else { return "" }
        guard let currentMatchIndex else {
            return AppCopy.current.text("无匹配项", "No Matches")
        }
        let suffix = hasAdditionalMatches ? "+" : ""
        return "\(currentMatchIndex + 1) / \(matches.count)\(suffix)"
    }

    func update(source: WorkspaceGridSearchSource) {
        let sourceChanged = self.source?.revision != source.revision
        self.source = source
        columns = source.columns
        sourceRowCount = source.rowCount
        if let selectedDataColumnIndex,
           !columns.indices.contains(selectedDataColumnIndex)
        {
            self.selectedDataColumnIndex = nil
        }
        guard sourceChanged else { return }
        scheduleSearch(debounce: false)
    }

    func clearSource() {
        source = nil
        columns = []
        sourceRowCount = 0
        cancelSearchAndResetResults()
    }

    func present() {
        guard canSearch else { return }
        isPresented = true
        focusRequest &+= 1
    }

    func dismiss() {
        isPresented = false
    }

    func togglePresentation() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    func selectNextMatch() {
        guard !matches.isEmpty else { return }
        let nextIndex = ((currentMatchIndex ?? -1) + 1) % matches.count
        selectMatch(at: nextIndex)
    }

    func selectPreviousMatch() {
        guard !matches.isEmpty else { return }
        let previousIndex =
            ((currentMatchIndex ?? 0) - 1 + matches.count) % matches.count
        selectMatch(at: previousIndex)
    }

    func attachSelectionHandler(
        _ handler: @escaping @MainActor (WorkspaceGridSearchMatch) -> Void
    ) {
        selectionHandler = handler
        if let currentMatchIndex, matches.indices.contains(currentMatchIndex) {
            handler(matches[currentMatchIndex])
        }
    }

    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        guard let source, !query.isEmpty else {
            cancelSearchAndResetResults()
            return
        }

        let request = WorkspaceGridSearchRequest(
            query: query,
            dataColumnIndex: selectedDataColumnIndex,
            searchOperator: searchOperator,
            isCaseSensitive: isCaseSensitive
        )
        isSearching = true
        searchTask = Task { @MainActor [weak self] in
            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(180))
                }
                guard let self else { return }
                let result = try await worker.search(
                    source: source,
                    request: request
                )
                try Task.checkCancellation()
                guard generation == searchGeneration else { return }
                apply(result)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == searchGeneration else {
                    return
                }
                apply(
                    WorkspaceGridSearchResult(
                        matches: [],
                        hasAdditionalMatches: false
                    )
                )
            }
        }
    }

    private func apply(_ result: WorkspaceGridSearchResult) {
        matches = result.matches
        hasAdditionalMatches = result.hasAdditionalMatches
        isSearching = false
        if matches.isEmpty {
            currentMatchIndex = nil
        } else {
            selectMatch(at: 0)
        }
        searchTask = nil
    }

    private func selectMatch(at index: Int) {
        guard matches.indices.contains(index) else { return }
        currentMatchIndex = index
        selectionHandler?(matches[index])
    }

    private func cancelSearchAndResetResults() {
        searchTask?.cancel()
        searchTask = nil
        matches = []
        currentMatchIndex = nil
        hasAdditionalMatches = false
        isSearching = false
    }
}
