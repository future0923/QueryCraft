import AppKit

@MainActor
final class RedisCollectionGridCoordinator: NSObject {
    private static let rowNumberIdentifier = NSUserInterfaceItemIdentifier(
        "redis.collection.rowNumber"
    )
    private static let firstIdentifier = NSUserInterfaceItemIdentifier(
        "redis.collection.first"
    )
    private static let secondIdentifier = NSUserInterfaceItemIdentifier(
        "redis.collection.second"
    )
    private static let actionIdentifier = NSUserInterfaceItemIdentifier(
        "redis.collection.action"
    )
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier(
        "redis.collection.row"
    )

    private var rows: [RedisKeyEditableRow]
    private var kind: RedisCollectionGridKind
    private var isEnabled: Bool
    private var selectedRowIndexes: IndexSet
    private let searchController: WorkspaceGridSearchController
    private var searchPresentationActions: WorkspaceGridSearchCommandActions
    private var searchSourceRevision = UUID()
    private var addRow: @MainActor () -> Void
    private var updateValue: @MainActor (
        RedisKeyEditableRow.ID,
        RedisKeyEditableCell,
        String
    ) -> Void
    private var removeRow: @MainActor (RedisKeyEditableRow.ID) -> Void
    private var selectRows: @MainActor (IndexSet) -> Void
    private var columnIndexes: [NSUserInterfaceItemIdentifier: Int] = [:]
    private weak var tableView: WorkspaceDirectDrawTableView?
    private weak var inlineEditor: RedisCollectionNativeTextField?
    private var editingRowID: RedisKeyEditableRow.ID?
    private var editingCell: RedisKeyEditableCell?
    private var editingTableColumnIndex: Int?
    private var editingInitialText = ""
    private var editingText = ""
    private var isEndingEdit = false
    private var isApplyingAutomaticColumnWidths = false
    private var isSynchronizingSelection = false
    private var selectedRowsPublicationTask: Task<Void, Never>?
    private var pendingSelectedRowsForActions: IndexSet?

    isolated deinit {
        selectedRowsPublicationTask?.cancel()
    }

    init(
        rows: [RedisKeyEditableRow],
        kind: RedisCollectionGridKind,
        isEnabled: Bool,
        selectedRowIndexes: IndexSet,
        searchController: WorkspaceGridSearchController =
            WorkspaceGridSearchController(),
        searchPresentationActions: WorkspaceGridSearchCommandActions,
        addRow: @escaping @MainActor () -> Void,
        updateValue: @escaping @MainActor (
            RedisKeyEditableRow.ID,
            RedisKeyEditableCell,
            String
        ) -> Void,
        removeRow: @escaping @MainActor (RedisKeyEditableRow.ID) -> Void,
        selectRows: @escaping @MainActor (IndexSet) -> Void
    ) {
        self.rows = rows
        self.kind = kind
        self.isEnabled = isEnabled
        self.selectedRowIndexes = selectedRowIndexes
        self.searchController = searchController
        self.searchPresentationActions = searchPresentationActions
        self.addRow = addRow
        self.updateValue = updateValue
        self.removeRow = removeRow
        self.selectRows = selectRows
    }

    func makeScrollView() -> NSScrollView {
        let tableView = WorkspaceDirectDrawTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.workspaceDataSource = self
        tableView.rowNumberIdentifier = Self.rowNumberIdentifier
        tableView.gridSearchController = searchController
        tableView.gridSearchPresentationActions = searchPresentationActions
        let headerView = WorkspaceGridHeaderView()
        headerView.resetColumnWidths = { [weak self] in
            self?.applyAutomaticColumnWidths()
        }
        headerView.frame.size.height = WorkspaceGridMetrics.headerHeight
        tableView.headerView = headerView
        let font = WorkspaceGridMetrics.cellFont
        tableView.rowHeight = max(
            24,
            ceil(font.ascender - font.descender + font.leading) + 6
        )
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.style = .fullWidth
        tableView.setAccessibilityIdentifier("redis.collection.grid")
        installHandlers(in: tableView)

        let scrollView = NSScrollView()
        scrollView.contentView = WorkspaceGridViewportClipView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.setAccessibilityIdentifier("redis.collection.grid")

        self.tableView = tableView
        rebuildColumns(in: tableView)
        syncSelection(in: tableView)
        updateSearchSource()
        searchController.attachSelectionHandler { [weak self] match in
            self?.revealSearchMatch(match)
        }
        return scrollView
    }

    func update(
        rows: [RedisKeyEditableRow],
        kind: RedisCollectionGridKind,
        isEnabled: Bool,
        selectedRowIndexes: IndexSet,
        searchPresentationActions: WorkspaceGridSearchCommandActions,
        addRow: @escaping @MainActor () -> Void,
        updateValue: @escaping @MainActor (
            RedisKeyEditableRow.ID,
            RedisKeyEditableCell,
            String
        ) -> Void,
        removeRow: @escaping @MainActor (RedisKeyEditableRow.ID) -> Void,
        selectRows: @escaping @MainActor (IndexSet) -> Void
    ) {
        let previousRows = self.rows
        let previousKind = self.kind
        let previousEnabled = self.isEnabled
        let previousSelection = self.selectedRowIndexes
        self.rows = rows
        self.kind = kind
        self.isEnabled = isEnabled
        self.selectedRowIndexes = selectedRowIndexes
        self.searchPresentationActions = searchPresentationActions
        self.addRow = addRow
        self.updateValue = updateValue
        self.removeRow = removeRow
        self.selectRows = selectRows

        guard let tableView else { return }
        tableView.gridSearchPresentationActions = searchPresentationActions
        installHandlers(in: tableView)
        if previousKind != kind {
            searchSourceRevision = UUID()
            finishEditing()
            rebuildColumns(in: tableView)
            tableView.reloadData()
            syncSelection(in: tableView)
            updateSearchSource()
            return
        }
        if let editingRowID,
           rows.first(where: { $0.id == editingRowID })?.isDeleted != false
        {
            finishEditing()
        }
        if previousRows != rows {
            searchSourceRevision = UUID()
            tableView.reloadData()
            updateSearchSource()
        } else if previousEnabled != isEnabled {
            RedisCollectionGridRowView.invalidateVisibleRows(in: tableView)
        }
        if previousSelection != selectedRowIndexes {
            syncSelection(in: tableView)
        }
        if rows.count > previousRows.count,
           let newRow = rows.last,
           newRow.isNew,
           selectedRowIndexes.contains(rows.count - 1)
        {
            beginEditingNewRow(newRow.id)
        }
    }

    func finishEditing() {
        finishInlineEditing(commit: true)
    }

    func dismantleSearch() {
        searchController.clearSource()
        searchController.dismiss()
    }

    private func installHandlers(in tableView: WorkspaceDirectDrawTableView) {
        tableView.canEditCellHandler = { [weak self] row, column in
            self?.canEdit(row: row, tableColumnIndex: column) == true
        }
        tableView.cellEditHandler = { [weak self] row, column in
            self?.beginEditingCell(row: row, tableColumnIndex: column)
        }
        tableView.singleClickCellHandler = nil
        tableView.cellTypingHandler = { [weak self] row, column, text in
            self?.beginTyping(
                row: row,
                tableColumnIndex: column,
                replacement: text
            ) == true
        }
        tableView.auxiliaryCellSingleClickHandler = { [weak self] row, column in
            self?.handleActionClick(row: row, tableColumnIndex: column) == true
        }
        tableView.inlineEditorLayoutHandler = { [weak self] in
            self?.layoutInlineEditor()
        }
        tableView.addDataRowHandler = isEnabled
            ? { [weak self] in self?.performAddRow() }
            : nil
        tableView.deleteDataRowsHandler = { [weak self] rows in
            self?.performDeleteRows(rows)
        }
        tableView.canDeleteDataRowsHandler = { [weak self] rows in
            self?.canDeleteRows(rows) == true
        }
        tableView.selectedDataRowsChanged = { [weak self] rows in
            self?.tableSelectionChanged(rows)
        }
    }

    private func rebuildColumns(in tableView: WorkspaceDirectDrawTableView) {
        tableView.clearGridSelection()
        tableView.tableColumns.forEach(tableView.removeTableColumn)
        columnIndexes.removeAll(keepingCapacity: true)

        let rowNumberColumn = NSTableColumn(
            identifier: Self.rowNumberIdentifier
        )
        rowNumberColumn.title = ""
        WorkspaceGridMetrics.configureHeaderCell(rowNumberColumn.headerCell)
        rowNumberColumn.width = 48
        rowNumberColumn.minWidth = 48
        rowNumberColumn.maxWidth = 48
        rowNumberColumn.resizingMask = []
        tableView.addTableColumn(rowNumberColumn)

        let identifiers = [Self.firstIdentifier, Self.secondIdentifier]
        for (dataIndex, title) in kind.columnTitles.enumerated() {
            let identifier = identifiers[dataIndex]
            columnIndexes[identifier] = dataIndex
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            WorkspaceGridMetrics.configureHeaderCell(column.headerCell)
            column.headerToolTip = title
            column.minWidth = WorkspaceGridColumnSizing.minimumColumnWidth
            column.width = 160
            column.maxWidth = 4_000
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
        }

        let actionColumn = NSTableColumn(identifier: Self.actionIdentifier)
        actionColumn.title = ""
        WorkspaceGridMetrics.configureHeaderCell(actionColumn.headerCell)
        actionColumn.width = 38
        actionColumn.minWidth = 38
        actionColumn.maxWidth = 38
        actionColumn.resizingMask = []
        tableView.addTableColumn(actionColumn)
        applyAutomaticColumnWidths()
        tableView.headerView?.needsLayout = true
    }

    private func applyAutomaticColumnWidths() {
        guard let tableView else { return }
        let columns = kind.columnTitles.enumerated().map {
            WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element)
        }
        let widths = WorkspaceGridColumnSizing.automaticWidths(
            columns: columns,
            rowCount: rows.count,
            maximumConsideredRows: nil,
            rowAt: { [rows, kind] index in
                guard rows.indices.contains(index) else { return nil }
                let row = rows[index]
                return WorkspaceDatabaseDataRow(
                    id: index,
                    values: kind.cells.map { cell in
                        switch cell {
                        case .firstValue:
                            .text(row.firstValue)
                        case .secondValue:
                            .text(row.secondValue)
                        case .thirdValue:
                            .text(row.thirdValue)
                        }
                    }
                )
            },
            cellFont: WorkspaceGridMetrics.cellFont
        )
        isApplyingAutomaticColumnWidths = true
        for tableColumn in tableView.tableColumns {
            guard let dataIndex = columnIndexes[tableColumn.identifier],
                  let width = widths[dataIndex]
            else { continue }
            let preferredWidth = kind.preferredColumnWidths[dataIndex]
            tableColumn.width = max(width, preferredWidth)
        }
        isApplyingAutomaticColumnWidths = false
        RedisCollectionGridRowView.invalidateVisibleRows(in: tableView)
        tableView.headerView?.needsDisplay = true
    }

    private func dataIndex(for tableColumnIndex: Int) -> Int? {
        guard let tableView,
              tableView.tableColumns.indices.contains(tableColumnIndex)
        else { return nil }
        return columnIndexes[
            tableView.tableColumns[tableColumnIndex].identifier
        ]
    }

    private func cell(for dataIndex: Int) -> RedisKeyEditableCell? {
        guard kind.cells.indices.contains(dataIndex) else { return nil }
        return kind.cells[dataIndex]
    }

    private func canEdit(row: Int, tableColumnIndex: Int) -> Bool {
        guard let presentation = rowPresentation(at: row),
              let dataIndex = dataIndex(for: tableColumnIndex)
        else { return false }
        return presentation.isEditable(
            dataIndex: dataIndex,
            isEnabled: isEnabled
        ) && cell(for: dataIndex) != nil
    }

    private func beginEditingCell(row: Int, tableColumnIndex: Int) {
        guard canEdit(row: row, tableColumnIndex: tableColumnIndex),
              let dataIndex = dataIndex(for: tableColumnIndex),
              let cell = cell(for: dataIndex)
        else { return }
        beginTextEditing(
            row: row,
            cell: cell,
            tableColumnIndex: tableColumnIndex
        )
    }

    private func beginTyping(
        row: Int,
        tableColumnIndex: Int,
        replacement: String
    ) -> Bool {
        guard canEdit(row: row, tableColumnIndex: tableColumnIndex),
              let dataIndex = dataIndex(for: tableColumnIndex),
              let cell = cell(for: dataIndex)
        else { return false }
        beginTextEditing(
            row: row,
            cell: cell,
            tableColumnIndex: tableColumnIndex,
            replacement: replacement
        )
        return true
    }

    private func beginTextEditing(
        row: Int,
        cell: RedisKeyEditableCell,
        tableColumnIndex: Int,
        replacement: String? = nil
    ) {
        guard let tableView, rows.indices.contains(row) else { return }
        finishInlineEditing(commit: true)
        let editableRow = rows[row]
        let initialText = value(in: editableRow, cell: cell)
        let editor = RedisCollectionNativeTextField()
        editor.stringValue = replacement ?? initialText
        editor.font = WorkspaceGridMetrics.cellFont
        editor.isEditable = true
        editor.isSelectable = true
        editor.isBordered = false
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.focusRingType = .none
        editor.wantsLayer = true
        editor.layer?.borderColor = NSColor.controlAccentColor.cgColor
        editor.layer?.borderWidth = 2
        editor.lineBreakMode = .byTruncatingTail
        editor.delegate = self
        editor.setAccessibilityIdentifier("redisCollectionCellInlineEditor")
        let dataIndex = dataIndex(for: tableColumnIndex) ?? 0
        let title = kind.columnTitles[dataIndex]
        editor.setAccessibilityLabel(
            AppCopy.current.text("编辑\(title)", "Edit \(title)")
        )

        editingRowID = editableRow.id
        editingCell = cell
        editingTableColumnIndex = tableColumnIndex
        editingInitialText = initialText
        editingText = editor.stringValue
        let coordinate = WorkspaceGridCoordinate(
            row: row,
            column: tableColumnIndex
        )
        tableView.suppressActiveCellIndicator(at: coordinate)
        tableView.addSubview(editor, positioned: .above, relativeTo: nil)
        inlineEditor = editor
        layoutInlineEditor()
        Task { @MainActor [weak self, weak tableView, weak editor] in
            await Task.yield()
            guard let self,
                  let tableView,
                  let editor,
                  self.inlineEditor === editor,
                  editor.superview === tableView
            else { return }
            tableView.addSubview(editor, positioned: .above, relativeTo: nil)
            self.layoutInlineEditor()
            guard tableView.window?.makeFirstResponder(editor) == true else {
                return
            }
            (editor.currentEditor() as? NSTextView)?.configureForCodeInput()
            (editor.currentEditor() as? NSTextView)?.insertionPointColor =
                .controlAccentColor
            editor.currentEditor()?.moveToEndOfDocument(nil)
        }
    }

    private func layoutInlineEditor() {
        guard let tableView,
              let editor = inlineEditor,
              let rowID = editingRowID,
              let row = rows.firstIndex(where: { $0.id == rowID }),
              let column = editingTableColumnIndex
        else { return }
        editor.frame = tableView.frameOfCell(
            atColumn: column,
            row: row
        ).insetBy(dx: 1, dy: 1)
    }

    private func finishInlineEditing(
        commit: Bool,
        movingBy offset: Int? = nil
    ) {
        guard !isEndingEdit,
              let editor = inlineEditor,
              let rowID = editingRowID,
              let cell = editingCell
        else { return }
        isEndingEdit = true
        editingText = editor.currentEditor()?.string ?? editor.stringValue
        let row = rows.firstIndex(where: { $0.id == rowID })
        let currentColumn = editingTableColumnIndex
        editor.delegate = nil
        editor.removeFromSuperview()
        inlineEditor = nil
        tableView?.suppressActiveCellIndicator(at: nil)
        editingRowID = nil
        editingCell = nil
        editingTableColumnIndex = nil
        let text = editingText
        let initialText = editingInitialText
        editingInitialText = ""
        editingText = ""
        tableView?.window?.makeFirstResponder(tableView)
        isEndingEdit = false

        if commit, text != initialText {
            updateValue(rowID, cell, text)
        }
        guard let row,
              let offset,
              let currentColumn,
              let targetColumn = adjacentEditableColumn(
                row: row,
                from: currentColumn,
                offset: offset
              ),
              let tableView
        else { return }
        let coordinate = WorkspaceGridCoordinate(
            row: row,
            column: targetColumn
        )
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollRowToVisible(row)
        tableView.scrollColumnToVisible(targetColumn)
        beginEditingCell(row: row, tableColumnIndex: targetColumn)
    }

    private func adjacentEditableColumn(
        row: Int,
        from current: Int,
        offset: Int
    ) -> Int? {
        guard let tableView else { return nil }
        let editable = tableView.tableColumns.indices.filter {
            canEdit(row: row, tableColumnIndex: $0)
        }
        guard let position = editable.firstIndex(of: current),
              !editable.isEmpty
        else { return nil }
        return editable[(position + offset + editable.count) % editable.count]
    }

    private func moveEditingVertically(by offset: Int) {
        guard let rowID = editingRowID,
              let row = rows.firstIndex(where: { $0.id == rowID }),
              let column = editingTableColumnIndex,
              let tableView
        else { return }
        let targetRow = row + offset
        guard rows.indices.contains(targetRow),
              canEdit(row: targetRow, tableColumnIndex: column)
        else {
            NSSound.beep()
            return
        }
        finishInlineEditing(commit: true)
        let coordinate = WorkspaceGridCoordinate(
            row: targetRow,
            column: column
        )
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollRowToVisible(targetRow)
        tableView.scrollColumnToVisible(column)
        beginEditingCell(row: targetRow, tableColumnIndex: column)
    }

    private func handleActionClick(
        row: Int,
        tableColumnIndex: Int
    ) -> Bool {
        guard let tableView,
              tableView.tableColumns.indices.contains(tableColumnIndex),
              tableView.tableColumns[tableColumnIndex].identifier
                == Self.actionIdentifier
        else { return false }
        guard isEnabled, rows.indices.contains(row) else {
            NSSound.beep()
            return true
        }
        finishInlineEditing(commit: true)
        removeRow(rows[row].id)
        return true
    }

    private func performAddRow() {
        guard isEnabled else { return }
        finishInlineEditing(commit: true)
        addRow()
    }

    private func canDeleteRows(_ indexes: IndexSet) -> Bool {
        isEnabled
            && !indexes.isEmpty
            && indexes.allSatisfy(rows.indices.contains)
    }

    private func performDeleteRows(_ indexes: IndexSet) {
        guard canDeleteRows(indexes) else { return }
        finishInlineEditing(commit: true)
        let ids = indexes.map { rows[$0].id }
        ids.forEach(removeRow)
    }

    private func tableSelectionChanged(_ indexes: IndexSet) {
        guard !isSynchronizingSelection else { return }
        pendingSelectedRowsForActions = indexes
        selectedRowsPublicationTask?.cancel()
        selectedRowsPublicationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.publishSelectedRowsForActions()
        }
    }

    private func publishSelectedRowsForActions() {
        guard let indexes = pendingSelectedRowsForActions else { return }
        pendingSelectedRowsForActions = nil
        selectedRowsPublicationTask = nil
        selectRows(indexes)
    }

    private func syncSelection(in tableView: WorkspaceDirectDrawTableView) {
        if let pendingSelectedRowsForActions {
            guard selectedRowIndexes == pendingSelectedRowsForActions else {
                return
            }
            selectedRowsPublicationTask?.cancel()
            selectedRowsPublicationTask = nil
            self.pendingSelectedRowsForActions = nil
        }
        let validSelection = IndexSet(
            selectedRowIndexes.filter(rows.indices.contains)
        )
        guard validSelection != tableView.selectedDataRowIndexesForActions else {
            return
        }

        isSynchronizingSelection = true
        defer { isSynchronizingSelection = false }
        guard let row = validSelection.last else {
            tableView.clearGridSelection()
            return
        }
        guard validSelection.count == 1 else {
            tableView.clearGridSelection()
            tableView.selectRowIndexes(
                validSelection,
                byExtendingSelection: false
            )
            RedisCollectionGridRowView.invalidateVisibleRows(in: tableView)
            tableView.scrollRowToVisible(row)
            return
        }

        let column = (tableView.gridSelection.active?.column).flatMap {
            dataIndex(for: $0) == nil ? nil : $0
        } ?? tableView.tableColumns.indices.first(where: {
            dataIndex(for: $0) != nil
        })
        guard let column else { return }
        let coordinate = WorkspaceGridCoordinate(row: row, column: column)
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollRowToVisible(row)
        tableView.scrollColumnToVisible(column)
    }

    private func beginEditingNewRow(_ rowID: RedisKeyEditableRow.ID) {
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      let tableView = self.tableView,
                      let row = self.rows.firstIndex(where: { $0.id == rowID }),
                      let column = tableView.tableColumns.indices.first(where: {
                        self.canEdit(row: row, tableColumnIndex: $0)
                      })
                else { return }
                self.beginEditingCell(row: row, tableColumnIndex: column)
            }
        }
    }

    private func value(
        in row: RedisKeyEditableRow,
        cell: RedisKeyEditableCell
    ) -> String {
        switch cell {
        case .firstValue: row.firstValue
        case .secondValue: row.secondValue
        case .thirdValue: row.thirdValue
        }
    }

    private func rowPresentation(
        at row: Int
    ) -> RedisCollectionGridRowPresentation? {
        guard rows.indices.contains(row) else { return nil }
        return RedisCollectionGridRowPresentation(row: rows[row], kind: kind)
    }

    private func updateSearchSource() {
        let columns = kind.columnTitles.enumerated().map {
            WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element)
        }
        let searchRows = rows.enumerated().map { index, row in
            WorkspaceDatabaseDataRow(
                id: index,
                values: kind.cells.map { cell in
                    .text(value(in: row, cell: cell))
                }
            )
        }
        searchController.update(
            source: .redisCollection(
                WorkspaceGridSearchCollectionSource(
                    revision: searchSourceRevision,
                    columns: columns,
                    rows: searchRows
                )
            )
        )
    }

    private func revealSearchMatch(_ match: WorkspaceGridSearchMatch) {
        guard let tableView,
              rows.indices.contains(match.rowIndex),
              let tableColumnIndex = tableView.tableColumns.firstIndex(where: {
                  columnIndexes[$0.identifier] == match.dataColumnIndex
              })
        else { return }
        let coordinate = WorkspaceGridCoordinate(
            row: match.rowIndex,
            column: tableColumnIndex
        )
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollRowToVisible(match.rowIndex)
        tableView.scrollColumnToVisible(tableColumnIndex)
    }
}

extension RedisCollectionGridCoordinator: NSTableViewDataSource, NSTableViewDelegate {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { rows.count }
    }

    nonisolated func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        nil
    }

    nonisolated func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
        MainActor.assumeIsolated {
            guard let tableView = tableView as? WorkspaceDirectDrawTableView,
                  let presentation = rowPresentation(at: row)
            else { return nil }
            let rowView: RedisCollectionGridRowView
            if let reused = tableView.makeView(
                withIdentifier: Self.rowViewIdentifier,
                owner: self
            ) as? RedisCollectionGridRowView {
                rowView = reused
            } else {
                rowView = RedisCollectionGridRowView()
                rowView.identifier = Self.rowViewIdentifier
            }
            rowView.configure(
                tableView: tableView,
                presentation: presentation,
                rowIndex: row,
                columnIndexes: columnIndexes,
                rowNumberIdentifier: Self.rowNumberIdentifier,
                actionIdentifier: Self.actionIdentifier
            )
            return rowView
        }
    }

    nonisolated func tableView(
        _ tableView: NSTableView,
        shouldReorderColumn columnIndex: Int,
        toColumn newColumnIndex: Int
    ) -> Bool {
        MainActor.assumeIsolated {
            guard tableView.tableColumns.indices.contains(columnIndex),
                  newColumnIndex > 0,
                  newColumnIndex < tableView.tableColumns.count - 1
            else { return false }
            let identifier = tableView.tableColumns[columnIndex].identifier
            return identifier != Self.rowNumberIdentifier
                && identifier != Self.actionIdentifier
        }
    }

    nonisolated func tableViewColumnDidResize(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !isApplyingAutomaticColumnWidths, let tableView else { return }
            RedisCollectionGridRowView.invalidateVisibleRows(in: tableView)
        }
    }

    nonisolated func tableViewColumnDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let tableView else { return }
            RedisCollectionGridRowView.invalidateVisibleRows(in: tableView)
        }
    }
}

extension RedisCollectionGridCoordinator: WorkspaceDirectDrawTableViewDataSource {
    func workspaceTableView(
        _ tableView: WorkspaceDirectDrawTableView,
        dataColumnIndexFor identifier: NSUserInterfaceItemIdentifier
    ) -> Int? {
        columnIndexes[identifier]
    }

    func workspaceTableViewCopySnapshot(
        _ tableView: WorkspaceDirectDrawTableView
    ) -> WorkspaceGridCopySnapshot {
        let copyRows = rows.enumerated().map { index, row in
            WorkspaceDatabaseDataRow(
                id: index,
                values: kind.cells.map { cell in
                    .text(value(in: row, cell: cell))
                }
            )
        }
        return WorkspaceGridCopySnapshot { row in
            guard copyRows.indices.contains(row) else { return nil }
            return copyRows[row]
        }
    }
}

extension RedisCollectionGridCoordinator: NSTextFieldDelegate {
    nonisolated func controlTextDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let editor = inlineEditor else { return }
            editingText = editor.currentEditor()?.string ?? editor.stringValue
        }
    }

    nonisolated func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        MainActor.assumeIsolated {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                finishInlineEditing(commit: false)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                editingText = textView.string
                let usesCommand = NSApp.currentEvent?.modifierFlags
                    .contains(.command) == true
                finishInlineEditing(commit: true, movingBy: usesCommand ? nil : 1)
                return true
            case #selector(NSResponder.insertTab(_:)):
                editingText = textView.string
                finishInlineEditing(commit: true, movingBy: 1)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                editingText = textView.string
                finishInlineEditing(commit: true, movingBy: -1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                editingText = textView.string
                moveEditingVertically(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                editingText = textView.string
                moveEditingVertically(by: 1)
                return true
            default:
                return false
            }
        }
    }

    nonisolated func controlTextDidEndEditing(_ notification: Notification) {
        MainActor.assumeIsolated {
            finishInlineEditing(commit: true)
        }
    }
}
