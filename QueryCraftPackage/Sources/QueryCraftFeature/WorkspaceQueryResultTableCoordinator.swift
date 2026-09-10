import AppKit

@MainActor
final class WorkspaceQueryResultTableCoordinator: NSObject {
    private static let rowNumberIdentifier = NSUserInterfaceItemIdentifier(
        "queryResult.rowNumber"
    )
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier(
        "queryResult.row"
    )

    private var page: WorkspaceQueryResultPage
    private var nullDisplayText: String
    private var emptyStringDisplayText: String
    private var copyIncludesColumnNames: Bool
    private var cellFont: NSFont
    private let exportController: WorkspaceDataExportController
    private let searchController: WorkspaceGridSearchController
    private var pendingUpdates: [WorkspaceDatabaseInspectorPendingUpdate]
    private var cellEditRequest: ((WorkspaceDatabaseDataCellEditTarget) ->
        WorkspaceDatabaseDataCellEditRequest?)?
    private var prepareCellEdit: ((WorkspaceDatabaseDataCellEditTarget) ->
        WorkspaceDatabaseDataCellInlineEditContext?)?
    private var updateCellEdit: (
        WorkspaceDatabaseDataCellInlineEditContext,
        WorkspaceDatabaseInspectorMutation
    ) -> Void
    private var discardPendingUpdates: (
        [WorkspaceDatabaseInspectorPendingUpdate]
    ) -> Void
    private let inlineEditor = WorkspaceDataCellInlineEditor()
    private var updateInspectorContext:
        @MainActor (WorkspaceQueryResultInspectorContext) -> Void
    private var columnIndexes: [NSUserInterfaceItemIdentifier: Int] = [:]
    private weak var tableView: NSTableView?
    private var isApplyingAutomaticColumnWidths = false
    private var rowLoadTasks: [Int: Task<Void, Never>] = [:]
    private var inspectorPublicationTask: Task<Void, Never>?

    init(
        page: WorkspaceQueryResultPage,
        nullDisplayText: String = "NULL",
        emptyStringDisplayText: String = "",
        copyIncludesColumnNames: Bool = false,
        cellFont: NSFont = WorkspaceGridMetrics.cellFont,
        exportController: WorkspaceDataExportController =
            WorkspaceDataExportController(),
        searchController: WorkspaceGridSearchController =
            WorkspaceGridSearchController(),
        pendingUpdates: [WorkspaceDatabaseInspectorPendingUpdate] = [],
        cellEditRequest: ((WorkspaceDatabaseDataCellEditTarget) ->
            WorkspaceDatabaseDataCellEditRequest?)? = nil,
        prepareCellEdit: ((WorkspaceDatabaseDataCellEditTarget) ->
            WorkspaceDatabaseDataCellInlineEditContext?)? = nil,
        updateCellEdit: @escaping (
            WorkspaceDatabaseDataCellInlineEditContext,
            WorkspaceDatabaseInspectorMutation
        ) -> Void = { _, _ in },
        discardPendingUpdates: @escaping (
            [WorkspaceDatabaseInspectorPendingUpdate]
        ) -> Void = { _ in },
        updateInspectorContext:
            @escaping @MainActor (WorkspaceQueryResultInspectorContext) -> Void =
            { _ in }
    ) {
        self.page = page
        self.nullDisplayText = nullDisplayText
        self.emptyStringDisplayText = emptyStringDisplayText
        self.copyIncludesColumnNames = copyIncludesColumnNames
        self.cellFont = cellFont
        self.exportController = exportController
        self.searchController = searchController
        self.pendingUpdates = pendingUpdates
        self.cellEditRequest = cellEditRequest
        self.prepareCellEdit = prepareCellEdit
        self.updateCellEdit = updateCellEdit
        self.discardPendingUpdates = discardPendingUpdates
        self.updateInspectorContext = updateInspectorContext
    }

    deinit {
        for task in rowLoadTasks.values {
            task.cancel()
        }
        inspectorPublicationTask?.cancel()
    }

    func makeScrollView() -> NSScrollView {
        let tableView = WorkspaceDirectDrawTableView()
        tableView.dataSource = self
        tableView.delegate = self
        let headerView = WorkspaceGridHeaderView()
        headerView.resetColumnWidths = { [weak self] in
            self?.resetColumnWidths()
        }
        headerView.frame.size.height = WorkspaceGridMetrics.headerHeight
        tableView.headerView = headerView
        tableView.rowHeight = Self.rowHeight(for: cellFont)
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.style = .fullWidth
        tableView.workspaceDataSource = self
        tableView.rowNumberIdentifier = Self.rowNumberIdentifier
        tableView.nullDisplayText = nullDisplayText
        tableView.emptyStringDisplayText = emptyStringDisplayText
        tableView.copyIncludesColumnNames = copyIncludesColumnNames
        tableView.gridSearchController = searchController
        updateCellActionHandlers(in: tableView)
        tableView.selectedDataRowsChanged = { [weak self] _ in
            self?.publishInspectorSelection()
        }
        exportController.attach(
            tableView: tableView,
            sourceKind: .queryResult,
            suggestedFileName: "query-result"
        )
        tableView.setAccessibilityIdentifier("queryResult")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.setAccessibilityIdentifier("queryResult")

        self.tableView = tableView
        rebuildColumns(in: tableView)
        searchController.update(source: .queryResult(page))
        searchController.attachSelectionHandler { [weak self] match in
            self?.revealSearchMatch(match)
        }
        return scrollView
    }

    func update(
        page: WorkspaceQueryResultPage,
        nullDisplayText: String = "NULL",
        emptyStringDisplayText: String = "",
        copyIncludesColumnNames: Bool = false,
        cellFont: NSFont = WorkspaceGridMetrics.cellFont,
        pendingUpdates: [WorkspaceDatabaseInspectorPendingUpdate] = [],
        cellEditRequest: ((WorkspaceDatabaseDataCellEditTarget) ->
            WorkspaceDatabaseDataCellEditRequest?)? = nil,
        prepareCellEdit: ((WorkspaceDatabaseDataCellEditTarget) ->
            WorkspaceDatabaseDataCellInlineEditContext?)? = nil,
        updateCellEdit: @escaping (
            WorkspaceDatabaseDataCellInlineEditContext,
            WorkspaceDatabaseInspectorMutation
        ) -> Void = { _, _ in },
        discardPendingUpdates: @escaping (
            [WorkspaceDatabaseInspectorPendingUpdate]
        ) -> Void = { _ in },
        updateInspectorContext:
            (@MainActor (WorkspaceQueryResultInspectorContext) -> Void)? = nil
    ) {
        let previousPendingUpdates = self.pendingUpdates
        self.pendingUpdates = pendingUpdates
        self.cellEditRequest = cellEditRequest
        self.prepareCellEdit = prepareCellEdit
        self.updateCellEdit = updateCellEdit
        self.discardPendingUpdates = discardPendingUpdates
        let fontChanged = cellFont.fontName != self.cellFont.fontName
            || cellFont.pointSize != self.cellFont.pointSize
        let displayTextChanged =
            nullDisplayText != self.nullDisplayText
            || emptyStringDisplayText != self.emptyStringDisplayText
        self.nullDisplayText = nullDisplayText
        self.emptyStringDisplayText = emptyStringDisplayText
        self.copyIncludesColumnNames = copyIncludesColumnNames
        self.cellFont = cellFont
        if let updateInspectorContext {
            self.updateInspectorContext = updateInspectorContext
        }
        if let tableView {
            if let directDrawTableView =
                tableView as? WorkspaceDirectDrawTableView {
                directDrawTableView.nullDisplayText = nullDisplayText
                directDrawTableView.emptyStringDisplayText =
                    emptyStringDisplayText
                directDrawTableView.copyIncludesColumnNames =
                    copyIncludesColumnNames
                updateCellActionHandlers(in: directDrawTableView)
            }
            if fontChanged {
                tableView.rowHeight = Self.rowHeight(for: cellFont)
                applyAutomaticColumnWidths(in: tableView)
                tableView.reloadData()
            } else if displayTextChanged {
                applyAutomaticColumnWidths(in: tableView)
                tableView.reloadData()
            }
            if previousPendingUpdates != pendingUpdates {
                refreshPendingPresentation(
                    in: tableView,
                    previousUpdates: previousPendingUpdates
                )
                publishInspectorSelection()
            }
        }
        guard page.revision != self.page.revision else { return }
        let columnsChanged = page.columns != self.page.columns
        let startsNewResult = page.store.id != self.page.store.id
        let appendsCurrentResult = !columnsChanged
            && !startsNewResult
            && page.rowCount >= self.page.rowCount
        self.page = page
        searchController.update(source: .queryResult(page))
        if startsNewResult {
            for task in rowLoadTasks.values {
                task.cancel()
            }
            rowLoadTasks.removeAll()
        }

        guard let tableView else { return }
        if columnsChanged {
            rebuildColumns(in: tableView)
        } else if startsNewResult {
            applyAutomaticColumnWidths(in: tableView)
        }
        if appendsCurrentResult {
            tableView.noteNumberOfRowsChanged()
        } else {
            (tableView as? WorkspaceDirectDrawTableView)?
                .clearGridSelection()
            tableView.reloadData()
            if page.rowCount > 0 {
                tableView.scrollRowToVisible(0)
            }
        }
        publishInspectorSelection()
    }

    private func rebuildColumns(in tableView: NSTableView) {
        (tableView as? WorkspaceDirectDrawTableView)?.clearGridSelection()
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

        for column in page.columns {
            let identifier = NSUserInterfaceItemIdentifier(
                "queryResult.column.\(column.id)"
            )
            columnIndexes[identifier] = column.id
            let tableColumn = NSTableColumn(identifier: identifier)
            tableColumn.title = column.name
            WorkspaceGridMetrics.configureHeaderCell(tableColumn.headerCell)
            tableColumn.width = 160
            tableColumn.minWidth =
                WorkspaceGridColumnSizing.minimumColumnWidth
            tableColumn.resizingMask = .userResizingMask
            tableView.addTableColumn(tableColumn)
        }
        applyAutomaticColumnWidths(in: tableView)
        tableView.headerView?.needsLayout = true
    }

    func resetColumnWidths() {
        guard let tableView else { return }
        applyAutomaticColumnWidths(in: tableView)
    }

    private func applyAutomaticColumnWidths(in tableView: NSTableView) {
        let widths = WorkspaceGridColumnSizing.automaticWidths(
            columns: page.columns,
            rowCount: page.rowCount,
            maximumConsideredRows: 256,
            rowAt: page.cachedRow(at:),
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText,
            cellFont: cellFont
        )
        isApplyingAutomaticColumnWidths = true
        for tableColumn in tableView.tableColumns {
            guard
                let columnIndex = columnIndexes[tableColumn.identifier],
                let width = widths[columnIndex]
            else {
                continue
            }
            tableColumn.width = max(160, width)
        }
        isApplyingAutomaticColumnWidths = false
        WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: tableView)
        tableView.headerView?.needsDisplay = true
    }

    private func revealSearchMatch(_ match: WorkspaceGridSearchMatch) {
        guard
            let tableView = tableView as? WorkspaceDirectDrawTableView,
            match.rowIndex >= 0,
            match.rowIndex < page.rowCount,
            let tableColumnIndex = tableView.tableColumns.firstIndex(where: {
                columnIndexes[$0.identifier] == match.dataColumnIndex
            })
        else {
            return
        }
        let coordinate = WorkspaceGridCoordinate(
            row: match.rowIndex,
            column: tableColumnIndex
        )
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollRowToVisible(match.rowIndex)
        tableView.scrollColumnToVisible(tableColumnIndex)
    }

    private func publishInspectorSelection() {
        guard let tableView = tableView as? WorkspaceDirectDrawTableView else {
            scheduleInspectorPublication(
                WorkspaceQueryResultInspectorContext(page: page)
            )
            return
        }
        let selectedRows = tableView.selectedDataRowIndexesForActions
        guard selectedRows.count == 1, let rowIndex = selectedRows.first else {
            scheduleInspectorPublication(
                WorkspaceQueryResultInspectorContext(page: page)
            )
            return
        }
        guard let row = page.cachedRow(at: rowIndex) else {
            scheduleInspectorPublication(
                WorkspaceQueryResultInspectorContext(
                    page: page,
                    selectedRowIndex: rowIndex,
                    isLoading: true
                )
            )
            scheduleRowLoad(containing: rowIndex)
            return
        }
        scheduleInspectorPublication(
            WorkspaceQueryResultInspectorContext(
                page: page,
                selectedRowIndex: rowIndex,
                row: row
            )
        )
    }

    private func scheduleInspectorPublication(
        _ context: WorkspaceQueryResultInspectorContext
    ) {
        inspectorPublicationTask?.cancel()
        let resultID = page.store.id
        inspectorPublicationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled,
                let self,
                self.page.store.id == resultID
            else {
                return
            }
            self.updateInspectorContext(context)
            self.inspectorPublicationTask = nil
        }
    }
}

extension WorkspaceQueryResultTableCoordinator: NSTableViewDataSource {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { page.rowCount }
    }
}

extension WorkspaceQueryResultTableCoordinator: NSTableViewDelegate {
    nonisolated func tableView(
        _ tableView: NSTableView,
        shouldReorderColumn columnIndex: Int,
        toColumn newColumnIndex: Int
    ) -> Bool {
        MainActor.assumeIsolated {
            guard tableView.tableColumns.indices.contains(columnIndex) else {
                return false
            }
            return WorkspaceGridColumnReordering.allows(
                columnIdentifier:
                    tableView.tableColumns[columnIndex].identifier.rawValue,
                rowNumberIdentifier: Self.rowNumberIdentifier.rawValue,
                proposedIndex: newColumnIndex
            )
        }
    }

    nonisolated func tableViewColumnDidResize(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !isApplyingAutomaticColumnWidths else { return }
            guard let tableView else { return }
            WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: tableView)
        }
    }

    nonisolated func tableViewColumnDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let tableView else { return }
            if let directDrawTableView =
                tableView as? WorkspaceDirectDrawTableView {
                directDrawTableView.clearGridSelection()
                directDrawTableView.animateColumnsAfterReordering()
            }
            WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: tableView)
        }
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
            guard let dataRow = page.cachedRow(at: row) else {
                scheduleRowLoad(containing: row)
                return nil
            }
            let rowView: WorkspaceDatabaseDataRowView
            if let reused = tableView.makeView(
                withIdentifier: Self.rowViewIdentifier,
                owner: self
            ) as? WorkspaceDatabaseDataRowView {
                rowView = reused
            } else {
                rowView = WorkspaceDatabaseDataRowView()
                rowView.identifier = Self.rowViewIdentifier
            }
            rowView.configure(
                tableView: tableView,
                dataRow: effectiveRow(dataRow),
                rowIndex: row,
                columnIndexes: columnIndexes,
                rowNumberIdentifier: Self.rowNumberIdentifier,
                nullDisplayText: nullDisplayText,
                emptyStringDisplayText: emptyStringDisplayText,
                cellFont: cellFont,
                accessibilityPrefix: "queryResult",
                pendingUpdateColumnIndexes: pendingUpdateColumnIndexes(
                    for: dataRow
                )
            )
            return rowView
        }
    }
}

private extension WorkspaceQueryResultTableCoordinator {
    func updateCellActionHandlers(in tableView: WorkspaceDirectDrawTableView) {
        updateCellEditHandler(in: tableView)
        tableView.cellValueMutationMenuItemsProvider = { [weak self] row, column in
            self?.loadedValueMutationMenuItems(
                row: row,
                tableColumnIndex: column
            ) ?? []
        }
        tableView.additionalCellContextMenuItemsProvider = {
            [weak self] row, column in
            self?.additionalContextMenuItems(
                row: row,
                tableColumnIndex: column
            ) ?? []
        }
    }

    func updateCellEditHandler(in tableView: WorkspaceDirectDrawTableView) {
        guard prepareCellEdit != nil else {
            tableView.cellEditHandler = nil
            tableView.canEditCellHandler = nil
            tableView.cellTypingHandler = nil
            tableView.inlineEditorLayoutHandler = nil
            return
        }
        tableView.cellEditHandler = { [weak self] row, tableColumnIndex in
            self?.beginEditingCell(row: row, tableColumnIndex: tableColumnIndex)
        }
        tableView.canEditCellHandler = { [weak self] row, column in
            self?.canEditCell(row: row, tableColumnIndex: column) == true
        }
        tableView.cellTypingHandler = { [weak self] row, column, text in
            guard let self,
                  self.canEditCell(row: row, tableColumnIndex: column) else {
                return false
            }
            self.beginEditingCell(
                row: row,
                tableColumnIndex: column,
                replacingWith: text
            )
            return true
        }
        tableView.inlineEditorLayoutHandler = { [weak self] in
            self?.inlineEditor.layout()
        }
    }

    func canEditCell(row: Int, tableColumnIndex: Int) -> Bool {
        guard let target = loadedCellEditTarget(
            row: row,
            tableColumnIndex: tableColumnIndex
        ), target.column?.origin != nil else { return false }
        return cellEditRequest?(target) != nil
            || cellEditRequest == nil
    }

    func beginEditingCell(
        row: Int,
        tableColumnIndex: Int,
        replacingWith replacement: String? = nil
    ) {
        guard canEditCell(row: row, tableColumnIndex: tableColumnIndex),
              let tableView = tableView as? WorkspaceDirectDrawTableView,
              let target = loadedCellEditTarget(
                  row: row,
                  tableColumnIndex: tableColumnIndex
              ),
              let context = prepareCellEdit?(target) else { return }
        inlineEditor.begin(
            in: tableView,
            context: context,
            tableColumnIndex: tableColumnIndex,
            cellFont: cellFont,
            replacingWith: replacement,
            update: updateCellEdit,
            canEdit: { [weak self] row, column in
                self?.canEditCell(row: row, tableColumnIndex: column) == true
            },
            beginEdit: { [weak self] row, column in
                self?.beginEditingCell(row: row, tableColumnIndex: column)
            },
            redraw: { [weak self] row in
                guard let self,
                      let tableView = self.tableView
                        as? WorkspaceDirectDrawTableView else { return }
                self.reconfigureLoadedRow(at: row, in: tableView)
            }
        )
    }

    func loadedCellEditTarget(
        row: Int,
        tableColumnIndex: Int
    ) -> WorkspaceDatabaseDataCellEditTarget? {
        guard row >= 0, row < page.rowCount,
              let tableView,
              tableView.tableColumns.indices.contains(tableColumnIndex),
              let dataColumnIndex = columnIndexes[
                  tableView.tableColumns[tableColumnIndex].identifier
              ],
              let dataRow = page.cachedRow(at: row)
        else { return nil }
        return WorkspaceDatabaseDataCellEditTarget(
            rowIndex: row,
            dataColumnIndex: dataColumnIndex,
            columns: page.columns,
            row: dataRow
        )
    }

    func loadedValueMutationMenuItems(
        row: Int,
        tableColumnIndex: Int
    ) -> [NSMenuItem] {
        guard cellEditRequest != nil else { return [] }
        let target = NSValue(point: NSPoint(x: tableColumnIndex, y: row))
        let mutations: [(
            title: String,
            action: Selector,
            mutation: WorkspaceDatabaseInspectorMutation
        )] = [
            (
                AppCopy.current.text("设为 NULL", "Set to NULL"),
                #selector(setNullForLoadedCells(_:)),
                .null
            ),
            (
                AppCopy.current.text("使用默认值", "Use Default"),
                #selector(useDefaultForLoadedCells(_:)),
                .useDefault
            ),
            (
                AppCopy.current.text("设为空字符串", "Set to Empty String"),
                #selector(setEmptyForLoadedCells(_:)),
                .value("")
            ),
        ]
        return mutations.compactMap { item in
            let isEnabled = canApplyLoadedMutation(
                item.mutation,
                clickedRow: row,
                clickedTableColumnIndex: tableColumnIndex
            )
            if item.mutation == .useDefault, !isEnabled {
                return nil
            }
            let menuItem = NSMenuItem(
                title: item.title,
                action: item.action,
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = target
            menuItem.isEnabled = isEnabled
            return menuItem
        }
    }

    @objc func setNullForLoadedCells(_ sender: NSMenuItem) {
        applyLoadedMutation(.null, from: sender)
    }

    @objc func useDefaultForLoadedCells(_ sender: NSMenuItem) {
        applyLoadedMutation(.useDefault, from: sender)
    }

    @objc func setEmptyForLoadedCells(_ sender: NSMenuItem) {
        applyLoadedMutation(.value(""), from: sender)
    }

    func applyLoadedMutation(
        _ mutation: WorkspaceDatabaseInspectorMutation,
        from sender: NSMenuItem
    ) {
        guard let point = (sender.representedObject as? NSValue)?.pointValue else {
            return
        }
        for coordinate in selectedLoadedCoordinates(
            clickedRow: Int(point.y),
            clickedTableColumnIndex: Int(point.x)
        ) {
            guard
                let target = loadedCellEditTarget(
                    row: coordinate.row,
                    tableColumnIndex: coordinate.column
                ),
                target.column?.origin != nil,
                cellEditRequest?(target) != nil,
                let context = prepareCellEdit?(target)
            else {
                continue
            }
            updateCellEdit(context, mutation)
        }
    }

    func canApplyLoadedMutation(
        _ mutation: WorkspaceDatabaseInspectorMutation,
        clickedRow: Int,
        clickedTableColumnIndex: Int
    ) -> Bool {
        let coordinates = selectedLoadedCoordinates(
            clickedRow: clickedRow,
            clickedTableColumnIndex: clickedTableColumnIndex
        )
        guard !coordinates.isEmpty else { return false }
        return coordinates.allSatisfy { coordinate in
            guard
                let target = loadedCellEditTarget(
                    row: coordinate.row,
                    tableColumnIndex: coordinate.column
                ),
                target.column?.origin != nil,
                let request = cellEditRequest?(target)
            else {
                return false
            }
            return switch mutation {
            case .null:
                request.column.isNullable
            case .useDefault:
                request.column.defaultValue != nil
                    || request.column.extra.localizedCaseInsensitiveContains(
                        "default_generated"
                    )
            case .value:
                true
            }
        }
    }

    func selectedLoadedCoordinates(
        clickedRow: Int,
        clickedTableColumnIndex: Int
    ) -> [WorkspaceGridCoordinate] {
        guard
            let tableView = tableView as? WorkspaceDirectDrawTableView,
            tableView.gridSelection.contains(
                row: clickedRow,
                column: clickedTableColumnIndex
            ),
            let rows = tableView.gridSelection.rows,
            let columns = tableView.gridSelection.columns
        else {
            return [WorkspaceGridCoordinate(
                row: clickedRow,
                column: clickedTableColumnIndex
            )]
        }
        return rows.flatMap { row in
            columns.compactMap { column in
                guard loadedCellEditTarget(
                    row: row,
                    tableColumnIndex: column
                ) != nil else {
                    return nil
                }
                return WorkspaceGridCoordinate(row: row, column: column)
            }
        }
    }

    func additionalContextMenuItems(
        row: Int,
        tableColumnIndex: Int
    ) -> [NSMenuItem] {
        guard page.cachedRow(at: row) != nil else { return [] }
        let copyRowItem = NSMenuItem(
            title: AppCopy.current.text("复制行", "Copy Row"),
            action: #selector(copyRowFromMenu(_:)),
            keyEquivalent: "c"
        )
        copyRowItem.keyEquivalentModifierMask = .command
        copyRowItem.target = self
        copyRowItem.representedObject = row

        let pendingItems = pendingChangeMenuItems(
            row: row,
            tableColumnIndex: tableColumnIndex
        )
        guard !pendingItems.isEmpty else { return [copyRowItem] }
        return [copyRowItem, .separator()] + pendingItems
    }

    func pendingChangeMenuItems(
        row: Int,
        tableColumnIndex: Int
    ) -> [NSMenuItem] {
        guard let dataRow = page.cachedRow(at: row) else { return [] }
        let rowUpdates = pendingUpdates.filter {
            $0.applies(to: dataRow, columns: page.columns)
        }
        guard !rowUpdates.isEmpty else { return [] }

        var items: [NSMenuItem] = []
        var includesCellUndo = false
        if let tableView,
           tableView.tableColumns.indices.contains(tableColumnIndex),
           let dataColumnIndex = columnIndexes[
               tableView.tableColumns[tableColumnIndex].identifier
           ],
           let cellUpdate = rowUpdates.last(where: {
               $0.applies(
                   to: dataRow,
                   columns: page.columns,
                   dataColumnIndex: dataColumnIndex
               )
           })
        {
            let item = NSMenuItem(
                title: AppCopy.current.text(
                    "撤销单元格修改",
                    "Undo Cell Change"
                ),
                action: #selector(undoCellChangeFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = cellUpdate
            items.append(item)
            includesCellUndo = true
        }
        if rowUpdates.count > 1 || !includesCellUndo {
            let item = NSMenuItem(
                title: rowUpdates.count == 1
                    ? AppCopy.current.text(
                        "撤销此行修改",
                        "Undo Row Change"
                    )
                    : AppCopy.current.text(
                        "撤销此行全部修改",
                        "Undo All Changes in Row"
                    ),
                action: #selector(undoRowChangesFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = rowUpdates
            items.append(item)
        }
        return items
    }

    @objc func copyRowFromMenu(_ sender: NSMenuItem) {
        guard
            let row = sender.representedObject as? Int,
            let tableView = tableView as? WorkspaceDirectDrawTableView
        else { return }
        tableView.copyRow(at: row)
    }

    @objc func undoCellChangeFromMenu(_ sender: NSMenuItem) {
        guard let update = sender.representedObject
            as? WorkspaceDatabaseInspectorPendingUpdate else { return }
        discardPendingUpdates([update])
    }

    @objc func undoRowChangesFromMenu(_ sender: NSMenuItem) {
        guard let updates = sender.representedObject
            as? [WorkspaceDatabaseInspectorPendingUpdate] else { return }
        discardPendingUpdates(updates)
    }

    func effectiveRow(
        _ row: WorkspaceDatabaseDataRow
    ) -> WorkspaceDatabaseDataRow {
        WorkspaceLoadedDataPendingPresentation.effectiveRow(
            row,
            columns: page.columns,
            updates: pendingUpdates
        )
    }

    func refreshPendingPresentation(
        in tableView: NSTableView,
        previousUpdates: [WorkspaceDatabaseInspectorPendingUpdate]
    ) {
        let changedRows = WorkspaceLoadedDataPendingPresentation
            .changedVisibleRowIndexes(
                in: tableView,
                columns: page.columns,
                previousUpdates: previousUpdates,
                updates: pendingUpdates,
                rowAt: page.cachedRow(at:)
            )
        guard let directTableView = tableView as? WorkspaceDirectDrawTableView
        else { return }
        for rowIndex in changedRows {
            reconfigureLoadedRow(at: rowIndex, in: directTableView)
        }
    }

    func reconfigureLoadedRow(
        at rowIndex: Int,
        in tableView: WorkspaceDirectDrawTableView
    ) {
        guard
            let row = page.cachedRow(at: rowIndex),
            let rowView = tableView.rowView(
                atRow: rowIndex,
                makeIfNecessary: false
            ) as? WorkspaceDatabaseDataRowView
        else { return }
        rowView.configure(
            tableView: tableView,
            dataRow: effectiveRow(row),
            rowIndex: rowIndex,
            columnIndexes: columnIndexes,
            rowNumberIdentifier: Self.rowNumberIdentifier,
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText,
            cellFont: cellFont,
            accessibilityPrefix: "queryResult",
            pendingUpdateColumnIndexes: pendingUpdateColumnIndexes(for: row)
        )
    }

    func pendingUpdateColumnIndexes(
        for row: WorkspaceDatabaseDataRow
    ) -> Set<Int> {
        WorkspaceLoadedDataPendingPresentation.pendingUpdateColumnIndexes(
            for: row,
            columns: page.columns,
            updates: pendingUpdates
        )
    }

    func scheduleRowLoad(containing row: Int) {
        guard let pageIdentifier = page.store.cachePageIdentifier(
            containing: row
        ), rowLoadTasks[pageIdentifier] == nil else {
            return
        }
        let store = page.store
        let task = Task { @MainActor [weak self, weak tableView] in
            defer {
                self?.rowLoadTasks[pageIdentifier] = nil
            }
            do {
                guard let range = try await store.loadPage(containing: row),
                      !Task.isCancelled,
                      let self,
                      self.page.store === store,
                      let tableView
                else {
                    return
                }
                let lowerBound = max(0, range.lowerBound)
                let upperBound = min(self.page.rowCount, range.upperBound)
                guard lowerBound < upperBound else { return }
                let visibleRows = lowerBound..<upperBound
                tableView.reloadData(
                    forRowIndexes: IndexSet(integersIn: visibleRows),
                    columnIndexes: IndexSet(
                        integersIn: 0..<tableView.numberOfColumns
                    )
                )
                self.publishInspectorSelection()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        rowLoadTasks[pageIdentifier] = task
    }

    static func rowHeight(for font: NSFont) -> CGFloat {
        max(24, ceil(font.ascender - font.descender + font.leading) + 6)
    }
}

extension WorkspaceQueryResultTableCoordinator:
    WorkspaceDirectDrawTableViewDataSource
{
    func workspaceTableView(
        _ tableView: WorkspaceDirectDrawTableView,
        dataColumnIndexFor identifier: NSUserInterfaceItemIdentifier
    ) -> Int? {
        columnIndexes[identifier]
    }

    func workspaceTableViewCopySnapshot(
        _ tableView: WorkspaceDirectDrawTableView
    ) -> WorkspaceGridCopySnapshot {
        let page = page
        return WorkspaceGridCopySnapshot(
            rowAt: { page.row(at: $0) },
            requiresBackgroundEncoding: true
        )
    }

    func workspaceTableView(
        _ tableView: WorkspaceDirectDrawTableView,
        dataExportSourceFor rows: WorkspaceGridCopyRows
    ) -> (any WorkspaceDataExportRowSource)? {
        page.store.makeDataExportRowSource(rows: rows)
    }
}
