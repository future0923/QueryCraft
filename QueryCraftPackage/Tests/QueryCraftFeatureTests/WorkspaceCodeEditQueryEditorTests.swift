import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI
import Testing
@testable import QueryCraftFeature

@MainActor
@Suite(.serialized)
struct WorkspaceCodeEditQueryEditorTests {
    @Test
    func documentJSONEditorMountsAcrossSystemAppearances() throws {
        let appearanceNames: [NSAppearance.Name] = [
            .aqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ]

        for appearanceName in appearanceNames {
            let editor = WorkspaceCodeEditJSONEditor(
                text: .constant("{\"enabled\":true}")
            )
            let hostingView = NSHostingView(rootView: editor)
            hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 240)

            let window = NSWindow(
                contentRect: hostingView.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            hostingView.layoutSubtreeIfNeeded()
            hostingView.displayIfNeeded()

            #expect(findCodeEditTextView(in: hostingView) != nil)
            window.orderOut(nil)
        }
    }

    @Test
    func returnAfterAcceptingFromCompletionOnlyInsertsANewline() async throws {
        let languageService = WorkspaceSQLLanguageService()
        let completionService = WorkspaceSQLCompletionService(
            languageService: languageService,
            schemaCatalog: .empty,
            defaultDatabase: { nil },
            prepareCompletionColumns: { _ in .empty }
        )
        let mountedEditor = mountEditor(
            text: "",
            selectedRange: NSRange(location: 0, length: 0),
            languageService: languageService,
            completionService: completionService,
            windowStyleMask: [.titled]
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        _ = try #require(textViewController(for: textView))
        try #require(mountedEditor.window.makeFirstResponder(textView))
        let suggestionController = SuggestionController.shared
        suggestionController.close()
        defer { suggestionController.close() }

        textView.insertText("sel")
        await (try #require(suggestionController.model.itemsRequestTask)).value
        let suggestionView = try #require(
            suggestionController.contentViewController as? SuggestionViewController
        )
        let selectRow = try #require(
            suggestionController.model.items.firstIndex { $0.label == "SELECT" }
        )
        suggestionView.tableView.selectRowIndexes(
            IndexSet(integer: selectRow),
            byExtendingSelection: false
        )
        sendReturnKey(to: textView)
        #expect(textView.string == "SELECT")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!suggestionController.isVisible)

        sendReturnKey(to: textView)
        textView.insertText("* fro")
        await (try #require(suggestionController.model.itemsRequestTask)).value
        let fromRow = try #require(
            suggestionController.model.items.firstIndex { $0.label == "FROM" }
        )
        suggestionView.tableView.selectRowIndexes(
            IndexSet(integer: fromRow),
            byExtendingSelection: false
        )
        sendReturnKey(to: textView)
        try await Task.sleep(for: .milliseconds(300))

        let completedSQL = """
        SELECT
        * FROM
        """
        #expect(textView.string == completedSQL)
        #expect(textView.selectionManager.textSelections.count == 1)
        #expect(
            textView.selectedRange()
                == NSRange(location: (completedSQL as NSString).length, length: 0)
        )

        sendReturnKey(to: textView)

        #expect(textView.string == completedSQL + "\n")
        #expect(!suggestionController.isVisible)
    }

    @Test
    func queryDocumentFocusesTheEditorOnceWhenItAppears() throws {
        let sql = "SELECT 1"
        let mountedEditor = mountEditor(
            text: sql,
            selectedRange: NSRange(location: (sql as NSString).length, length: 0)
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let controller = try #require(textViewController(for: textView))
        let languageService = WorkspaceSQLLanguageService()
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: DatabaseConnectionConfiguration(
                host: "127.0.0.1",
                port: 3306,
                username: "reader",
                password: "",
                database: nil,
                tlsMode: .disabled
            ),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let coordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document,
            languageService: languageService
        )

        mountedEditor.window.makeFirstResponder(nil)
        coordinator.controllerDidAppear(controller: controller)
        #expect(mountedEditor.window.firstResponder === textView)

        mountedEditor.window.makeFirstResponder(nil)
        coordinator.controllerDidAppear(controller: controller)
        #expect(mountedEditor.window.firstResponder !== textView)
    }

    @Test
    func retiringOldEditorDoesNotClearTheReplacementEditor() throws {
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: DatabaseConnectionConfiguration(
                host: "127.0.0.1",
                port: 3306,
                username: "reader",
                password: "",
                database: nil,
                tlsMode: .disabled
            ),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let coordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document,
            languageService: WorkspaceSQLLanguageService()
        )
        let firstEditor = mountEditor(text: "", selectedRange: .init())
        let firstTextView = try #require(
            findCodeEditTextView(in: firstEditor.hostingView)
        )
        let firstController = try #require(
            textViewController(for: firstTextView)
        )
        let replacementEditor = mountEditor(text: "", selectedRange: .init())
        let replacementTextView = try #require(
            findCodeEditTextView(in: replacementEditor.hostingView)
        )
        let replacementController = try #require(
            textViewController(for: replacementTextView)
        )

        coordinator.prepareCoordinator(controller: firstController)
        coordinator.prepareCoordinator(controller: replacementController)
        coordinator.destroy()
        replacementTextView.string = "SELECT * FROM users;"
        coordinator.synchronizeDocumentText()

        #expect(document.sql == "SELECT * FROM users;")
        #expect(document.isDirty)
    }

    @Test
    func completionWindowIsANonactivatingPanelThatPreservesEditorFocus() throws {
        let parentWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: parentWindow.contentView?.bounds ?? .zero)
        parentWindow.contentView = textView
        try #require(parentWindow.makeFirstResponder(textView))

        let suggestionController = SuggestionController()
        let suggestionPanel = try #require(suggestionController.window as? NSPanel)

        #expect(suggestionPanel.styleMask.contains(.nonactivatingPanel))
        #expect(!suggestionPanel.styleMask.contains(.utilityWindow))

        suggestionController.showWindow(attachedTo: parentWindow)

        #expect(parentWindow.firstResponder === textView)
        #expect(!suggestionPanel.isKeyWindow)
        #expect(parentWindow.childWindows?.contains(suggestionPanel) == true)

        suggestionController.close()
    }

    @Test
    func completionClosesWhenItsEditorDisappears() throws {
        let mountedEditor = mountEditor(
            text: "SELECT",
            selectedRange: NSRange(location: 6, length: 0)
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let controller = try #require(textViewController(for: textView))
        let suggestionController = SuggestionController.shared
        suggestionController.close()
        suggestionController.model.activeTextView = controller
        suggestionController.showWindow(attachedTo: mountedEditor.window)
        #expect(suggestionController.isVisible)

        controller.viewDidDisappear()

        #expect(!suggestionController.isVisible)
        #expect(suggestionController.model.activeTextView == nil)
    }

    @Test
    func completionSessionSizeOnlyExpands() throws {
        let suggestionController = SuggestionController()
        suggestionController.setCompletionAnchor(
            cursorRect: NSRect(x: 400, y: 400, width: 1, height: 18),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        let initialSize = suggestionController.lockedCompletionSize(
            for: NSSize(width: 256, height: 80)
        )
        let expandedSize = suggestionController.lockedCompletionSize(
            for: NSSize(width: 420, height: 160)
        )
        let retainedSize = suggestionController.lockedCompletionSize(
            for: NSSize(width: 280, height: 60)
        )

        #expect(initialSize == NSSize(width: 256, height: 80))
        #expect(expandedSize == NSSize(width: 420, height: 160))
        #expect(retainedSize == expandedSize)

        suggestionController.close()
    }

    @Test
    func singleCompletionMeasuresEnoughHeightForItsNativeRow() async throws {
        let mountedEditor = mountEditor(
            text: "g",
            selectedRange: NSRange(location: 1, length: 0)
        )
        let textView = try #require(
            findCodeEditTextView(in: mountedEditor.hostingView)
        )
        let editorController = try #require(textViewController(for: textView))
        let cursorPosition = CursorPosition(range: textView.selectedRange())
        let suggestionModel = SuggestionViewModel()
        let delegate = SequencedSuggestionDelegate(
            windowPosition: cursorPosition,
            responses: [["GET"], ["GET", "POST", "HEAD"]]
        )
        let suggestionController = SuggestionController()
        let viewController = SuggestionViewController()
        suggestionController.model = suggestionModel
        viewController.model = suggestionModel
        viewController.windowController = suggestionController
        suggestionController.window?.contentViewController = viewController
        suggestionController.setCompletionAnchor(
            cursorRect: NSRect(x: 400, y: 400, width: 1, height: 18),
            font: editorController.font
        )
        _ = viewController.view

        suggestionModel.showCompletions(
            textView: editorController,
            delegate: delegate,
            cursorPosition: cursorPosition
        ) { _, _ in }
        await (try #require(suggestionModel.itemsRequestTask)).value
        viewController.styleView(using: editorController)
        viewController.renderInitialCandidates(using: editorController)

        let rowView = try #require(
            viewController.tableView.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            )
        )
        rowView.layoutSubtreeIfNeeded()
        let nativeRowHeight = max(
            rowView.fittingSize.height,
            rowView.intrinsicContentSize.height
        )
        let scrollHeight = try #require(
            viewController.scrollViewHeightConstraint
        ).constant

        #expect(nativeRowHeight > 0)
        #expect(
            scrollHeight >= nativeRowHeight
                + SuggestionController.WINDOW_PADDING * 2
        )
        let heightConstraint = try #require(
            viewController.viewHeightConstraint
        )
        let initialHeight = heightConstraint.constant
        let initialWindowHeight = suggestionController.window?.frame.height

        suggestionModel.refreshCompletions(
            textView: editorController,
            delegate: delegate,
            cursorPosition: cursorPosition,
            itemsUnavailable: {
                Issue.record("Expanded method candidates were unavailable")
            },
            itemsLoaded: { _, _ in
                viewController.renderVisibleCandidateRefresh()
            }
        )
        await (try #require(suggestionModel.itemsRequestTask)).value

        #expect(suggestionModel.items.map(\.label) == ["GET", "POST", "HEAD"])
        #expect(viewController.viewHeightConstraint === heightConstraint)
        #expect(heightConstraint.constant > initialHeight)
        #expect(
            (suggestionController.window?.frame.height ?? 0)
                > (initialWindowHeight ?? 0)
        )
        suggestionController.close()
    }

    @Test
    func completionAnchorUsesLayoutAfterTheLatestInsertion() async throws {
        let initialSQL = "SELECT * FROM t"
        let mountedEditor = mountEditor(
            text: initialSQL,
            selectedRange: NSRange(
                location: (initialSQL as NSString).length,
                length: 0
            )
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let controller = try #require(textViewController(for: textView))
        textView.layoutSubtreeIfNeeded()
        let initialCursorRect = try #require(
            textView.layoutManager.rectForOffset(textView.selectedRange().location)
        )

        let relationRange = (textView.string as NSString).range(of: "t")
        textView.replaceCharacters(
            in: relationRange,
            with: "test_chl_oa.attendance_clock w"
        )
        let cursorPosition = CursorPosition(range: textView.selectedRange())
        let delegate = ImmediateSuggestionDelegate(windowPosition: cursorPosition)
        let suggestionModel = SuggestionViewModel()
        var capturedCursorRect: NSRect?

        suggestionModel.showCompletions(
            textView: controller,
            delegate: delegate,
            cursorPosition: cursorPosition
        ) { _, cursorRect in
            capturedCursorRect = cursorRect
        }
        let requestTask = try #require(suggestionModel.itemsRequestTask)
        await requestTask.value

        let screenCursorRect = try #require(capturedCursorRect)
        let localCursorRect = textView.convert(
            mountedEditor.window.convertFromScreen(screenCursorRect),
            from: nil
        )
        #expect(localCursorRect.minX > initialCursorRect.minX + 100)

        suggestionModel.willClose()
    }

    @Test
    func visibleCompletionRefreshKeepsCurrentItemsUntilReplacementArrives() async throws {
        let sql = "SELECT * fro"
        let mountedEditor = mountEditor(
            text: sql,
            selectedRange: NSRange(location: (sql as NSString).length, length: 0)
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let editorController = try #require(textViewController(for: textView))
        let cursorPosition = CursorPosition(range: textView.selectedRange())
        let gate = SuggestionPhaseGate()
        let delegate = PhasedSuggestionDelegate(
            windowPosition: cursorPosition,
            gate: gate
        )
        let suggestionModel = SuggestionViewModel()

        suggestionModel.showCompletions(
            textView: editorController,
            delegate: delegate,
            cursorPosition: cursorPosition
        ) { _, _ in }
        let initialTask = try #require(suggestionModel.itemsRequestTask)
        await initialTask.value

        #expect(suggestionModel.items.first?.label == "WHERE")
        let viewController = SuggestionViewController()
        viewController.model = suggestionModel
        _ = viewController.view
        viewController.renderInitialCandidates(using: editorController)
        #expect(viewController.noItemsLabel.isHidden)

        suggestionModel.refreshCompletions(
            textView: editorController,
            delegate: delegate,
            cursorPosition: cursorPosition,
            itemsUnavailable: {
                Issue.record("The latest completion request unexpectedly returned no items")
            },
            itemsLoaded: { _, _ in }
        )
        let refreshTask = try #require(suggestionModel.itemsRequestTask)
        await Task.yield()

        #expect(suggestionModel.items.first?.label == "WHERE")
        #expect(viewController.noItemsLabel.isHidden)

        await gate.open()
        await refreshTask.value

        #expect(suggestionModel.items.first?.label == "FROM")
        viewController.renderVisibleCandidateRefresh()
        #expect(viewController.noItemsLabel.isHidden)
        suggestionModel.willClose()
    }

    @Test
    func visibleRefreshPreservesSelectionWithoutRepeatingSizing() async throws {
        let sql = "SELECT * fro"
        let mountedEditor = mountEditor(
            text: sql,
            selectedRange: NSRange(location: (sql as NSString).length, length: 0)
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let editorController = try #require(textViewController(for: textView))
        let cursorPosition = CursorPosition(range: textView.selectedRange())
        let delegate = SequencedSuggestionDelegate(
            windowPosition: cursorPosition,
            responses: [
                (0..<20).map { "ITEM_\($0)" },
                ["NEW_0", "NEW_1"] + (0..<20).map { "ITEM_\($0)" },
            ]
        )
        let suggestionModel = SuggestionViewModel()
        let suggestionController = SuggestionController()
        let viewController = SuggestionViewController()
        suggestionController.model = suggestionModel
        viewController.model = suggestionModel
        viewController.windowController = suggestionController
        suggestionController.window?.contentViewController = viewController
        suggestionController.setCompletionAnchor(
            cursorRect: NSRect(x: 400, y: 400, width: 1, height: 18),
            font: editorController.font
        )
        _ = viewController.view

        suggestionModel.showCompletions(
            textView: editorController,
            delegate: delegate,
            cursorPosition: cursorPosition
        ) { _, _ in }
        await (try #require(suggestionModel.itemsRequestTask)).value
        viewController.styleView(using: editorController)
        viewController.renderInitialCandidates(using: editorController)
        viewController.tableView.selectRowIndexes(
            IndexSet(integer: 10),
            byExtendingSelection: false
        )
        viewController.tableView.scrollRowToVisible(10)
        let scrollOrigin = viewController.scrollView.contentView.bounds.origin
        let widthConstraint = try #require(viewController.viewWidthConstraint)
        let heightConstraint = try #require(viewController.viewHeightConstraint)
        let initialFrame = try #require(suggestionController.window).frame

        suggestionModel.refreshCompletions(
            textView: editorController,
            delegate: delegate,
            cursorPosition: cursorPosition,
            itemsUnavailable: {
                Issue.record("The replacement completion request returned no items")
            },
            itemsLoaded: { _, _ in
                viewController.renderVisibleCandidateRefresh()
            }
        )
        await (try #require(suggestionModel.itemsRequestTask)).value

        #expect(viewController.tableView.selectedRow == 12)
        #expect(
            suggestionModel.items[viewController.tableView.selectedRow].label
                == "ITEM_10"
        )
        #expect(viewController.scrollView.contentView.bounds.origin == scrollOrigin)
        #expect(viewController.viewWidthConstraint === widthConstraint)
        #expect(viewController.viewHeightConstraint === heightConstraint)
        #expect(suggestionController.window?.frame == initialFrame)
        suggestionController.close()
    }

    @Test
    func completionArrowNavigationWrapsAtBothEnds() async throws {
        let sql = "SELECT * fro"
        let mountedEditor = mountEditor(
            text: sql,
            selectedRange: NSRange(location: (sql as NSString).length, length: 0)
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let editorController = try #require(textViewController(for: textView))
        let cursorPosition = CursorPosition(range: textView.selectedRange())
        let delegate = SequencedSuggestionDelegate(
            windowPosition: cursorPosition,
            responses: [["SELECT", "FROM", "WHERE"]]
        )
        let suggestionModel = SuggestionViewModel()
        let viewController = SuggestionViewController()
        viewController.model = suggestionModel
        _ = viewController.view

        suggestionModel.showCompletions(
            textView: editorController,
            delegate: delegate,
            cursorPosition: cursorPosition
        ) { _, _ in }
        await (try #require(suggestionModel.itemsRequestTask)).value
        viewController.renderInitialCandidates(using: editorController)

        viewController.tableView.selectRowIndexes(
            IndexSet(integer: 2),
            byExtendingSelection: false
        )
        viewController.moveSelection(by: 1)
        #expect(viewController.tableView.selectedRow == 0)

        viewController.moveSelection(by: -1)
        #expect(viewController.tableView.selectedRow == 2)
        suggestionModel.willClose()
    }

    @Test
    func cancelledRefreshCannotOverwriteTheLatestCandidates() async throws {
        let sql = "SELECT * fro"
        let mountedEditor = mountEditor(
            text: sql,
            selectedRange: NSRange(location: (sql as NSString).length, length: 0)
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let editorController = try #require(textViewController(for: textView))
        let cursorPosition = CursorPosition(range: textView.selectedRange())
        let gate = SuggestionPhaseGate()
        let delegate = PhasedSuggestionDelegate(
            windowPosition: cursorPosition,
            gate: gate
        )
        let suggestionModel = SuggestionViewModel()

        suggestionModel.showCompletions(
            textView: editorController,
            delegate: delegate,
            cursorPosition: cursorPosition
        ) { _, _ in }
        await (try #require(suggestionModel.itemsRequestTask)).value

        suggestionModel.refreshCompletions(
            textView: editorController,
            delegate: delegate,
            cursorPosition: cursorPosition,
            itemsUnavailable: { },
            itemsLoaded: { _, _ in }
        )
        let cancelledTask = try #require(suggestionModel.itemsRequestTask)
        while delegate.numberOfRequests < 2 {
            await Task.yield()
        }

        suggestionModel.refreshCompletions(
            textView: editorController,
            delegate: delegate,
            cursorPosition: cursorPosition,
            itemsUnavailable: { },
            itemsLoaded: { _, _ in }
        )
        let latestTask = try #require(suggestionModel.itemsRequestTask)
        while delegate.numberOfRequests < 3 {
            await Task.yield()
        }

        await gate.open()
        await cancelledTask.value
        await latestTask.value

        #expect(suggestionModel.items.first?.label == "SELECT")
        suggestionModel.willClose()
    }

    @Test
    func completionCommitUsesTheLiveTextSelection() async throws {
        let languageService = WorkspaceSQLLanguageService()
        let completionService = WorkspaceSQLCompletionService(
            languageService: languageService,
            schemaCatalog: .empty,
            defaultDatabase: { nil },
            prepareCompletionColumns: { _ in .empty }
        )
        let sql = "selec"
        let insertionRange = NSRange(
            location: (sql as NSString).length,
            length: 0
        )
        let mountedEditor = mountEditor(
            text: sql,
            selectedRange: insertionRange,
            languageService: languageService,
            completionService: completionService
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let editorController = try #require(textViewController(for: textView))
        let suggestionModel = SuggestionViewModel()

        suggestionModel.showCompletions(
            textView: editorController,
            delegate: completionService,
            cursorPosition: CursorPosition(range: insertionRange)
        ) { _, _ in }
        let requestTask = try #require(suggestionModel.itemsRequestTask)
        await requestTask.value
        let selectItem = try #require(
            suggestionModel.items.first { $0.label == "SELECT" }
        )

        // CodeEdit's mirrored cursor array can lag the native selection during edits.
        editorController.cursorPositions = [
            CursorPosition(range: NSRange(location: 0, length: 0))
        ]
        #expect(textView.selectedRange() == insertionRange)

        suggestionModel.applySelectedItem(item: selectItem)

        #expect(textView.string == "SELECT")
        suggestionModel.willClose()
    }

    @Test
    func completedBeginRemainsExecutableAfterTypingItsSemicolon() async throws {
        let languageService = WorkspaceSQLLanguageService()
        let completionService = WorkspaceSQLCompletionService(
            languageService: languageService,
            schemaCatalog: .empty,
            defaultDatabase: { nil },
            prepareCompletionColumns: { _ in .empty }
        )
        let initialSQL = "beg"
        let insertionRange = NSRange(
            location: (initialSQL as NSString).length,
            length: 0
        )
        let mountedEditor = mountEditor(
            text: initialSQL,
            selectedRange: insertionRange,
            languageService: languageService,
            completionService: completionService
        )
        let textView = try #require(
            findCodeEditTextView(in: mountedEditor.hostingView)
        )
        let editorController = try #require(textViewController(for: textView))
        let suggestionModel = SuggestionViewModel()

        suggestionModel.showCompletions(
            textView: editorController,
            delegate: completionService,
            cursorPosition: CursorPosition(range: insertionRange)
        ) { _, _ in }
        await (try #require(suggestionModel.itemsRequestTask)).value
        let beginItem = try #require(
            suggestionModel.items.first { $0.label == "BEGIN" }
        )
        suggestionModel.applySelectedItem(item: beginItem)
        textView.insertText(
            ";",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let plan = try await languageService.executionPlan(for: .all)

        #expect(textView.string == "BEGIN;")
        #expect(plan.statements.count == 1)
        #expect(plan.statements.first?.kind == .transaction(.begin))
        suggestionModel.willClose()
    }

    @Test
    func pastedMixedTransactionScriptRunsOnlyTheStatementAtTheCursor() async throws {
        let languageService = WorkspaceSQLLanguageService()
        let mountedEditor = mountEditor(
            text: "",
            selectedRange: NSRange(location: 0, length: 0),
            languageService: languageService
        )
        let textView = try #require(
            findCodeEditTextView(in: mountedEditor.hostingView)
        )
        let sql = """
        DROP TEMPORARY TABLE IF EXISTS querycraft_tx_probe;

        CREATE TEMPORARY TABLE querycraft_tx_probe (
            id INT PRIMARY KEY,
            value VARCHAR(32)
        );

        BEGIN;

        INSERT INTO querycraft_tx_probe VALUES (1, 'pending');

        SELECT * FROM querycraft_tx_probe;

        ROLLBACK;

        SELECT * FROM querycraft_tx_probe;
        """
        textView.insertText(
            sql,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let dropLocation = (sql as NSString).range(of: "DROP TEMPORARY").location
        textView.selectionManager.setSelectedRange(
            NSRange(location: dropLocation + 1, length: 0)
        )

        let plan = try await languageService.executionPlan(
            for: .selectionOrCurrentStatement
        )

        #expect(
            plan.statements.map {
                $0.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            } == ["DROP TEMPORARY TABLE IF EXISTS querycraft_tx_probe;"]
        )
        #expect(plan.statements.map(\.kind) == [.ddl(.drop)])
    }

    @Test
    func pastedSQLHighlightsKeywordsAcrossTheEntireVisibleInsertion() async throws {
        let languageService = WorkspaceSQLLanguageService()
        let mountedEditor = mountEditor(
            text: "",
            selectedRange: NSRange(location: 0, length: 0),
            languageService: languageService
        )
        let textView = try #require(
            findCodeEditTextView(in: mountedEditor.hostingView)
        )
        let sql = """
        (
            SELECT 'VALUE' AS data_type, user_phone
            FROM admin_user
            WHERE user_phone IS NOT NULL
                AND user_phone <> ''
            LIMIT 10
        )
        UNION ALL
        (
            SELECT 'NULL' AS data_type, user_phone
            FROM admin_user
            WHERE user_phone IS NULL
            LIMIT 10
        );
        """
        textView.insertText(
            sql,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        _ = try await languageService.executionPlan(for: .all)

        let source = sql as NSString
        let firstSelect = source.range(of: "SELECT")
        let secondSelect = source.range(
            of: "SELECT",
            options: [],
            range: NSRange(
                location: NSMaxRange(firstSelect),
                length: source.length - NSMaxRange(firstSelect)
            )
        )
        let identifier = source.range(of: "data_type")
        var firstColor: NSColor?
        var secondColor: NSColor?
        var identifierColor: NSColor?

        for _ in 0..<40 {
            firstColor = textView.textStorage.attribute(
                .foregroundColor,
                at: firstSelect.location,
                effectiveRange: nil
            ) as? NSColor
            secondColor = textView.textStorage.attribute(
                .foregroundColor,
                at: secondSelect.location,
                effectiveRange: nil
            ) as? NSColor
            identifierColor = textView.textStorage.attribute(
                .foregroundColor,
                at: identifier.location,
                effectiveRange: nil
            ) as? NSColor
            if firstColor == secondColor,
               firstColor != identifierColor
            {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(firstColor == secondColor)
        #expect(firstColor != identifierColor)
    }

    @Test
    func sqlIdentifierUnderscoreRetriggersCompletion() {
        let completionService = WorkspaceSQLCompletionService(
            languageService: WorkspaceSQLLanguageService(),
            schemaCatalog: .empty,
            defaultDatabase: { nil },
            prepareCompletionColumns: { _ in .empty }
        )

        #expect(completionService.completionTriggerCharacters().contains("_"))
    }

    @Test
    func deletingAnIdentifierCharacterRetriggersCompletion() {
        let trigger = SuggestionTriggerCharacterModel.triggerCharacter(
            afterReplacing: NSRange(location: 3, length: 1),
            with: "",
            in: "fro"
        )

        #expect(trigger == "o")
    }

    @Test
    func loadsWithSemanticSystemColors() {
        let editor = WorkspaceCodeEditQueryEditor(
            text: .constant("SELECT 1"),
            selectedRange: .constant(NSRange(location: 0, length: 0)),
            languageService: WorkspaceSQLLanguageService()
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 320)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        #expect(hostingView.fittingSize.width > 0)
        #expect(!hostingView.subviews.isEmpty)
    }

    @Test
    func longSQLScrollsAndRevealsKeyboardDestinationsAcrossAppearances() throws {
        let sql = "SELECT id FROM sample WHERE id IN ("
            + Array(repeating: "1720746103614537730", count: 80)
                .joined(separator: ", ") + ");"
        let end = (sql as NSString).length
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

        for appearance in appearances {
            let languageService = WorkspaceSQLLanguageService()
            let document = WorkspaceQueryDocumentModel(
                title: "Query 1",
                configuration: DatabaseConnectionConfiguration(
                    host: "127.0.0.1", port: 3306, username: "reader",
                    password: "", database: nil, tlsMode: .disabled
                ),
                sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
            )
            document.sql = sql
            let coordinator = WorkspaceQueryEditorCommandCoordinator(
                document: document, languageService: languageService
            )
            let mountedEditor = mountEditor(
                text: sql,
                selectedRange: NSRange(location: 7, length: 0),
                languageService: languageService,
                windowStyleMask: [.titled],
                commandCoordinator: coordinator,
                appearance: appearance
            )
            defer { mountedEditor.window.orderOut(nil) }
            let textView = try #require(
                findCodeEditTextView(in: mountedEditor.hostingView)
            )
            let controller = try #require(textViewController(for: textView))
            let scrollView = try #require(controller.scrollView)
            try #require(mountedEditor.window.makeFirstResponder(textView))
            coordinator.controllerDidAppear(controller: controller)

            #expect(scrollView.hasHorizontalScroller)
            #expect(scrollView.hasVerticalScroller)
            #expect(scrollView.scrollerStyle == .overlay)
            #expect(scrollView.autohidesScrollers)
            #expect(textView.frame.width > scrollView.contentSize.width * 2)
            let acceptedFrame = scrollView.frame

            scrollView.contentView.scroll(to: NSPoint(x: 200, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            #expect(abs(scrollView.contentView.bounds.minX - 200) < 1)

            sendArrowKey(.right, modifiers: [.command], to: textView)
            #expect(textView.selectedRange() == NSRange(location: end, length: 0))
            let endRect = try #require(textView.layoutManager.rectForOffset(end))
            #expect(scrollView.contentView.bounds.minX > 0)
            #expect(endRect.minX <= scrollView.documentVisibleRect.maxX + 1)
            #expect(endRect.minX >= scrollView.documentVisibleRect.minX)

            sendArrowKey(.left, modifiers: [.command], to: textView)
            #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
            #expect(abs(scrollView.contentView.bounds.minX) < 1)
            #expect(scrollView.frame == acceptedFrame)

            sendArrowKey(.right, modifiers: [.command, .shift], to: textView)
            #expect(textView.selectedRange() == NSRange(location: 0, length: end))
            #expect(endRect.minX <= scrollView.documentVisibleRect.maxX + 1)
            sendArrowKey(.left, modifiers: [.command, .shift], to: textView)
            #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
            #expect(abs(scrollView.contentView.bounds.minX) < 1)

            // Reappearing after switching tabs must retain the native scrollers.
            coordinator.controllerDidAppear(controller: controller)
            #expect(scrollView.hasHorizontalScroller)
            #expect(scrollView.hasVerticalScroller)
        }
    }

    @Test
    func commandArrowScrollSurvivesUnpublishedStateAndRepeatedViewUpdates() throws {
        let sql = "SELECT " + Array(repeating: "1234567890", count: 100).joined(separator: ", ")
        let mountedEditor = mountEditor(
            text: sql, selectedRange: NSRange(location: 7, length: 0),
            windowStyleMask: [.titled]
        )
        defer { mountedEditor.window.orderOut(nil) }
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let controller = try #require(textViewController(for: textView))
        let scrollView = try #require(controller.scrollView)
        try #require(mountedEditor.window.makeFirstResponder(textView))
        var state = SourceEditorState(scrollPosition: scrollView.contentView.bounds.origin)
        let coordinator = SourceEditor.Coordinator(
            text: .binding(.constant(sql)),
            editorState: Binding(get: { state }, set: { state = $0 }),
            highlightProviders: []
        )
        coordinator.synchronizeScrollPosition(state.scrollPosition, controller: controller)

        for arrow in [ArrowKey.right, .left, .right, .left] {
            sendArrowKey(arrow, modifiers: [.command], to: textView)
            let destination = scrollView.contentView.bounds.origin
            let caret = try #require(textView.layoutManager.rectForOffset(textView.selectedRange().location))
            #expect(caret.minX <= scrollView.documentVisibleRect.maxX + 1)
            #expect(caret.minX >= scrollView.documentVisibleRect.minX
                + textView.layoutManager.edgeInsets.left - 1)

            // Cursor updates can render SwiftUI before the deferred scroll notification is delivered.
            coordinator.textControllerCursorsDidUpdate(Notification(
                name: TextViewController.cursorPositionUpdatedNotification, object: controller
            ))
            for _ in 0..<2 {
                coordinator.synchronizeScrollPosition(state.scrollPosition, controller: controller)
                #expect(scrollView.contentView.bounds.origin == destination)
            }
            coordinator.textControllerScrollDidChange(Notification(
                name: TextViewController.scrollPositionDidUpdateNotification, object: controller
            ))
            #expect(state.scrollPosition == destination)
            coordinator.synchronizeScrollPosition(state.scrollPosition, controller: controller)
            #expect(scrollView.contentView.bounds.origin == destination)
        }
    }

    @Test
    func scrollBindingPreservesExplicitRequestsAndPublishesNativeScrolling() throws {
        let sql = "SELECT " + Array(repeating: "1234567890", count: 100).joined(separator: ", ")
        let mountedEditor = mountEditor(
            text: sql, selectedRange: NSRange(location: 7, length: 0),
            windowStyleMask: [.titled]
        )
        defer { mountedEditor.window.orderOut(nil) }
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let controller = try #require(textViewController(for: textView))
        let scrollView = try #require(controller.scrollView)
        let initialPosition = CGPoint(x: 100, y: scrollView.contentView.bounds.minY)
        var state = SourceEditorState(scrollPosition: initialPosition)
        let coordinator = SourceEditor.Coordinator(
            text: .binding(.constant(sql)),
            editorState: Binding(get: { state }, set: { state = $0 }),
            highlightProviders: []
        )
        coordinator.synchronizeScrollPosition(state.scrollPosition, controller: controller)
        #expect(scrollView.contentView.bounds.origin == initialPosition)

        let notification = Notification(
            name: TextViewController.scrollPositionDidUpdateNotification, object: controller
        )
        scrollView.contentView.scroll(to: CGPoint(x: 200, y: initialPosition.y))
        let requestedPosition = CGPoint(x: 400, y: initialPosition.y)
        state.scrollPosition = requestedPosition
        // A deferred native notification must not overwrite an external request awaiting the next render.
        coordinator.textControllerScrollDidChange(notification)
        #expect(state.scrollPosition == requestedPosition)
        coordinator.isUpdateFromTextView = true
        coordinator.synchronizeScrollPosition(state.scrollPosition, controller: controller)
        #expect(scrollView.contentView.bounds.origin == requestedPosition)

        let nativePosition = CGPoint(x: 600, y: initialPosition.y)
        scrollView.contentView.scroll(to: nativePosition)
        coordinator.textControllerScrollDidChange(notification)
        #expect(state.scrollPosition == nativePosition)
        coordinator.synchronizeScrollPosition(state.scrollPosition, controller: controller)
        #expect(scrollView.contentView.bounds.origin == nativePosition)

        state.scrollPosition = nil
        coordinator.synchronizeScrollPosition(state.scrollPosition, controller: controller)
        #expect(scrollView.contentView.bounds.origin == nativePosition)
        state.scrollPosition = initialPosition
        coordinator.synchronizeScrollPosition(state.scrollPosition, controller: controller)
        #expect(scrollView.contentView.bounds.origin == initialPosition)
    }

    @Test
    func pastingLongSQLExpandsTheDocumentAndKeepsTheCaretVisible() throws {
        let prefix = "SELECT "
        let mountedEditor = mountEditor(
            text: prefix,
            selectedRange: NSRange(location: prefix.utf16.count, length: 0),
            windowStyleMask: [.titled]
        )
        defer { mountedEditor.window.orderOut(nil) }
        let textView = try #require(
            findCodeEditTextView(in: mountedEditor.hostingView)
        )
        let scrollView = try #require(textView.enclosingScrollView)
        try #require(mountedEditor.window.makeFirstResponder(textView))
        let initialWidth = textView.frame.width
        let pastedText = Array(repeating: "1720746103614537730", count: 80)
            .joined(separator: ", ")

        textView.insertText(pastedText)
        mountedEditor.hostingView.layoutSubtreeIfNeeded()

        #expect(textView.string == prefix + pastedText)
        #expect(textView.frame.width > initialWidth * 2)
        #expect(scrollView.contentView.bounds.minX > 0)
        let caret = try #require(
            textView.layoutManager.rectForOffset(textView.selectedRange().location)
        )
        #expect(caret.minX <= scrollView.documentVisibleRect.maxX + 1)
        #expect(caret.minX >= scrollView.documentVisibleRect.minX)

        let undoManager = try #require(textView.undoManager)
        undoManager.undo()
        #expect(textView.string == prefix)
        undoManager.redo()
        #expect(textView.string == prefix + pastedText)
        #expect(textView.selectedRange() == NSRange(
            location: prefix.utf16.count, length: pastedText.utf16.count
        ))
        let restoredSelectionStart = try #require(
            textView.layoutManager.rectForOffset(prefix.utf16.count)
        )
        #expect(restoredSelectionStart.minX <= scrollView.documentVisibleRect.maxX)
        #expect(restoredSelectionStart.minX >= scrollView.documentVisibleRect.minX
            + textView.layoutManager.edgeInsets.left - 1)
    }

    @Test
    func supportsStandardMacOSArrowKeySelectionAndNavigation() throws {
        let mountedEditor = mountEditor(
            text: "SELECT one;\nSELECT two;",
            selectedRange: NSRange(location: 7, length: 0)
        )
        let textView = try #require(findTextInput(in: mountedEditor.hostingView))
        try #require(mountedEditor.window.makeFirstResponder(textView))

        sendArrowKey(.right, modifiers: [.shift], to: textView)
        #expect(textView.selectedRange() == NSRange(location: 7, length: 1))

        sendArrowKey(.right, modifiers: [.command], to: textView)
        #expect(textView.selectedRange() == NSRange(location: 11, length: 0))

        sendArrowKey(.left, modifiers: [.command, .shift], to: textView)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 11))
    }

    @Test
    func navigatesFromInsertionPointAfterFinalCharacter() throws {
        let sql = "select * from admin_user limit 10;"
        let end = (sql as NSString).length
        let mountedEditor = mountEditor(
            text: sql,
            selectedRange: NSRange(location: end, length: 0)
        )
        let textView = try #require(findTextInput(in: mountedEditor.hostingView))
        try #require(mountedEditor.window.makeFirstResponder(textView))

        sendArrowKey(.left, modifiers: [.command], to: textView)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))

        sendArrowKey(.right, modifiers: [.command], to: textView)
        #expect(textView.selectedRange() == NSRange(location: end, length: 0))

        sendArrowKey(.left, modifiers: [.command, .shift], to: textView)
        #expect(textView.selectedRange() == NSRange(location: 0, length: end))
    }

    @Test
    func appliesCompletionAsOneUndoableEditorMutation() async throws {
        let languageService = WorkspaceSQLLanguageService()
        let completionService = WorkspaceSQLCompletionService(
            languageService: languageService,
            schemaCatalog: .empty,
            defaultDatabase: { nil },
            prepareCompletionColumns: { _ in .empty }
        )
        let mountedEditor = mountEditor(
            text: "sel",
            selectedRange: NSRange(location: 3, length: 0),
            languageService: languageService,
            completionService: completionService
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let controller = try #require(textViewController(for: textView))
        try #require(mountedEditor.window.makeFirstResponder(textView))

        let response = try #require(
            await completionService.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: CursorPosition(
                    range: NSRange(location: 3, length: 0)
                )
            )
        )
        let select = try #require(response.items.first { $0.label == "SELECT" })
        completionService.completionWindowApplyCompletion(
            item: select,
            textView: controller,
            cursorPosition: CursorPosition(
                range: NSRange(location: 3, length: 0)
            )
        )

        #expect(textView.string == "SELECT")
        textView.undoManager?.undo()
        #expect(textView.string == "sel")
    }

    @Test
    func elasticsearchFieldCompletionAcceptsBeforeAutoPairedQuote() async throws {
        let source = """
            POST /second_hand/_search
            {
              "query": {
                "term": {
                  "an"
                }
              }
            }
            """
        let quotedToken = (source as NSString).range(of: "\"an\"")
        let cursor = quotedToken.location + quotedToken.length - 1
        let completionService = WorkspaceElasticsearchCompletionService(
            fields: { _ in ["areaCode", "areaName", "status.keyword"] }
        )
        let mountedEditor = mountEditor(
            text: source,
            selectedRange: NSRange(location: cursor, length: 0)
        )
        let textView = try #require(
            findCodeEditTextView(in: mountedEditor.hostingView)
        )
        let controller = try #require(textViewController(for: textView))
        try #require(mountedEditor.window.makeFirstResponder(textView))
        let cursorPosition = CursorPosition(
            range: NSRange(location: cursor, length: 0)
        )
        let response = try #require(
            await completionService.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: cursorPosition
            )
        )
        let field = try #require(
            response.items.first { $0.label == "areaName" }
        )

        completionService.completionWindowApplyCompletion(
            item: field,
            textView: controller,
            cursorPosition: cursorPosition
        )

        #expect(textView.string.contains("\"areaName\": \"\""))
        #expect(textView.selectedRange().length == 0)
        _ = try JSONSerialization.jsonObject(
            with: Data(
                textView.string
                    .split(separator: "\n", maxSplits: 1)
                    .dropFirst().first.map(String.init)?.utf8 ?? "".utf8
            )
        )
    }

    @Test
    func elasticsearchQueryCompletionReusesEditorGeneratedRootClosingBrace() async throws {
        let initialSource = """
            POST /second_hand/_search
            {
              q
              }
            """
        let prefix = (initialSource as NSString).range(of: "q\n")
        let mountedEditor = mountEditor(
            text: initialSource,
            selectedRange: NSRange(
                location: prefix.location + 1,
                length: 0
            )
        )
        let textView = try #require(
            findCodeEditTextView(in: mountedEditor.hostingView)
        )
        let controller = try #require(textViewController(for: textView))
        try #require(mountedEditor.window.makeFirstResponder(textView))

        let completionService = WorkspaceElasticsearchCompletionService(
            fields: { _ in [] }
        )
        let cursorPosition = CursorPosition(range: textView.selectedRange())
        let response = try #require(
            await completionService.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: cursorPosition
            )
        )
        let query = try #require(
            response.items.first { $0.label == "query" }
        )

        completionService.completionWindowApplyCompletion(
            item: query,
            textView: controller,
            cursorPosition: cursorPosition
        )

        let body = textView.string.split(separator: "\n", maxSplits: 1)
            .dropFirst().first.map(String.init) ?? ""
        _ = try JSONSerialization.jsonObject(with: Data(body.utf8))
        let expected = "POST /second_hand/_search\n"
            + "{\n"
            + "  \"query\": {\n"
            + "    \n"
            + "  }\n"
            + "}"
        #expect(textView.string == expected)
        #expect(body.filter { $0 == "{" }.count == 2)
        #expect(body.filter { $0 == "}" }.count == 2)
        #expect(!body.contains("}}"))
    }

    @Test
    func placesFunctionCursorInsideParentheses() async throws {
        let languageService = WorkspaceSQLLanguageService()
        let completionService = WorkspaceSQLCompletionService(
            languageService: languageService,
            schemaCatalog: .empty,
            defaultDatabase: { nil },
            prepareCompletionColumns: { _ in .empty }
        )
        let mountedEditor = mountEditor(
            text: "coun",
            selectedRange: NSRange(location: 4, length: 0),
            languageService: languageService,
            completionService: completionService
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let controller = try #require(textViewController(for: textView))
        try #require(mountedEditor.window.makeFirstResponder(textView))

        let response = try #require(
            await completionService.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: CursorPosition(
                    range: NSRange(location: 4, length: 0)
                )
            )
        )
        let count = try #require(response.items.first { $0.label == "COUNT" })
        completionService.completionWindowApplyCompletion(
            item: count,
            textView: controller,
            cursorPosition: CursorPosition(
                range: NSRange(location: 4, length: 0)
            )
        )

        #expect(textView.string == "COUNT()")
        #expect(textView.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test
    func markedTextBlocksCompletionRequestsAndCommits() async throws {
        let languageService = WorkspaceSQLLanguageService()
        let completionService = WorkspaceSQLCompletionService(
            languageService: languageService,
            schemaCatalog: .empty,
            defaultDatabase: { nil },
            prepareCompletionColumns: { _ in .empty }
        )
        let mountedEditor = mountEditor(
            text: "sel",
            selectedRange: NSRange(location: 3, length: 0),
            languageService: languageService,
            completionService: completionService
        )
        let textView = try #require(findCodeEditTextView(in: mountedEditor.hostingView))
        let controller = try #require(textViewController(for: textView))
        try #require(mountedEditor.window.makeFirstResponder(textView))
        let oldResponse = try #require(
            await completionService.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: CursorPosition(
                    range: NSRange(location: 3, length: 0)
                )
            )
        )
        let staleSelect = try #require(
            oldResponse.items.first { $0.label == "SELECT" }
        )

        textView.setMarkedText(
            "ni" as NSString,
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let markedRange = textView.selectedRange()
        #expect(textView.hasMarkedText())
        #expect(
            await completionService.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: CursorPosition(range: markedRange)
            ) == nil
        )

        completionService.completionWindowApplyCompletion(
            item: staleSelect,
            textView: controller,
            cursorPosition: CursorPosition(range: markedRange)
        )
        #expect(textView.string == "selni")
    }

    private func mountEditor(
        text: String,
        selectedRange: NSRange,
        languageService: WorkspaceSQLLanguageService = WorkspaceSQLLanguageService(),
        completionService: WorkspaceSQLCompletionService? = nil,
        windowStyleMask: NSWindow.StyleMask = .borderless,
        commandCoordinator: WorkspaceQueryEditorCommandCoordinator? = nil,
        appearance: NSAppearance.Name? = nil
    ) -> (window: NSWindow, hostingView: NSHostingView<WorkspaceCodeEditQueryEditor>) {
        let editor = WorkspaceCodeEditQueryEditor(
            text: .constant(text),
            selectedRange: .constant(selectedRange),
            languageService: languageService,
            commandCoordinator: commandCoordinator,
            completionService: completionService
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 320)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: windowStyleMask,
            backing: .buffered,
            defer: false
        )
        if let appearance {
            window.appearance = NSAppearance(named: appearance)
        }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        return (window, hostingView)
    }

    private func findTextInput(in view: NSView) -> (NSView & NSTextInputClient)? {
        if let textInput = view as? (NSView & NSTextInputClient) {
            return textInput
        }
        return view.subviews.lazy.compactMap(findTextInput(in:)).first
    }

    private func findCodeEditTextView(in view: NSView) -> TextView? {
        if let textView = view as? TextView { return textView }
        return view.subviews.lazy.compactMap(findCodeEditTextView(in:)).first
    }

    private func textViewController(for textView: TextView) -> TextViewController? {
        var responder: NSResponder? = textView
        while let current = responder {
            if let controller = current as? TextViewController {
                return controller
            }
            responder = current.nextResponder
        }
        return nil
    }

    private func sendArrowKey(
        _ arrow: ArrowKey,
        modifiers: NSEvent.ModifierFlags,
        to textView: NSView
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: textView.window?.windowNumber ?? 0,
            context: nil,
            characters: arrow.characters,
            charactersIgnoringModifiers: arrow.characters,
            isARepeat: false,
            keyCode: arrow.keyCode
        ) else {
            Issue.record("Failed to create arrow key event")
            return
        }

        if !textView.performKeyEquivalent(with: event) {
            textView.keyDown(with: event)
        }
    }

    private func sendReturnKey(to textView: NSView) {
        textView.window?.makeKeyAndOrderFront(nil)
        _ = textView.window?.makeFirstResponder(textView)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: textView.window?.windowNumber ?? 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else {
            Issue.record("Failed to create Return key event")
            return
        }
        NSApp.sendEvent(event)
    }

    private enum ArrowKey {
        case left
        case right

        var keyCode: UInt16 {
            switch self {
            case .left: 123
            case .right: 124
            }
        }

        var characters: String {
            switch self {
            case .left: "\u{F702}"
            case .right: "\u{F703}"
            }
        }
    }
}

@MainActor
private final class ImmediateSuggestionDelegate: CodeSuggestionDelegate {
    private let windowPosition: CursorPosition

    init(windowPosition: CursorPosition) {
        self.windowPosition = windowPosition
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        (windowPosition, [TestSuggestionEntry()])
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) { }
}

@MainActor
private final class PhasedSuggestionDelegate: CodeSuggestionDelegate {
    private let windowPosition: CursorPosition
    private let gate: SuggestionPhaseGate
    private var requestCount = 0
    var numberOfRequests: Int { requestCount }

    init(windowPosition: CursorPosition, gate: SuggestionPhaseGate) {
        self.windowPosition = windowPosition
        self.gate = gate
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        requestCount += 1
        let requestNumber = requestCount
        if requestNumber > 1 {
            await gate.wait()
        }
        let label = switch requestNumber {
        case 1: "WHERE"
        case 2: "FROM"
        default: "SELECT"
        }
        return (windowPosition, [TestSuggestionEntry(label: label)])
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) { }
}

@MainActor
private final class SequencedSuggestionDelegate: CodeSuggestionDelegate {
    private let windowPosition: CursorPosition
    private var responses: [[String]]

    init(windowPosition: CursorPosition, responses: [[String]]) {
        self.windowPosition = windowPosition
        self.responses = responses
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard !responses.isEmpty else { return nil }
        let labels = responses.removeFirst()
        return (windowPosition, labels.map(TestSuggestionEntry.init))
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) { }
}

private actor SuggestionPhaseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private struct TestSuggestionEntry: CodeSuggestionEntry {
    let label: String
    let detail: String? = "keyword"
    let documentation: String? = nil
    let pathComponents: [String]? = nil
    let targetPosition: CursorPosition? = nil
    let sourcePreview: String? = nil
    let image = Image(systemName: "chevron.left.forwardslash.chevron.right")
    let imageColor = Color.purple
    let deprecated = false

    init(label: String = "WHERE") {
        self.label = label
    }
}
