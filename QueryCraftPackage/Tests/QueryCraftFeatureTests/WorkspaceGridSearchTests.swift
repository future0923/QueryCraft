import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

struct WorkspaceGridSearchTests {
    @Test @MainActor
    func visibleGridIsTheWindowSearchTargetWithoutTableFocus() {
        let controller = WorkspaceGridSearchController()
        controller.update(
            source: makeSource(rows: [[.text("ready")]])
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let tableView = WorkspaceDirectDrawTableView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        tableView.gridSearchController = controller
        window.contentView = tableView

        #expect(
            WorkspaceDirectDrawTableView.visibleSearchTarget(in: window)
                === tableView
        )

        tableView.isHidden = true
        #expect(
            WorkspaceDirectDrawTableView.visibleSearchTarget(in: window)
                == nil
        )
    }

    @Test @MainActor
    func escapeDismissesSearchFromTheNativeSearchField() {
        let controller = WorkspaceGridSearchController()
        controller.update(
            source: makeSource(rows: [[.text("ready")]])
        )
        controller.present()
        let field = WorkspaceGridSearchField(
            text: .constant("ready"),
            placeholder: "",
            focusRequest: controller.focusRequest,
            submit: {},
            cancel: controller.dismiss
        )
        let coordinator = field.makeCoordinator()

        let handled = coordinator.control(
            NSSearchField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        #expect(handled)
        #expect(!controller.isPresented)
    }

    @Test @MainActor
    func nativeSearchFieldForwardsColumnPickerNavigation() {
        var moveUpCount = 0
        var moveDownCount = 0
        let field = WorkspaceGridSearchField(
            text: .constant("name"),
            placeholder: "",
            focusRequest: 1,
            submit: {},
            cancel: {},
            accessibilityIdentifier: "columnSearch",
            moveUp: { moveUpCount += 1 },
            moveDown: { moveDownCount += 1 }
        )
        let coordinator = field.makeCoordinator()

        let handledMoveUp = coordinator.control(
            NSSearchField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveUp(_:))
        )
        let handledMoveDown = coordinator.control(
            NSSearchField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        )

        #expect(handledMoveUp)
        #expect(handledMoveDown)
        #expect(moveUpCount == 1)
        #expect(moveDownCount == 1)
    }

    @Test @MainActor
    func columnPickerFiltersNamesWithoutChangingColumnIndices() {
        let columns = [
            WorkspaceDatabaseDataColumn(id: 10, name: "customer_name"),
            WorkspaceDatabaseDataColumn(id: 20, name: "order_status"),
            WorkspaceDatabaseDataColumn(id: 30, name: "Customer_Email"),
        ]

        #expect(
            WorkspaceGridSearchColumnPicker.filteredColumnIndices(
                in: columns,
                matching: "CUSTOMER"
            ) == [0, 2]
        )
        #expect(
            WorkspaceGridSearchColumnPicker.filteredColumnIndices(
                in: columns,
                matching: " status "
            ) == [1]
        )
        #expect(
            WorkspaceGridSearchColumnPicker.filteredColumnIndices(
                in: columns,
                matching: ""
            ) == [0, 1, 2]
        )
    }

    @Test @MainActor
    func columnPickerWidthIsUserResizableWithinBounds() {
        #expect(
            WorkspaceGridSearchColumnPicker.resizedWidth(
                startingWidth: 220,
                translation: 40
            ) == 260
        )
        #expect(
            WorkspaceGridSearchColumnPicker.resizedWidth(
                startingWidth: 220,
                translation: -1_000
            ) == 180
        )
        #expect(
            WorkspaceGridSearchColumnPicker.resizedWidth(
                startingWidth: 220,
                translation: 1_000
            ) == 480
        )
    }

    @Test @MainActor
    func commandFShowsSearchFromTheDirectDrawGrid() throws {
        let controller = WorkspaceGridSearchController()
        controller.update(
            source: makeSource(rows: [[.text("ready")]])
        )
        let tableView = WorkspaceDirectDrawTableView()
        tableView.gridSearchController = controller
        #expect(
            tableView.tryToPerform(
                #selector(WorkspaceDirectDrawTableView.findInData(_:)),
                with: nil
            )
        )
        #expect(controller.isPresented)
        controller.dismiss()
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "f",
                charactersIgnoringModifiers: "f",
                isARepeat: false,
                keyCode: 3
            )
        )

        tableView.keyDown(with: event)

        #expect(controller.isPresented)
        tableView.cancelOperation(nil)
        #expect(!controller.isPresented)
    }

    @Test @MainActor
    func sourceAvailabilityUpdatesTheSearchControl() {
        let controller = WorkspaceGridSearchController()
        #expect(!controller.canSearch)

        controller.update(
            source: makeSource(rows: [[.text("ready")]])
        )
        #expect(controller.canSearch)

        controller.clearSource()
        #expect(!controller.canSearch)
    }

    @Test
    func searchesAllColumnsWithEachOperator() async throws {
        let source = makeSource(
            rows: [
                [.text("Alpha"), .text("north")],
                [.text("beta"), .text("SOUTH")],
                [.text("alphabet"), .null],
            ]
        )
        let worker = WorkspaceGridSearchWorker()

        let contains = try await worker.search(
            source: source,
            request: WorkspaceGridSearchRequest(
                query: "ALPHA",
                dataColumnIndex: nil,
                searchOperator: .contains,
                isCaseSensitive: false
            )
        )
        #expect(
            contains.matches
                == [
                    WorkspaceGridSearchMatch(
                        rowIndex: 0,
                        dataColumnIndex: 0
                    ),
                    WorkspaceGridSearchMatch(
                        rowIndex: 2,
                        dataColumnIndex: 0
                    ),
                ]
        )

        let equals = try await worker.search(
            source: source,
            request: WorkspaceGridSearchRequest(
                query: "SOUTH",
                dataColumnIndex: 1,
                searchOperator: .equals,
                isCaseSensitive: true
            )
        )
        #expect(
            equals.matches
                == [
                    WorkspaceGridSearchMatch(
                        rowIndex: 1,
                        dataColumnIndex: 1
                    )
                ]
        )

        let beginsWith = try await worker.search(
            source: source,
            request: WorkspaceGridSearchRequest(
                query: "alph",
                dataColumnIndex: 0,
                searchOperator: .beginsWith,
                isCaseSensitive: false
            )
        )
        #expect(beginsWith.matches.count == 2)

        let endsWith = try await worker.search(
            source: source,
            request: WorkspaceGridSearchRequest(
                query: "TH",
                dataColumnIndex: 1,
                searchOperator: .endsWith,
                isCaseSensitive: false
            )
        )
        #expect(endsWith.matches.count == 2)
    }

    @Test
    func boundsStoredMatches() async throws {
        let rowCount = WorkspaceGridSearchWorker.maximumMatchCount + 1
        let source = makeSource(
            rows: Array(
                repeating: [.text("match")],
                count: rowCount
            )
        )
        let result = try await WorkspaceGridSearchWorker().search(
            source: source,
            request: WorkspaceGridSearchRequest(
                query: "match",
                dataColumnIndex: nil,
                searchOperator: .equals,
                isCaseSensitive: true
            )
        )

        #expect(
            result.matches.count
                == WorkspaceGridSearchWorker.maximumMatchCount
        )
        #expect(result.hasAdditionalMatches)
    }

    @Test
    func observesCancellationBeforeScanning() async {
        let source = makeSource(
            rows: Array(repeating: [.text("value")], count: 2_000)
        )
        let worker = WorkspaceGridSearchWorker()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream {
                break
            }
            return try await worker.search(
                source: source,
                request: WorkspaceGridSearchRequest(
                    query: "value",
                    dataColumnIndex: nil,
                    searchOperator: .contains,
                    isCaseSensitive: false
                )
            )
        }
        task.cancel()
        continuation.yield(())
        continuation.finish()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func makeSource(
        rows: [[WorkspaceDatabaseDataCell]]
    ) -> WorkspaceGridSearchSource {
        let columnCount = rows.map(\.count).max() ?? 0
        return .tablePage(
            WorkspaceDatabaseDataPage(
                columns: (0..<columnCount).map {
                    WorkspaceDatabaseDataColumn(
                        id: $0,
                        name: "column_\($0)"
                    )
                },
                rows: rows.enumerated().map {
                    WorkspaceDatabaseDataRow(
                        id: $0.offset,
                        values: $0.element
                    )
                },
                offset: 0,
                limit: max(rows.count, 1),
                hasNextPage: false
            )
        )
    }
}
