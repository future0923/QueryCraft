import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

struct MobileGridSearchTests {
    private func source(_ rows: [[WorkspaceDatabaseDataCell]], revision: UUID = UUID()) -> MobileGridSearchSource {
        let count = rows.map(\.count).max() ?? 0
        return .init(revision: revision, data: .init(columns: (0..<count).map { "column_\($0)" }, details: [],
            rows: rows.map { $0.map { _ in "deliberately different display fallback" } }, cells: rows))
    }

    @Test func desktopMatchingOperatorsCaseAndColumnScopeUseTypedCells() async throws {
        let snapshot = source([[.text("Alpha"), .text("north")], [.text("beta"), .text("SOUTH")], [.text("alphabet"), .null]])
        let worker = WorkspaceGridSearchWorker()
        let cases: [(String, Int?, WorkspaceGridSearchOperator, Bool, [WorkspaceGridSearchMatch])] = [
            ("ALPHA", nil, .contains, false, [.init(rowIndex: 0, dataColumnIndex: 0), .init(rowIndex: 2, dataColumnIndex: 0)]),
            ("ALPHA", nil, .contains, true, []),
            ("SOUTH", 1, .equals, true, [.init(rowIndex: 1, dataColumnIndex: 1)]),
            ("alph", 0, .beginsWith, false, [.init(rowIndex: 0, dataColumnIndex: 0), .init(rowIndex: 2, dataColumnIndex: 0)]),
            ("TH", 1, .endsWith, false, [.init(rowIndex: 0, dataColumnIndex: 1), .init(rowIndex: 1, dataColumnIndex: 1)]),
            ("north", 0, .contains, false, []),
        ]
        for (query, column, operation, sensitive, expected) in cases {
            let result = try await worker.search(source: snapshot, request: .init(query: query, dataColumnIndex: column,
                searchOperator: operation, isCaseSensitive: sensitive))
            #expect(result.matches == expected)
        }
        #expect(snapshot.rowCount == 3, "Finding must not filter or renumber data rows")
    }

    @Test func nullBinaryLongTextAndDuplicateColumnNamesRemainDistinct() async throws {
        let rows: [[WorkspaceDatabaseDataCell]] = [[.null, .text("")], [.binary(byteCount: 300, preview: [0, 255]), .text(String(repeating: "x", count: 500) + "尾部")], [.text("hit"), .text("hit")]]
        let snapshot = MobileGridSearchSource(revision: UUID(), data: .init(columns: ["alias", "alias"], details: [],
            rows: rows.map { $0.map { _ in nil } }, cells: rows))
        let worker = WorkspaceGridSearchWorker()
        for (query, expected) in [("NULL", [WorkspaceGridSearchMatch(rowIndex: 0, dataColumnIndex: 0)]),
                                   ("BINARY 300", [.init(rowIndex: 1, dataColumnIndex: 0)]),
                                   ("尾部", [.init(rowIndex: 1, dataColumnIndex: 1)]),
                                   ("hit", [.init(rowIndex: 2, dataColumnIndex: 0), .init(rowIndex: 2, dataColumnIndex: 1)])] {
            let result = try await worker.search(source: snapshot, request: .init(query: query, dataColumnIndex: nil, searchOperator: .contains, isCaseSensitive: false))
            #expect(result.matches == expected)
        }
    }

    @Test func matchCapAndCancellationAreSharedWithDesktop() async throws {
        let snapshot = source(Array(repeating: [.text("match")], count: 10_001))
        let worker = WorkspaceGridSearchWorker()
        let request = WorkspaceGridSearchRequest(query: "match", dataColumnIndex: nil, searchOperator: .equals, isCaseSensitive: true)
        let result = try await worker.search(source: snapshot, request: request)
        #expect(result.matches.count == 10_000)
        #expect(result.hasAdditionalMatches)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream { break }
            return try await worker.search(source: snapshot, request: request)
        }
        task.cancel(); continuation.yield(()); continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test @MainActor func navigationWrapsAndDismissPreservesQueryAndMatch() async throws {
        let controller = WorkspaceGridSearchController()
        controller.update(source: source([[.text("hit"), .text("hit")], [.text("other"), .text("hit")]]))
        var selected: [WorkspaceGridSearchMatch] = []
        controller.attachSelectionHandler { selected.append($0) }
        controller.present(); controller.query = "hit"
        try await settled(controller)
        #expect(controller.matches.count == 3)
        #expect(controller.currentMatchIndex == 0)
        controller.selectPreviousMatch()
        #expect(selected.last == .init(rowIndex: 1, dataColumnIndex: 1))
        controller.selectNextMatch()
        #expect(controller.currentMatchIndex == 0)
        controller.selectNextMatch()
        #expect(selected.last == .init(rowIndex: 0, dataColumnIndex: 1))
        controller.dismiss()
        #expect(controller.query == "hit")
        #expect(controller.currentMatchIndex == 1)
        controller.present()
        #expect(controller.currentMatchIndex == 1)
    }

    @Test @MainActor func rapidReplacementAndClearingRejectStaleMatches() async throws {
        let controller = WorkspaceGridSearchController()
        controller.query = "old"
        controller.update(source: source(Array(repeating: [.text("old")], count: 10_001)))
        controller.query = "latest"
        controller.update(source: source([[.text("other")], [.text("latest")]]))
        try await settled(controller)
        #expect(controller.matches == [.init(rowIndex: 1, dataColumnIndex: 0)])
        controller.selectedDataColumnIndex = 9
        controller.update(source: source([[.text("latest")]]))
        try await settled(controller)
        #expect(controller.selectedDataColumnIndex == nil)
        #expect(controller.matches == [.init(rowIndex: 0, dataColumnIndex: 0)])
        controller.query = "old"
        controller.clearSource()
        try await Task.sleep(for: .milliseconds(220))
        #expect(controller.matches.isEmpty)
        #expect(controller.isSearching == false)
        #expect(controller.canSearch == false)
    }

    @Test @MainActor func sameRevisionRefreshRetainsSelectionAndSuccessfulEmptyIsNotStale() async throws {
        let controller = WorkspaceGridSearchController()
        let page = source([[.text("hit")], [.text("hit")]])
        controller.update(source: page); controller.query = "hit"
        try await settled(controller)
        controller.selectNextMatch()
        controller.update(source: page)
        #expect(controller.currentMatchIndex == 1)
        controller.update(source: source([]))
        try await settled(controller)
        #expect(controller.matches.isEmpty)
        #expect(controller.currentMatchIndex == nil)
    }

    @MainActor private func settled(_ controller: WorkspaceGridSearchController) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.isSearching, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.isSearching == false, "Search did not complete within the test deadline")
    }
}
