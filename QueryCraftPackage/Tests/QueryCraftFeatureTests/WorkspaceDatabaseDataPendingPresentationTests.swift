import AppKit
import Testing

@testable import QueryCraftFeature

@MainActor
struct WorkspaceDatabaseDataPendingPresentationTests {
    @Test
    func pendingCellUpdateImmediatelyRefreshesVisibleValueAndColor() throws {
        let page = makePage()
        let coordinator = makeCoordinator(page: page)
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        _ = scrollView
        let rowView = try visibleRowView(at: 0, in: tableView)
        #expect(rowView.accessibilityValue() as? String == "1, before")
        #expect(rowView.pendingPresentationBackgroundColor == nil)

        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            pendingLoadedUpdates: [makePendingUpdate()]
        )

        #expect(rowView.accessibilityValue() as? String == "1, 123")
        #expect(rowView.pendingPresentationBackgroundColor == nil)
        #expect(rowView.pendingUpdateBackgroundColor(at: 0) == nil)
        let background = try #require(
            rowView.pendingUpdateBackgroundColor(at: 1)?.usingColorSpace(
                .deviceRGB
            )
        )
        #expect(background.redComponent > background.greenComponent)
        #expect(background.greenComponent > background.blueComponent)
    }

    @Test
    func pendingCellColorsTrackMultipleUpdatesAndDiscard() throws {
        let page = makePage(rowCount: 2)
        let coordinator = makeCoordinator(page: page)
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        _ = scrollView
        let first = try visibleRowView(at: 0, in: tableView)
        let second = try visibleRowView(at: 1, in: tableView)
        let nameUpdate = makePendingUpdate()
        let idUpdate = makePendingUpdate(
            columnName: "id",
            originalValue: "1",
            newValue: "7"
        )

        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            pendingLoadedUpdates: [nameUpdate, idUpdate]
        )

        #expect(first.accessibilityValue() as? String == "7, 123")
        #expect(first.pendingUpdateBackgroundColor(at: 0) != nil)
        #expect(first.pendingUpdateBackgroundColor(at: 1) != nil)
        #expect(second.pendingUpdateBackgroundColor(at: 0) == nil)
        #expect(second.pendingUpdateBackgroundColor(at: 1) == nil)

        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            pendingLoadedUpdates: [nameUpdate]
        )

        #expect(first.accessibilityValue() as? String == "1, 123")
        #expect(first.pendingUpdateBackgroundColor(at: 0) == nil)
        #expect(first.pendingUpdateBackgroundColor(at: 1) != nil)

        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in }
        )

        #expect(first.accessibilityValue() as? String == "1, before")
        #expect(first.pendingUpdateBackgroundColor(at: 0) == nil)
        #expect(first.pendingUpdateBackgroundColor(at: 1) == nil)
    }

    @Test
    func selectionAndDeletionOverridePendingCellColor() throws {
        let page = makePage()
        let coordinator = makeCoordinator(page: page)
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        _ = scrollView
        let rowView = try visibleRowView(at: 0, in: tableView)

        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            pendingLoadedUpdates: [makePendingUpdate()]
        )

        #expect(
            rowView.cellBackgroundColor(
                at: 1,
                isGridSelected: true,
                isWindowKey: true
            ) == .selectedContentBackgroundColor
        )
        #expect(
            rowView.cellBackgroundColor(
                at: 1,
                isGridSelected: true,
                isWindowKey: false
            ) == .unemphasizedSelectedContentBackgroundColor
        )

        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            pendingLoadedUpdates: [makePendingUpdate()],
            pendingDeleteRowIndexes: [0]
        )

        #expect(
            rowView.cellBackgroundColor(
                at: 1,
                isGridSelected: false,
                isWindowKey: true
            ) == nil
        )
        #expect(rowView.pendingPresentationBackgroundColor != nil)
    }

    @Test
    func pendingDeleteImmediatelyRefreshesEverySelectedVisibleRow() throws {
        let page = makePage(rowCount: 3)
        let coordinator = makeCoordinator(page: page)
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        _ = scrollView
        let first = try visibleRowView(at: 0, in: tableView)
        let middle = try visibleRowView(at: 1, in: tableView)
        let last = try visibleRowView(at: 2, in: tableView)

        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            pendingDeleteRowIndexes: IndexSet([0, 2])
        )

        for rowView in [first, last] {
            let background = try #require(
                rowView.pendingPresentationBackgroundColor?.usingColorSpace(
                    .deviceRGB
                )
            )
            #expect(background.redComponent > background.greenComponent)
        }
        #expect(middle.pendingPresentationBackgroundColor == nil)
    }

    @Test
    func externalSelectionMovesOffThePendingDeletedRow() throws {
        let page = makePage(rowCount: 3)
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            selectedRowIndexes: [1]
        )
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        _ = scrollView
        #expect(tableView.gridSelection.active?.row == 1)

        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            pendingDeleteRowIndexes: [1],
            selectedRowIndexes: [2]
        )

        #expect(tableView.gridSelection.active?.row == 2)
        #expect(tableView.selectedDataRowIndexesForActions == [2])
    }

    @Test
    func cellSelectionPublishesOutsideTheImmediateSelectionPath() async throws {
        let page = makePage(rowCount: 2)
        var publishedRows: IndexSet?
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            selectRowsForActions: { publishedRows = $0 }
        )
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        _ = scrollView

        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 1, column: 1),
            active: WorkspaceGridCoordinate(row: 1, column: 1)
        )

        #expect(publishedRows == nil)
        await waitForSelectionPublication()
        #expect(publishedRows == [1])
    }

    @Test
    func rapidCrossRowSelectionPublishesOnlyTheLatestRow() async throws {
        let page = makePage(rowCount: 3)
        var publishedRows: [IndexSet] = []
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            selectRowsForActions: { publishedRows.append($0) }
        )
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        _ = scrollView

        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 0, column: 1),
            active: WorkspaceGridCoordinate(row: 0, column: 1)
        )
        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 2, column: 1),
            active: WorkspaceGridCoordinate(row: 2, column: 1)
        )

        #expect(publishedRows.isEmpty)
        await waitForSelectionPublication()
        #expect(publishedRows == [IndexSet(integer: 2)])
        #expect(tableView.selectedDataRowIndexesForActions == [2])
    }

    @Test
    func pendingCrossRowSelectionIsNotRevertedByStaleViewState() async throws {
        let page = makePage(rowCount: 3)
        var publishedRows = IndexSet()
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            selectRowsForActions: { publishedRows = $0 }
        )
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        _ = scrollView

        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 2, column: 1),
            active: WorkspaceGridCoordinate(row: 2, column: 1)
        )
        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            selectedRowIndexes: [],
            selectRowsForActions: { publishedRows = $0 }
        )

        #expect(tableView.gridSelection.active?.row == 2)
        await waitForSelectionPublication()
        #expect(publishedRows == [2])
    }

    @Test
    func endingLoadedCellEditDoesNotPublishFocusClearedSelection() async throws {
        let page = makePage()
        var publishedRows: [IndexSet] = []
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            prepareCellEdit: { target in
                WorkspaceDatabaseDataCellInlineEditContext(
                    rowIndex: target.rowIndex,
                    dataColumnIndex: target.dataColumnIndex,
                    columnName: target.column?.name ?? "",
                    initialText: "before",
                    initialMutation: .value("before")
                )
            },
            selectRowsForActions: { publishedRows.append($0) }
        )
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        _ = scrollView
        let coordinate = WorkspaceGridCoordinate(row: 0, column: 2)
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.cellEditHandler?(0, 2)
        let editor = try #require(
            tableView.subviews.compactMap { $0 as? NSTextField }.first {
                $0.accessibilityIdentifier() == "dataCellInlineEditor"
            }
        )
        let editorDelegate = try #require(
            editor.delegate as? WorkspaceDataCellInlineEditor
        )

        tableView.clearGridSelection()
        editorDelegate.controlTextDidEndEditing(
            Notification(
                name: NSControl.textDidEndEditingNotification,
                object: editor
            )
        )

        #expect(tableView.gridSelection.isEmpty)
        #expect(tableView.selectedDataRowIndexesForActions.isEmpty)
        await waitForSelectionPublication()
        #expect(publishedRows == [IndexSet(integer: 0)])
    }

    @Test
    func discardingAfterFocusLossDoesNotRestoreFirstColumnSelection() throws {
        let page = makePage()
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            prepareCellEdit: { target in
                WorkspaceDatabaseDataCellInlineEditContext(
                    rowIndex: target.rowIndex,
                    dataColumnIndex: target.dataColumnIndex,
                    columnName: target.column?.name ?? "",
                    initialText: "before",
                    initialMutation: .value("before")
                )
            },
            selectedRowIndexes: [0]
        )
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        scrollView.frame.size.width = 90
        scrollView.layoutSubtreeIfNeeded()
        let coordinate = WorkspaceGridCoordinate(row: 0, column: 2)
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollColumnToVisible(2)
        let horizontalOrigin = scrollView.contentView.bounds.origin.x
        tableView.cellEditHandler?(0, 2)
        let editor = try #require(
            tableView.subviews.compactMap { $0 as? NSTextField }.first {
                $0.accessibilityIdentifier() == "dataCellInlineEditor"
            }
        )
        let editorDelegate = try #require(
            editor.delegate as? WorkspaceDataCellInlineEditor
        )

        tableView.clearGridSelection()
        editorDelegate.controlTextDidEndEditing(
            Notification(
                name: NSControl.textDidEndEditingNotification,
                object: editor
            )
        )
        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            selectedRowIndexes: [0]
        )

        #expect(tableView.gridSelection.isEmpty)
        #expect(tableView.selectedDataRowIndexesForActions.isEmpty)
        #expect(scrollView.contentView.bounds.origin.x == horizontalOrigin)
    }

    @Test
    func committedPageRefreshRestoresThePreviouslyActiveColumn() throws {
        let page = makeWidePage()
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            selectedRowIndexes: [0]
        )
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        scrollView.frame.size.width = 180
        scrollView.layoutSubtreeIfNeeded()
        let editedColumn = 6
        let coordinate = WorkspaceGridCoordinate(
            row: 0,
            column: editedColumn
        )
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollColumnToVisible(editedColumn)
        let horizontalOrigin = scrollView.contentView.bounds.origin.x
        #expect(horizontalOrigin > 0)

        coordinator.update(
            page: page,
            isFetching: true,
            sortData: { _ in },
            selectedRowIndexes: []
        )
        coordinator.update(
            page: makeWidePage(valueSuffix: " refreshed"),
            isFetching: false,
            sortData: { _ in },
            selectedRowIndexes: [0]
        )

        #expect(tableView.gridSelection.active?.row == 0)
        #expect(tableView.gridSelection.active?.column == editedColumn)
        #expect(tableView.selectedDataRowIndexesForActions == [0])
        #expect(scrollView.contentView.bounds.origin.x == horizontalOrigin)
    }

    @Test
    func asynchronousDocumentCellsOfferNullAndEmptyStringMutations() async throws {
        let page = WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "_id"),
                WorkspaceDatabaseDataColumn(id: 1, name: "_index"),
                WorkspaceDatabaseDataColumn(id: 2, name: "_routing"),
                WorkspaceDatabaseDataColumn(id: 3, name: "name"),
            ],
            rows: [
                WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [
                        .text("routed-1"),
                        .text("logs"),
                        .text("tenant-a"),
                        .text("before"),
                    ]
                ),
            ],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
        var retainedCoordinator: WorkspaceDatabaseDataTableCoordinator?
        let mutation = await withCheckedContinuation { continuation in
            let coordinator = WorkspaceDatabaseDataTableCoordinator(
                page: page,
                isFetching: false,
                sortData: { _ in },
                prepareCellEditAsync: { target in
                    WorkspaceDatabaseDataCellInlineEditContext(
                        rowIndex: target.rowIndex,
                        dataColumnIndex: target.dataColumnIndex,
                        columnName: target.column?.name ?? "",
                        initialText: "before",
                        initialMutation: .value("before")
                    )
                },
                updateCellEdit: { _, mutation in
                    continuation.resume(returning: mutation)
                }
            )
            retainedCoordinator = coordinator
            let tableView = coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
            #expect(tableView?.canEditCellHandler?(0, 3) == false)
            #expect(tableView?.canEditCellHandler?(0, 4) == true)
            #expect(
                tableView?.cellValueMutationMenuItemsProvider?(0, 3).isEmpty
                    == true
            )
            let items = tableView?.cellValueMutationMenuItemsProvider?(0, 4)
                ?? []
            #expect(items.map(\.title) == [
                AppCopy.current.text("设为 NULL", "Set to NULL"),
                AppCopy.current.text("设为空字符串", "Set to Empty String"),
            ])
            let menu = NSMenu()
            items.forEach(menu.addItem)
            menu.performActionForItem(at: 0)
        }
        _ = retainedCoordinator
        #expect(mutation == .null)
    }

    @Test
    func nullInlineEditorUsesAPlaceholderWithoutCreatingAStringUpdate() throws {
        let page = makePage()
        var mutations: [WorkspaceDatabaseInspectorMutation] = []
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            prepareCellEdit: { target in
                WorkspaceDatabaseDataCellInlineEditContext(
                    rowIndex: target.rowIndex,
                    dataColumnIndex: target.dataColumnIndex,
                    columnName: target.column?.name ?? "",
                    initialText: "",
                    initialMutation: .null,
                    placeholderText: "NULL"
                )
            },
            updateCellEdit: { _, mutation in mutations.append(mutation) }
        )
        let (scrollView, tableView) = try makeVisibleTable(coordinator)
        _ = scrollView

        tableView.cellEditHandler?(0, 2)
        let editor = try #require(
            tableView.subviews.compactMap { $0 as? NSTextField }.first {
                $0.accessibilityIdentifier() == "dataCellInlineEditor"
            }
        )
        #expect(editor.stringValue.isEmpty)
        #expect(editor.placeholderAttributedString?.string == "NULL")
        let editorDelegate = try #require(
            editor.delegate as? WorkspaceDataCellInlineEditor
        )
        editorDelegate.controlTextDidEndEditing(
            Notification(
                name: NSControl.textDidEndEditingNotification,
                object: editor
            )
        )

        #expect(mutations.isEmpty)
    }

    @Test
    func elasticsearchDocumentMenuUsesDeleteAndUndoLabels() throws {
        let page = makePage(rowCount: 2)
        var addCount = 0
        var duplicatedRows: [Int] = []
        var requestedRows: [IndexSet] = []
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            selectedRowIndexes: [0],
            rowActionKind: .elasticsearchDocument,
            addRow: { addCount += 1 },
            duplicateRow: { duplicatedRows.append($0) },
            deleteRows: { requestedRows.append($0) }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        let items = try #require(
            tableView.additionalCellContextMenuItemsProvider?(0, 1)
        )
        #expect(items.map(\.title) == [
            AppCopy.current.text("新增文档", "Add Document"),
            AppCopy.current.text("复制文档", "Copy Document"),
            AppCopy.current.text(
                "复制为新增文档",
                "Duplicate as New Document"
            ),
            AppCopy.current.text("删除文档", "Delete Document"),
        ])
        let addItem = items[0]
        let addAction = try #require(addItem.action)
        #expect(addItem.isEnabled)
        #expect(
            NSApp.sendAction(
                addAction,
                to: addItem.target,
                from: addItem
            )
        )
        #expect(addCount == 1)
        let duplicateItem = items[2]
        let duplicateAction = try #require(duplicateItem.action)
        #expect(duplicateItem.isEnabled)
        #expect(
            NSApp.sendAction(
                duplicateAction,
                to: duplicateItem.target,
                from: duplicateItem
            )
        )
        #expect(duplicatedRows == [0])
        let deleteItem = try #require(items.last)
        let deleteAction = try #require(deleteItem.action)
        #expect(deleteItem.isEnabled)
        #expect(
            NSApp.sendAction(
                deleteAction,
                to: deleteItem.target,
                from: deleteItem
            )
        )
        #expect(requestedRows == [IndexSet(integer: 0)])

        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            pendingDeleteRowIndexes: [0],
            selectedRowIndexes: [0],
            rowActionKind: .elasticsearchDocument,
            addRow: { addCount += 1 },
            deleteRows: { requestedRows.append($0) }
        )
        #expect(tableView.selectedDataRowIndexesForActions == [0])
        let pendingItems = try #require(
            tableView.additionalCellContextMenuItemsProvider?(0, 1)
        )
        #expect(
            pendingItems.last?.title
                == AppCopy.current.text("撤销删除", "Undo Delete")
        )
        let undoItem = try #require(pendingItems.last)
        let undoAction = try #require(undoItem.action)
        #expect(
            NSApp.sendAction(
                undoAction,
                to: undoItem.target,
                from: undoItem
            )
        )
        #expect(requestedRows.last == IndexSet(integer: 0))
    }

    @Test
    func elasticsearchCreationDraftCanBeDiscardedFromItsRowMenu() throws {
        let page = makePage(rowCount: 1)
        let request = WorkspaceDatabaseDataRowInsertRequest
            .makeElasticsearchDocument(
                selection: WorkspaceDatabaseObjectSelection(
                    databaseName: "Elasticsearch",
                    objectName: "logs",
                    kind: .elasticsearchIndex
                ),
                pageColumns: page.columns
            )
        var editor = WorkspaceDatabaseDataRowInsertEditorState()
        editor.present(request)
        var requestedRows: [IndexSet] = []
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            rowInsertEditor: editor,
            selectedRowIndexes: [page.rowCount],
            rowActionKind: .elasticsearchDocument,
            addRow: {},
            deleteRows: { requestedRows.append($0) }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        let items = try #require(
            tableView.additionalCellContextMenuItemsProvider?(
                page.rowCount,
                1
            )
        )
        let discardItem = try #require(items.last)
        #expect(
            discardItem.title
                == AppCopy.current.text(
                    "放弃新增文档",
                    "Discard New Document"
                )
        )
        let action = try #require(discardItem.action)
        #expect(
            NSApp.sendAction(action, to: discardItem.target, from: discardItem)
        )
        #expect(requestedRows == [IndexSet(integer: page.rowCount)])
    }

    @Test
    func elasticsearchDocumentDeleteKeysDeleteSelectedRows() throws {
        let page = makePage(rowCount: 2)
        var requestedRows: [IndexSet] = []
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            rowActionKind: .elasticsearchDocument,
            deleteRows: { requestedRows.append($0) }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        tableView.selectRowIndexes([0, 1], byExtendingSelection: false)
        tableView.keyDown(with: try deleteKeyEvent(keyCode: 51))
        #expect(requestedRows == [IndexSet([0, 1])])

        tableView.selectRowIndexes([1], byExtendingSelection: false)
        tableView.keyDown(with: try deleteKeyEvent(keyCode: 117))
        #expect(requestedRows == [IndexSet([0, 1]), IndexSet(integer: 1)])
    }

    @Test
    func elasticsearchDuplicateShortcutUsesPhysicalDKeyWithChineseInput()
        async throws
    {
        var duplicatedRows: [Int] = []
        let actions = WorkspaceDatabaseDataRowCommandActions(
            selectedRowIndexes: IndexSet(integer: 1),
            canAddRow: true,
            canDuplicateRow: true,
            canDeleteRow: true,
            addRow: {},
            duplicateRow: { duplicatedRows.append($0) },
            deleteRows: { _ in }
        )
        let coordinator = WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator(
            actions: actions,
            filterPresentationActions: nil,
            objectDetailTabActions: nil,
            isSuspended: false
        )
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "文",
            charactersIgnoringModifiers: "文",
            isARepeat: false,
            keyCode: 2
        ))

        #expect(coordinator.handle(event))
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
        #expect(duplicatedRows == [1])
    }

    @Test
    func textEditorKeepsDeleteKeyForTextEditing() {
        #expect(
            WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator
                .isTextEditingResponder(NSTextView())
        )
        #expect(
            !WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator
                .isTextEditingResponder(NSView())
        )
    }

    private func deleteKeyEvent(keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: String(UnicodeScalar(0x7f)),
            charactersIgnoringModifiers: String(UnicodeScalar(0x7f)),
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func waitForSelectionPublication() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func makeCoordinator(
        page: WorkspaceDatabaseDataPage
    ) -> WorkspaceDatabaseDataTableCoordinator {
        WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in }
        )
    }

    private func makeVisibleTable(
        _ coordinator: WorkspaceDatabaseDataTableCoordinator
    ) throws -> (NSScrollView, WorkspaceDirectDrawTableView) {
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        scrollView.layoutSubtreeIfNeeded()
        return (scrollView, tableView)
    }

    private func visibleRowView(
        at row: Int,
        in tableView: WorkspaceDirectDrawTableView
    ) throws -> WorkspaceDatabaseDataRowView {
        try #require(
            tableView.rowView(atRow: row, makeIfNecessary: true)
                as? WorkspaceDatabaseDataRowView
        )
    }

    private func makePage(
        rowCount: Int = 1
    ) -> WorkspaceDatabaseDataPage {
        WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "id"),
                WorkspaceDatabaseDataColumn(id: 1, name: "name"),
            ],
            rows: (0..<rowCount).map { row in
                WorkspaceDatabaseDataRow(
                    id: row,
                    values: [.text(String(row + 1)), .text("before")]
                )
            },
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
    }

    private func makeWidePage(
        valueSuffix: String = ""
    ) -> WorkspaceDatabaseDataPage {
        let columns = (0..<8).map {
            WorkspaceDatabaseDataColumn(id: $0, name: "field_\($0)")
        }
        return WorkspaceDatabaseDataPage(
            columns: columns,
            rows: [
                WorkspaceDatabaseDataRow(
                    id: 0,
                    values: columns.map {
                        .text("value_\($0.id)\(valueSuffix)")
                    }
                ),
            ],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
    }

    private func makePendingUpdate(
        columnName: String = "name",
        originalValue: String = "before",
        newValue: String = "123"
    )
        -> WorkspaceDatabaseInspectorPendingUpdate
    {
        WorkspaceDatabaseInspectorPendingUpdate(
            update: WorkspaceDatabaseDataCellUpdate(
                selection: WorkspaceDatabaseObjectSelection(
                    databaseName: "querycraft_test",
                    objectName: "users",
                    kind: .table
                ),
                columnName: columnName,
                originalValue: .text(originalValue),
                newValue: .text(newValue),
                primaryKey: [
                    .init(columnName: "id", value: .text("1")),
                ]
            )
        )
    }
}
