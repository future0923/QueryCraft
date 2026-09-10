import AppKit

@MainActor
final class WorkspaceDatabaseDataTableCoordinator: NSObject {
    private static let rowNumberIdentifier = NSUserInterfaceItemIdentifier(
        "databaseData.rowNumber"
    )
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier(
        "databaseData.row"
    )

    private var page: WorkspaceDatabaseDataPage
    private var columnIndexes: [NSUserInterfaceItemIdentifier: Int] = [:]
    private var displayedSort: WorkspaceDatabaseDataSort
    private var isFetching: Bool
    private var usesAlternatingRows: Bool
    private var nullDisplayText: String
    private var emptyStringDisplayText: String
    private var copyIncludesColumnNames: Bool
    private var cellFont: NSFont
    private let exportController: WorkspaceDataExportController
    private let searchController: WorkspaceGridSearchController
    private var exportAllRowsProvider: WorkspaceDataExportAllRowsProvider?
    private var exportFileName: String
    private var sortData: (WorkspaceDatabaseDataSort) -> Void
    private var prepareCellEdit: ((WorkspaceDatabaseDataCellEditTarget) ->
        WorkspaceDatabaseDataCellInlineEditContext?)?
    private var prepareCellEditAsync: ((WorkspaceDatabaseDataCellEditTarget) async ->
        WorkspaceDatabaseDataCellInlineEditContext?)?
    private var updateCellEdit: (
        WorkspaceDatabaseDataCellInlineEditContext,
        WorkspaceDatabaseInspectorMutation
    ) -> Void
    private var databaseColumns: [WorkspaceDatabaseColumn]
    private var pendingLoadedUpdates: [WorkspaceDatabaseInspectorPendingUpdate]
    var mappingActions: WorkspaceMappingGridActions?
    private var mappingOptionPresenter: WorkspaceMappingGridOptionPresenter?
    private var hasSizedLoadedMappingRows = false
    private var rowInsertEditor: WorkspaceDatabaseDataRowInsertEditorState
    private var updateRowInsertDraft: (
        UUID,
        String,
        WorkspaceDatabaseDataRowInsertDraft
    ) -> Void
    private var submitRowInsert: () -> Void
    private var cancelRowInsert: () -> Void
    private var pendingDeleteRowIndexes: IndexSet
    private var requestedSelectedRowIndexes: IndexSet
    private var rowActionKind: WorkspaceDatabaseDataRowActionKind
    private var addRow: (() -> Void)?
    private var duplicateRow: ((Int) -> Void)?
    private var deleteRows: ((IndexSet) -> Void)?
    private var pasteRows: ((
        WorkspaceGridPasteboardContent,
        [String],
        UUID?
    ) -> Void)?
    private var selectRowsForActions: (IndexSet) -> Void
    private weak var tableView: NSTableView?
    private var isApplyingAutomaticColumnWidths = false
    private let loadedCellInlineEditor = WorkspaceDataCellInlineEditor()
    private weak var inlineEditor: NSTextField?
    private var inlineEditingLoadedContext:
        WorkspaceDatabaseDataCellInlineEditContext?
    private var inlineEditingDraftRowID: UUID?
    private var inlineEditingColumnName: String?
    private var inlineEditingTableColumnIndex: Int?
    private var inlineEditingText = ""
    private var inlineEditingInitialText = ""
    private var isEndingInlineEdit = false
    private var inlineEditorKeyMonitor: Any?
    private var isSynchronizingSelection = false
    private var selectedRowsPublicationTask: Task<Void, Never>?
    private var pendingSelectedRowsForActions: IndexSet?
    private var visuallyClearedActionRowIndexes: IndexSet?
    private var lastActiveDataColumnIdentifier: NSUserInterfaceItemIdentifier?
    private var cellEditPreparationTask: Task<Void, Never>?
    private var cellEditPreparationID: UUID?

    isolated deinit {
        mappingOptionPresenter?.close()
        if let inlineEditorKeyMonitor {
            NSEvent.removeMonitor(inlineEditorKeyMonitor)
        }
        selectedRowsPublicationTask?.cancel()
        cellEditPreparationTask?.cancel()
    }

    init(
        page: WorkspaceDatabaseDataPage,
        isFetching: Bool,
        usesAlternatingRows: Bool = true,
        nullDisplayText: String = "NULL",
        emptyStringDisplayText: String = "",
        copyIncludesColumnNames: Bool = false,
        cellFont: NSFont = WorkspaceGridMetrics.cellFont,
        exportController: WorkspaceDataExportController =
            WorkspaceDataExportController(),
        searchController: WorkspaceGridSearchController =
            WorkspaceGridSearchController(),
        exportAllRowsProvider: WorkspaceDataExportAllRowsProvider? = nil,
        exportFileName: String = "table-data",
        sortData: @escaping (WorkspaceDatabaseDataSort) -> Void,
        prepareCellEdit: ((WorkspaceDatabaseDataCellEditTarget) ->
            WorkspaceDatabaseDataCellInlineEditContext?)? = nil,
        prepareCellEditAsync: ((WorkspaceDatabaseDataCellEditTarget) async ->
            WorkspaceDatabaseDataCellInlineEditContext?)? = nil,
        updateCellEdit: @escaping (
            WorkspaceDatabaseDataCellInlineEditContext,
            WorkspaceDatabaseInspectorMutation
        ) -> Void = { _, _ in },
        databaseColumns: [WorkspaceDatabaseColumn] = [],
        pendingLoadedUpdates: [WorkspaceDatabaseInspectorPendingUpdate] = [],
        rowInsertEditor: WorkspaceDatabaseDataRowInsertEditorState = .init(),
        updateRowInsertDraft: @escaping (
            UUID,
            String,
            WorkspaceDatabaseDataRowInsertDraft
        ) -> Void = { _, _, _ in },
        submitRowInsert: @escaping () -> Void = {},
        cancelRowInsert: @escaping () -> Void = {},
        pendingDeleteRowIndexes: IndexSet = [],
        selectedRowIndexes: IndexSet = [],
        rowActionKind: WorkspaceDatabaseDataRowActionKind = .tableRow,
        addRow: (() -> Void)? = nil,
        duplicateRow: ((Int) -> Void)? = nil,
        deleteRows: ((IndexSet) -> Void)? = nil,
        pasteRows: ((
            WorkspaceGridPasteboardContent,
            [String],
            UUID?
        ) -> Void)? = nil,
        selectRowsForActions: @escaping (IndexSet) -> Void = { _ in }
    ) {
        self.page = page
        displayedSort = page.sort
        self.isFetching = isFetching
        self.usesAlternatingRows = usesAlternatingRows
        self.nullDisplayText = nullDisplayText
        self.emptyStringDisplayText = emptyStringDisplayText
        self.copyIncludesColumnNames = copyIncludesColumnNames
        self.cellFont = cellFont
        self.exportController = exportController
        self.searchController = searchController
        self.exportAllRowsProvider = exportAllRowsProvider
        self.exportFileName = exportFileName
        self.sortData = sortData
        self.prepareCellEdit = prepareCellEdit
        self.prepareCellEditAsync = prepareCellEditAsync
        self.updateCellEdit = updateCellEdit
        self.databaseColumns = databaseColumns
        self.pendingLoadedUpdates = pendingLoadedUpdates
        self.rowInsertEditor = rowInsertEditor
        self.updateRowInsertDraft = updateRowInsertDraft
        self.submitRowInsert = submitRowInsert
        self.cancelRowInsert = cancelRowInsert
        self.pendingDeleteRowIndexes = pendingDeleteRowIndexes
        requestedSelectedRowIndexes = selectedRowIndexes
        self.rowActionKind = rowActionKind
        self.addRow = addRow
        self.duplicateRow = duplicateRow
        self.deleteRows = deleteRows
        self.pasteRows = pasteRows
        self.selectRowsForActions = selectRowsForActions
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
        tableView.usesAlternatingRowBackgroundColors = usesAlternatingRows
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
        updateCellEditHandler(in: tableView)
        updateRowInsertHandlers(in: tableView)
        updateDataRowActionHandlers(in: tableView)
        exportController.attach(
            tableView: tableView,
            sourceKind: .tablePage,
            suggestedFileName: exportFileName,
            allRowsProvider: exportAllRowsProvider
        )
        tableView.setAccessibilityIdentifier("databaseObjectData")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.setAccessibilityIdentifier("databaseObjectData")

        self.tableView = tableView
        rebuildColumns(in: tableView)
        syncRequestedSelection(in: tableView)
        searchController.update(source: .tablePage(page))
        searchController.attachSelectionHandler { [weak self] match in
            self?.revealSearchMatch(match)
        }
        updateSortIndicator(in: tableView)
        if !isFetching {
            updateLoadedSortAccessibility(in: tableView)
        }
        return scrollView
    }

    func update(
        page: WorkspaceDatabaseDataPage,
        isFetching: Bool,
        usesAlternatingRows: Bool = true,
        nullDisplayText: String = "NULL",
        emptyStringDisplayText: String = "",
        copyIncludesColumnNames: Bool = false,
        cellFont: NSFont = WorkspaceGridMetrics.cellFont,
        exportAllRowsProvider: WorkspaceDataExportAllRowsProvider? = nil,
        exportFileName: String = "table-data",
        sortData: @escaping (WorkspaceDatabaseDataSort) -> Void,
        prepareCellEdit: ((WorkspaceDatabaseDataCellEditTarget) ->
            WorkspaceDatabaseDataCellInlineEditContext?)? = nil,
        prepareCellEditAsync: ((WorkspaceDatabaseDataCellEditTarget) async ->
            WorkspaceDatabaseDataCellInlineEditContext?)? = nil,
        updateCellEdit: @escaping (
            WorkspaceDatabaseDataCellInlineEditContext,
            WorkspaceDatabaseInspectorMutation
        ) -> Void = { _, _ in },
        databaseColumns: [WorkspaceDatabaseColumn] = [],
        pendingLoadedUpdates: [WorkspaceDatabaseInspectorPendingUpdate] = [],
        rowInsertEditor: WorkspaceDatabaseDataRowInsertEditorState = .init(),
        updateRowInsertDraft: @escaping (
            UUID,
            String,
            WorkspaceDatabaseDataRowInsertDraft
        ) -> Void = { _, _, _ in },
        submitRowInsert: @escaping () -> Void = {},
        cancelRowInsert: @escaping () -> Void = {},
        pendingDeleteRowIndexes: IndexSet = [],
        selectedRowIndexes: IndexSet = [],
        rowActionKind: WorkspaceDatabaseDataRowActionKind = .tableRow,
        addRow: (() -> Void)? = nil,
        duplicateRow: ((Int) -> Void)? = nil,
        deleteRows: ((IndexSet) -> Void)? = nil,
        pasteRows: ((
            WorkspaceGridPasteboardContent,
            [String],
            UUID?
        ) -> Void)? = nil,
        selectRowsForActions: @escaping (IndexSet) -> Void = { _ in }
    ) {
        self.isFetching = isFetching
        if isFetching { mappingOptionPresenter?.close() }
        self.sortData = sortData
        self.prepareCellEdit = prepareCellEdit
        self.prepareCellEditAsync = prepareCellEditAsync
        self.updateCellEdit = updateCellEdit
        self.databaseColumns = databaseColumns
        let previousPendingLoadedUpdates = self.pendingLoadedUpdates
        self.pendingLoadedUpdates = pendingLoadedUpdates
        self.updateRowInsertDraft = updateRowInsertDraft
        self.submitRowInsert = submitRowInsert
        self.cancelRowInsert = cancelRowInsert
        let previousPendingDeleteRowIndexes = self.pendingDeleteRowIndexes
        self.pendingDeleteRowIndexes = pendingDeleteRowIndexes
        let previousRequestedSelectedRowIndexes = requestedSelectedRowIndexes
        requestedSelectedRowIndexes = selectedRowIndexes
        self.rowActionKind = rowActionKind
        if selectedRowIndexes != previousRequestedSelectedRowIndexes {
            visuallyClearedActionRowIndexes = nil
        }
        if
            pendingSelectedRowsForActions != nil,
            selectedRowIndexes != previousRequestedSelectedRowIndexes,
            selectedRowIndexes != pendingSelectedRowsForActions
        {
            selectedRowsPublicationTask?.cancel()
            selectedRowsPublicationTask = nil
            pendingSelectedRowsForActions = nil
        }
        defer {
            if let tableView = tableView as? WorkspaceDirectDrawTableView {
                syncRequestedSelection(in: tableView)
                if mappingActions != nil {
                    tableView.enumerateAvailableRowViews { [self] _, rowIndex in
                        reconfigureLoadedRow(at: rowIndex, in: tableView)
                    }
                }
            }
        }
        self.addRow = addRow
        self.duplicateRow = duplicateRow
        self.deleteRows = deleteRows
        self.pasteRows = pasteRows
        self.selectRowsForActions = selectRowsForActions
        if let tableView = tableView as? WorkspaceDirectDrawTableView {
            updateCellEditHandler(in: tableView)
            updateRowInsertHandlers(in: tableView)
            updateDataRowActionHandlers(in: tableView)
            refreshPendingPresentation(
                in: tableView,
                previousUpdates: previousPendingLoadedUpdates,
                previousDeleteRowIndexes: previousPendingDeleteRowIndexes
            )
        }
        updateRowInsertEditor(
            rowInsertEditor,
            defersRemovedRowsReload: rowActionKind == .elasticsearchDocument && page.revision != self.page.revision
        )
        self.exportAllRowsProvider = exportAllRowsProvider
        self.exportFileName = exportFileName
        exportController.updateAllRowsProvider(
            exportAllRowsProvider,
            suggestedFileName: exportFileName
        )
        let fontChanged = cellFont.fontName != self.cellFont.fontName
            || cellFont.pointSize != self.cellFont.pointSize
        let displayTextChanged =
            nullDisplayText != self.nullDisplayText
            || emptyStringDisplayText != self.emptyStringDisplayText
        self.usesAlternatingRows = usesAlternatingRows
        self.nullDisplayText = nullDisplayText
        self.emptyStringDisplayText = emptyStringDisplayText
        self.copyIncludesColumnNames = copyIncludesColumnNames
        self.cellFont = cellFont
        if let tableView {
            tableView.usesAlternatingRowBackgroundColors = usesAlternatingRows
            if let directDrawTableView =
                tableView as? WorkspaceDirectDrawTableView {
                directDrawTableView.nullDisplayText = nullDisplayText
                directDrawTableView.emptyStringDisplayText =
                    emptyStringDisplayText
                directDrawTableView.copyIncludesColumnNames =
                    copyIncludesColumnNames
            }
            if fontChanged {
                tableView.rowHeight = Self.rowHeight(for: cellFont)
                applyAutomaticColumnWidths(in: tableView)
                tableView.reloadData()
            } else if displayTextChanged {
                applyAutomaticColumnWidths(in: tableView)
                tableView.reloadData()
            }
        }
        guard page.revision != self.page.revision else { return }
        cellEditPreparationTask?.cancel()
        cellEditPreparationTask = nil
        cellEditPreparationID = nil
        let columnsChanged = page.columns != self.page.columns
        let updatesCurrentPage = !columnsChanged
            && page.offset == self.page.offset
            && page.limit == self.page.limit
            && page.sort == self.page.sort
            && page.filter == self.page.filter
        let appendsCurrentPage = updatesCurrentPage
            && page.rowStore === self.page.rowStore
            && page.rowCount >= self.page.rowCount
        let replacesCurrentPage = updatesCurrentPage
            && page.rowStore !== self.page.rowStore
        self.page = page
        displayedSort = page.sort
        searchController.update(source: .tablePage(page))

        guard let tableView else { return }
        if columnsChanged {
            rebuildColumns(in: tableView)
        } else if mappingActions != nil, !hasSizedLoadedMappingRows, page.rowCount > 0 {
            // The Mapping grid mounts before its asynchronous metadata arrives.
            // Size once against loaded fields, then preserve the user's widths.
            applyAutomaticColumnWidths(in: tableView)
        }
        updateSortIndicator(in: tableView)
        if !isFetching {
            updateLoadedSortAccessibility(in: tableView)
        }
        if appendsCurrentPage {
            tableView.noteNumberOfRowsChanged()
        } else if replacesCurrentPage {
            if
                let directDrawTableView =
                    tableView as? WorkspaceDirectDrawTableView,
                let selectedRows = directDrawTableView.gridSelection.rows,
                selectedRows.upperBound >= page.rowCount
            {
                directDrawTableView.clearGridSelection()
            }
            tableView.reloadData()
        } else {
            (tableView as? WorkspaceDirectDrawTableView)?
                .clearGridSelection()
            tableView.reloadData()
            tableView.scrollRowToVisible(0)
        }
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
                "databaseData.column.\(column.id)"
            )
            columnIndexes[identifier] = column.id

            let tableColumn = NSTableColumn(identifier: identifier)
            tableColumn.title = column.name
            WorkspaceGridMetrics.configureHeaderCell(tableColumn.headerCell)
            tableColumn.headerToolTip = mappingActions == nil ? AppCopy.current.sortBy(column.name) : column.name
            tableColumn.headerCell.setAccessibilityIdentifier(
                "databaseDataColumnHeader.\(column.id)"
            )
            tableColumn.width = 160
            tableColumn.minWidth =
                WorkspaceGridColumnSizing.minimumColumnWidth
            tableColumn.resizingMask = .userResizingMask
            tableView.addTableColumn(tableColumn)
        }
        applyAutomaticColumnWidths(in: tableView)
        tableView.headerView?.needsLayout = true
        if let lastActiveDataColumnIdentifier,
           !tableView.tableColumns.contains(where: {
               $0.identifier == lastActiveDataColumnIdentifier
           })
        {
            self.lastActiveDataColumnIdentifier = nil
        }
    }

    func resetColumnWidths() {
        guard let tableView else { return }
        applyAutomaticColumnWidths(in: tableView)
    }

    private func applyAutomaticColumnWidths(in tableView: NSTableView) {
        if mappingActions != nil, page.rowCount > 0 { hasSizedLoadedMappingRows = true }
        let widths = WorkspaceGridColumnSizing.automaticWidths(
            columns: page.columns,
            rowCount: page.rowCount,
            maximumConsideredRows: nil,
            rowAt: page.row(at:),
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
            if mappingActions != nil, columnIndex >= 2 {
                // Checkbox columns size to their localized headers, not hidden raw text.
                tableColumn.width = max(WorkspaceGridColumnSizing.minimumColumnWidth,
                    ceil((tableColumn.title as NSString).size(withAttributes: [.font: WorkspaceGridMetrics.headerFont]).width)
                        + WorkspaceGridMetrics.cellTrailingPadding)
            } else {
                tableColumn.width = width + (mappingActions != nil && columnIndex == 1 ? WorkspaceGridInlineControls.disclosureWidth : 0)
            }
        }
        isApplyingAutomaticColumnWidths = false
        WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: tableView)
        tableView.headerView?.needsDisplay = true
    }

    private func updateSortIndicator(in tableView: NSTableView) {
        for tableColumn in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: tableColumn)
            tableColumn.headerCell.textColor = .labelColor
        }

        guard
            let columnName = displayedSort.columnName,
            let dataColumn = page.columns.first(where: { $0.name == columnName }),
            let tableColumn = tableView.tableColumns.first(where: {
                $0.identifier.rawValue == "databaseData.column.\(dataColumn.id)"
            })
        else {
            return
        }

        let symbolName: String
        let accessibilityDescription: String
        switch displayedSort {
        case .none:
            return
        case .ascending:
            symbolName = "chevron.up"
            accessibilityDescription = AppCopy.current.text(
                "已按升序排列",
                "Sorted ascending"
            )
        case .descending:
            symbolName = "chevron.down"
            accessibilityDescription = AppCopy.current.text(
                "已按降序排列",
                "Sorted descending"
            )
        }

        let indicator = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )
        indicator?.isTemplate = true
        tableColumn.headerCell.textColor = .controlAccentColor
        tableView.setIndicatorImage(indicator, in: tableColumn)
        tableView.headerView?.needsDisplay = true
    }

    private func updateLoadedSortAccessibility(in tableView: NSTableView) {
        for tableColumn in tableView.tableColumns {
            tableColumn.headerCell.setAccessibilitySortDirection(.unknown)
            tableColumn.headerCell.setAccessibilityValue("Unsorted")
        }

        guard
            let columnName = page.sort.columnName,
            let dataColumn = page.columns.first(where: { $0.name == columnName }),
            let tableColumn = tableView.tableColumns.first(where: {
                $0.identifier.rawValue == "databaseData.column.\(dataColumn.id)"
            })
        else {
            return
        }

        switch page.sort {
        case .none:
            break
        case .ascending:
            tableColumn.headerCell.setAccessibilitySortDirection(.ascending)
            tableColumn.headerCell.setAccessibilityValue("Ascending")
        case .descending:
            tableColumn.headerCell.setAccessibilitySortDirection(.descending)
            tableColumn.headerCell.setAccessibilityValue("Descending")
        }
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

    private func beginEditingCell(
        row: Int,
        tableColumnIndex: Int,
        replacingWith replacement: String? = nil
    ) {
        if isDraftRow(row) {
            beginEditingDraftCell(
                row: row,
                tableColumnIndex: tableColumnIndex
            )
            return
        }
        guard
            !isFetching,
            let tableView,
            tableView.tableColumns.indices.contains(tableColumnIndex),
            let dataColumnIndex = columnIndexes[
                tableView.tableColumns[tableColumnIndex].identifier
            ],
            let dataRow = page.row(at: row)
        else {
            return
        }
        let target = WorkspaceDatabaseDataCellEditTarget(
            rowIndex: row,
            dataColumnIndex: dataColumnIndex,
            columns: page.columns,
            row: dataRow
        )
        if let mappingActions {
            guard mappingActions.canEdit(row, dataColumnIndex) else { return }
            if dataColumnIndex == 2 {
                finishInlineEditing(commit: true)
                mappingActions.toggleIndexed(row)
                return
            }
            let options = mappingActions.cellOptions(row, dataColumnIndex)
            if !options.isEmpty {
                finishInlineEditing(commit: true)
                if mappingOptionPresenter == nil { mappingOptionPresenter = WorkspaceMappingGridOptionPresenter() }
                let rect = tableView.frameOfCell(atColumn: tableColumnIndex, row: row)
                mappingOptionPresenter?.show(items: options, title: target.column?.name ?? "", rect: rect, in: tableView)
                return
            }
        }
        if let prepareCellEdit {
            guard let context = prepareCellEdit(target) else { return }
            beginEditingLoadedCell(
                context,
                tableColumnIndex: tableColumnIndex,
                replacingWith: replacement
            )
            return
        }
        guard let prepareCellEditAsync else { return }
        let preparationID = UUID()
        let pageRevision = page.revision
        cellEditPreparationTask?.cancel()
        cellEditPreparationID = preparationID
        cellEditPreparationTask = Task { @MainActor [weak self] in
            guard let context = await prepareCellEditAsync(target) else {
                if self?.cellEditPreparationID == preparationID {
                    self?.cellEditPreparationTask = nil
                    self?.cellEditPreparationID = nil
                }
                return
            }
            guard
                !Task.isCancelled,
                let self,
                self.cellEditPreparationID == preparationID,
                self.page.revision == pageRevision
            else { return }
            self.cellEditPreparationTask = nil
            self.cellEditPreparationID = nil
            self.beginEditingLoadedCell(
                context,
                tableColumnIndex: tableColumnIndex,
                replacingWith: replacement
            )
        }
    }

    private func updateCellEditHandler(
        in tableView: WorkspaceDirectDrawTableView
    ) {
        if isFetching
            || (prepareCellEdit == nil
                && prepareCellEditAsync == nil
                && !rowInsertEditor.isPresented)
        {
            tableView.cellEditHandler = nil
            tableView.canEditCellHandler = nil
        } else {
            tableView.cellEditHandler = { [weak self] row, column in
                self?.beginEditingCell(row: row, tableColumnIndex: column)
            }
            tableView.canEditCellHandler = { [weak self] row, column in
                guard let self,
                      !self.pendingDeleteRowIndexes.contains(row)
                else { return false }
                if let mappingActions = self.mappingActions {
                    guard let target = self.loadedCellEditTarget(row: row, tableColumnIndex: column) else { return false }
                    return mappingActions.canEdit(target.rowIndex, target.dataColumnIndex)
                }
                if self.isDraftRow(row) {
                    guard
                        self.tableView?.tableColumns.indices.contains(column)
                            == true,
                        let tableColumn = self.tableView?.tableColumns[column],
                        let dataColumnIndex = self.columnIndexes[
                            tableColumn.identifier
                        ],
                        let columnName = self.page.columns.first(where: {
                            $0.id == dataColumnIndex
                        })?.name
                    else {
                        return false
                    }
                    return self.rowInsertEditor.column(named: columnName) != nil
                }
                guard self.prepareCellEditAsync != nil else { return true }
                guard
                    let target = self.loadedCellEditTarget(
                        row: row,
                        tableColumnIndex: column
                    ),
                    let fieldName = target.column?.name
                else { return false }
                return WorkspaceElasticsearchDocumentCellEditor.canEdit(
                    fieldName: fieldName
                )
            }
        }
    }

    private func updateRowInsertHandlers(
        in tableView: WorkspaceDirectDrawTableView
    ) {
        tableView.singleClickCellHandler = { [weak self] row, column in
            guard let self, !self.isFetching else {
                return false
            }
            if let mappingActions = self.mappingActions,
               let target = self.loadedCellEditTarget(row: row, tableColumnIndex: column),
               target.dataColumnIndex > 0,
               mappingActions.canEdit(row, target.dataColumnIndex) {
                self.beginEditingCell(row: row, tableColumnIndex: column)
                return true
            }
            guard self.isDraftRow(row) else { return false }
            self.beginEditingDraftCell(row: row, tableColumnIndex: column)
            return true
        }
        tableView.cellTypingHandler = { [weak self] row, column, text in
            guard let self, !self.isFetching else {
                return false
            }
            if self.isDraftRow(row) {
                self.beginEditingDraftCell(
                    row: row,
                    tableColumnIndex: column,
                    replacingWith: text
                )
            } else {
                guard self.prepareCellEdit != nil
                        || self.prepareCellEditAsync != nil
                else { return false }
                self.beginEditingCell(
                    row: row,
                    tableColumnIndex: column,
                    replacingWith: text
                )
            }
            return true
        }
        tableView.cellContextMenuProvider = { [weak self] row, column in
            self?.draftContextMenu(row: row, tableColumnIndex: column)
        }
        tableView.cellValueMutationMenuItemsProvider = {
            [weak self] row, column in
            self?.loadedValueMutationMenuItems(
                row: row,
                tableColumnIndex: column
            ) ?? []
        }
        tableView.additionalCellContextMenuItemsProvider = {
            [weak self] row, column in
            guard let self else { return [] }
            return self.pendingChangeMenuItems(
                row: row,
                tableColumnIndex: column
            ) + self.rowActionMenuItems(row: row)
        }
        tableView.rowInsertSubmitHandler = rowInsertEditor.isPresented
            ? { [weak self] in self?.submitRowInsert() }
            : nil
        tableView.pasteDataRowsHandler = pasteRows == nil
            ? nil
            : { [weak self] content, startingColumn, row in
                self?.pasteRows(
                    content,
                    startingTableColumn: startingColumn,
                    tableRow: row
                )
            }
        tableView.inlineEditorLayoutHandler = { [weak self] in
            self?.layoutInlineEditor()
        }
    }

    private func updateDataRowActionHandlers(
        in tableView: WorkspaceDirectDrawTableView
    ) {
        tableView.addDataRowHandler = addRow
        tableView.duplicateDataRowHandler = duplicateRow
        tableView.deleteDataRowsHandler = deleteRows
        tableView.canDuplicateDataRowHandler = { [weak self] row in
            guard let self else { return false }
            return self.duplicateRow != nil
                && !self.rowInsertEditor.isSubmitting
                && (self.page.row(at: row) != nil || self.isDraftRow(row))
        }
        tableView.canDeleteDataRowsHandler = { [weak self] rows in
            guard let self else { return false }
            return self.deleteRows != nil
                && !rows.isEmpty
                && !self.rowInsertEditor.isSubmitting
                && rows.allSatisfy {
                    self.isDraftRow($0)
                        || (self.page.row(at: $0) != nil
                            && (self.rowActionKind == .elasticsearchDocument
                                || !self.pendingDeleteRowIndexes.contains($0)))
                }
        }
        tableView.selectedDataRowsChanged = { [weak self] rows in
            guard let self, !self.isSynchronizingSelection else { return }
            if
                let activeColumn = tableView.gridSelection.active?.column,
                tableView.tableColumns.indices.contains(activeColumn),
                self.columnIndexes[
                    tableView.tableColumns[activeColumn].identifier
                ] != nil
            {
                self.lastActiveDataColumnIdentifier =
                    tableView.tableColumns[activeColumn].identifier
            }
            if rows.isEmpty, self.loadedCellInlineEditor.isEditing {
                self.visuallyClearedActionRowIndexes =
                    self.requestedSelectedRowIndexes
                return
            }
            self.visuallyClearedActionRowIndexes = nil
            var validRows = IndexSet()
            for row in rows
            where row < self.page.rowCount + self.rowInsertEditor.rowCount {
                validRows.insert(row)
            }
            self.scheduleSelectedRowsForActions(validRows)
        }
    }

    private func scheduleSelectedRowsForActions(_ rows: IndexSet) {
        pendingSelectedRowsForActions = rows
        selectedRowsPublicationTask?.cancel()
        selectedRowsPublicationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.publishSelectedRowsForActions()
        }
    }

    private func publishSelectedRowsForActions() {
        guard let rows = pendingSelectedRowsForActions else { return }
        pendingSelectedRowsForActions = nil
        selectedRowsPublicationTask = nil
        selectRowsForActions(rows)
    }

    private func syncRequestedSelection(
        in tableView: WorkspaceDirectDrawTableView
    ) {
        if let pendingSelectedRowsForActions {
            guard requestedSelectedRowIndexes == pendingSelectedRowsForActions else {
                return
            }
            selectedRowsPublicationTask?.cancel()
            selectedRowsPublicationTask = nil
            self.pendingSelectedRowsForActions = nil
        }
        let rowCount = page.rowCount + rowInsertEditor.rowCount
        let selectedRows = IndexSet(
            requestedSelectedRowIndexes.filter { $0 >= 0 && $0 < rowCount }
        )
        if
            tableView.gridSelection.isEmpty,
            selectedRows == visuallyClearedActionRowIndexes
        {
            return
        }
        guard selectedRows != tableView.selectedDataRowIndexesForActions else {
            return
        }

        isSynchronizingSelection = true
        defer { isSynchronizingSelection = false }
        guard let activeRow = selectedRows.last else {
            tableView.clearGridSelection()
            return
        }
        guard selectedRows.count == 1 else {
            tableView.clearGridSelection()
            tableView.selectRowIndexes(
                selectedRows,
                byExtendingSelection: false
            )
            WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: tableView)
            tableView.scrollRowToVisible(activeRow)
            return
        }

        let activeColumn = activeDataColumnIndex(in: tableView)
        guard let activeColumn else { return }
        let coordinate = WorkspaceGridCoordinate(
            row: activeRow,
            column: activeColumn
        )
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollRowToVisible(activeRow)
        tableView.scrollColumnToVisible(activeColumn)
    }

    private func activeDataColumnIndex(
        in tableView: WorkspaceDirectDrawTableView
    ) -> Int? {
        if
            let current = tableView.gridSelection.active?.column,
            tableView.tableColumns.indices.contains(current),
            columnIndexes[tableView.tableColumns[current].identifier] != nil
        {
            return current
        }
        if
            let lastActiveDataColumnIdentifier,
            let remembered = tableView.tableColumns.firstIndex(where: {
                $0.identifier == lastActiveDataColumnIdentifier
            })
        {
            return remembered
        }
        if let visible = tableView.tableColumns.indices.first(where: { index in
            columnIndexes[tableView.tableColumns[index].identifier] != nil
                && tableView.rect(ofColumn: index).intersects(tableView.visibleRect)
        }) {
            return visible
        }
        return tableView.tableColumns.firstIndex(where: {
            columnIndexes[$0.identifier] != nil
        })
    }

    private func updateRowInsertEditor(
        _ editor: WorkspaceDatabaseDataRowInsertEditorState,
        defersRemovedRowsReload: Bool = false
    ) {
        let previous = rowInsertEditor
        guard editor.revision >= previous.revision else { return }
        guard previous != editor else { return }
        rowInsertEditor = editor
        guard let tableView = tableView as? WorkspaceDirectDrawTableView else {
            return
        }
        updateCellEditHandler(in: tableView)
        updateRowInsertHandlers(in: tableView)
        updateDataRowActionHandlers(in: tableView)

        if previous.rowIDs != editor.rowIDs {
            let addedRowID = editor.rowIDs.first { !previous.rowIDs.contains($0) }
            finishInlineEditing(commit: addedRowID != nil)
            // The replacement page will reload both loaded rows and remaining drafts below in update().
            if addedRowID == nil, defersRemovedRowsReload { return }
            if addedRowID == nil {
                tableView.clearGridSelection()
                tableView.deselectAll(nil)
            }
            tableView.noteNumberOfRowsChanged()
            tableView.reloadData()
            guard
                editor.isPresented,
                let draftRowID = addedRowID,
                let draftRow = tableRowIndex(forDraftRowID: draftRowID)
            else {
                return
            }
            tableView.scrollRowToVisible(draftRow)
            if let tableColumnIndex = firstEditableDraftTableColumnIndex() {
                let coordinate = WorkspaceGridCoordinate(
                    row: draftRow,
                    column: tableColumnIndex
                )
                tableView.selectGridRange(anchor: coordinate, active: coordinate)
                if !editor.hasEditedColumns(rowID: draftRowID) {
                    beginEditingDraftCell(
                        row: draftRow,
                        tableColumnIndex: tableColumnIndex
                    )
                }
            }
            return
        }

        if editor.isSubmitting {
            finishInlineEditing(commit: true)
        }
        if editor.isPresented {
            let previousRows = Dictionary(
                uniqueKeysWithValues: previous.draftRows.map { ($0.id, $0) }
            )
            editor.draftRows.lazy
                .filter { previousRows[$0.id] != $0 }
                .map(\.id)
                .forEach(redrawDraftRow)
        }
    }

    private func isDraftRow(_ row: Int) -> Bool {
        draftRowID(forTableRow: row) != nil
    }

    private func draftRowID(forTableRow row: Int) -> UUID? {
        rowInsertEditor.rowID(at: row - page.rowCount)
    }

    private func tableRowIndex(forDraftRowID rowID: UUID) -> Int? {
        rowInsertEditor.rowIndex(id: rowID).map { page.rowCount + $0 }
    }

    private func firstEditableDraftTableColumnIndex() -> Int? {
        guard let tableView else { return nil }
        let requiredColumn = rowInsertEditor.request?.columns.first {
            $0.initialDraft.mode == .unfilled
        } ?? rowInsertEditor.request?.columns.first
        guard let requiredColumn else { return nil }
        return tableView.tableColumns.firstIndex { tableColumn in
            guard let dataColumnIndex = columnIndexes[tableColumn.identifier] else {
                return false
            }
            return page.columns.first(where: { $0.id == dataColumnIndex })?.name
                == requiredColumn.id
        }
    }

    private func loadedCellEditTarget(
        row: Int,
        tableColumnIndex: Int
    ) -> WorkspaceDatabaseDataCellEditTarget? {
        guard
            !pendingDeleteRowIndexes.contains(row),
            let tableView,
            tableView.tableColumns.indices.contains(tableColumnIndex),
            let dataColumnIndex = columnIndexes[
                tableView.tableColumns[tableColumnIndex].identifier
            ],
            let dataRow = page.row(at: row)
        else {
            return nil
        }
        return WorkspaceDatabaseDataCellEditTarget(
            rowIndex: row,
            dataColumnIndex: dataColumnIndex,
            columns: page.columns,
            row: dataRow
        )
    }

    private func beginEditingLoadedCell(
        _ context: WorkspaceDatabaseDataCellInlineEditContext,
        tableColumnIndex: Int,
        replacingWith replacement: String? = nil
    ) {
        guard
            !isFetching,
            !pendingDeleteRowIndexes.contains(context.rowIndex),
            let tableView,
            context.rowIndex >= 0,
            context.rowIndex < page.rowCount,
            tableView.tableColumns.indices.contains(tableColumnIndex)
        else {
            NSSound.beep()
            return
        }

        finishInlineEditing(commit: true)
        guard let directTableView = tableView as? WorkspaceDirectDrawTableView
        else { return }
        loadedCellInlineEditor.begin(
            in: directTableView,
            context: context,
            tableColumnIndex: tableColumnIndex,
            cellFont: cellFont,
            replacingWith: replacement,
            update: updateCellEdit,
            canEdit: { [weak self] row, column in
                guard let self,
                      !self.isFetching,
                      !self.pendingDeleteRowIndexes.contains(row),
                      row >= 0,
                      row < self.page.rowCount,
                      self.tableView?.tableColumns.indices.contains(column)
                          == true,
                      let tableColumn = self.tableView?.tableColumns[column]
                else { return false }
                return self.columnIndexes[tableColumn.identifier] != nil
            },
            beginEdit: { [weak self] row, column in
                self?.beginEditingCell(row: row, tableColumnIndex: column)
            },
            redraw: { [weak self] row in
                guard let self,
                      let tableView = self.tableView as? WorkspaceDirectDrawTableView
                else { return }
                self.reconfigureLoadedRow(at: row, in: tableView)
            }
        )
    }

    private func beginEditingDraftCell(
        row: Int,
        tableColumnIndex: Int,
        replacingWith replacement: String? = nil
    ) {
        guard
            let draftRowID = draftRowID(forTableRow: row),
            !rowInsertEditor.isSubmitting,
            let tableView,
            tableView.tableColumns.indices.contains(tableColumnIndex),
            let dataColumnIndex = columnIndexes[
                tableView.tableColumns[tableColumnIndex].identifier
            ],
            let dataColumn = page.columns.first(where: {
                $0.id == dataColumnIndex
            }),
            let draft = rowInsertEditor.draft(
                rowID: draftRowID,
                for: dataColumn.name
            )
        else {
            NSSound.beep()
            return
        }

        finishInlineEditing(commit: true)
        tableView.selectRowIndexes(
            IndexSet(integer: row),
            byExtendingSelection: false
        )
        let editor = makeInlineEditor(
            text: replacement ?? (draft.mode == .value ? draft.text : ""),
            accessibilityLabel: rowActionKind == .elasticsearchDocument
                ? AppCopy.current.text(
                    "新增文档，\(dataColumn.name)",
                    "New document, \(dataColumn.name)"
                )
                : AppCopy.current.text(
                    "新增行，\(dataColumn.name)",
                    "New row, \(dataColumn.name)"
                )
        )
        inlineEditingLoadedContext = nil
        inlineEditingDraftRowID = draftRowID
        inlineEditingColumnName = dataColumn.name
        inlineEditingTableColumnIndex = tableColumnIndex
        inlineEditingText = editor.stringValue
        inlineEditingInitialText = editor.stringValue
        redrawDraftRow(draftRowID)
        presentInlineEditor(
            editor,
            selectsAll: false
        )
    }

    private func makeInlineEditor(
        text: String,
        accessibilityLabel: String
    ) -> NSTextField {
        let editor = NSTextField()
        editor.stringValue = text
        editor.font = cellFont
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
        editor.setAccessibilityLabel(accessibilityLabel)
        return editor
    }

    private func presentInlineEditor(
        _ editor: NSTextField,
        selectsAll: Bool
    ) {
        guard let tableView else { return }
        tableView.addSubview(editor, positioned: .above, relativeTo: nil)
        inlineEditor = editor
        installInlineEditorKeyMonitor()
        layoutInlineEditor()
        Task { @MainActor [weak self, weak tableView, weak editor] in
            await Task.yield()
            guard
                let self,
                let tableView,
                let editor,
                self.inlineEditor === editor,
                editor.superview === tableView
            else {
                return
            }
            tableView.addSubview(editor, positioned: .above, relativeTo: nil)
            self.layoutInlineEditor()
            guard tableView.window?.makeFirstResponder(editor) == true else {
                return
            }
            (editor.currentEditor() as? NSTextView)?.insertionPointColor =
                .controlAccentColor
            if selectsAll {
                editor.currentEditor()?.selectAll(nil)
            } else {
                editor.currentEditor()?.moveToEndOfDocument(nil)
            }
        }
    }

    private func layoutInlineEditor() {
        loadedCellInlineEditor.layout()
        guard
            let tableView,
            let inlineEditor,
            let tableColumnIndex = inlineEditingTableColumnIndex
        else {
            return
        }
        let tableRowIndex = inlineEditingLoadedContext?.rowIndex
            ?? inlineEditingDraftRowID.flatMap(tableRowIndex(forDraftRowID:))
        guard let tableRowIndex else { return }
        inlineEditor.frame = tableView.frameOfCell(
            atColumn: tableColumnIndex,
            row: tableRowIndex
        ).insetBy(dx: 1, dy: 1)
    }

    private func finishInlineEditing(
        commit: Bool,
        movingBy offset: Int? = nil
    ) {
        if inlineEditor == nil, loadedCellInlineEditor.isEditing {
            loadedCellInlineEditor.finish(commit: commit, movingBy: offset)
            return
        }
        guard
            !isEndingInlineEdit,
            let editor = inlineEditor,
            let columnName = inlineEditingColumnName
        else {
            return
        }
        let loadedContext = inlineEditingLoadedContext
        let draftRowID = inlineEditingDraftRowID
        let tableRowIndex = loadedContext?.rowIndex
            ?? draftRowID.flatMap(tableRowIndex(forDraftRowID:))
        isEndingInlineEdit = true
        removeInlineEditorKeyMonitor()
        let currentColumnIndex = inlineEditingTableColumnIndex
        if let loadedContext {
            if commit {
                if inlineEditingText != inlineEditingInitialText {
                    updateCellEdit(
                        loadedContext,
                        .value(inlineEditingText)
                    )
                }
            } else {
                updateCellEdit(
                    loadedContext,
                    loadedContext.initialMutation
                )
            }
        } else if commit,
                  inlineEditingText != inlineEditingInitialText,
                  let draftRowID
        {
            let draft: WorkspaceDatabaseDataRowInsertDraft
            draft = WorkspaceDatabaseDataRowInsertDraft(
                mode: .value,
                text: inlineEditingText
            )
            rowInsertEditor.update(
                rowID: draftRowID,
                columnName: columnName,
                draft: draft
            )
            updateRowInsertDraft(draftRowID, columnName, draft)
        }
        editor.delegate = nil
        editor.removeFromSuperview()
        inlineEditor = nil
        inlineEditingLoadedContext = nil
        inlineEditingDraftRowID = nil
        inlineEditingColumnName = nil
        inlineEditingTableColumnIndex = nil
        inlineEditingText = ""
        inlineEditingInitialText = ""
        tableView?.window?.makeFirstResponder(tableView)
        isEndingInlineEdit = false
        if let draftRowID {
            redrawDraftRow(draftRowID)
        } else if
            let tableRowIndex,
            let tableView = tableView as? WorkspaceDirectDrawTableView
        {
            reconfigureLoadedRow(at: tableRowIndex, in: tableView)
        }

        guard
            let offset,
            let currentColumnIndex,
            let tableRowIndex,
            let targetColumnIndex = adjacentEditableTableColumn(
                from: currentColumnIndex,
                offset: offset
            ),
            let tableView = tableView as? WorkspaceDirectDrawTableView
        else {
            return
        }
        let coordinate = WorkspaceGridCoordinate(
            row: tableRowIndex,
            column: targetColumnIndex
        )
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        beginEditingCell(
            row: tableRowIndex,
            tableColumnIndex: targetColumnIndex
        )
    }

    private func installInlineEditorKeyMonitor() {
        guard inlineEditorKeyMonitor == nil else { return }
        inlineEditorKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard
                    let self,
                    event.window === self.tableView?.window,
                    event.modifierFlags.intersection([
                        .command,
                        .control,
                        .option,
                        .shift,
                    ]) == .command,
                    event.matchesWorkspaceShortcut(keyCode: 9, character: "v"),
                    self.handleTabularInlinePaste()
                else {
                    return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeInlineEditorKeyMonitor() {
        guard let inlineEditorKeyMonitor else { return }
        NSEvent.removeMonitor(inlineEditorKeyMonitor)
        self.inlineEditorKeyMonitor = nil
    }

    private func handleTabularInlinePaste() -> Bool {
        let content = WorkspaceGridPasteboardContent.read(from: .general)
        guard
            pasteRows != nil,
            let text = content.tabSeparatedText,
            text.unicodeScalars.contains(where: {
                $0 == "\t" || $0 == "\n" || $0 == "\r"
            }),
            let rowID = inlineEditingDraftRowID,
            let tableRow = tableRowIndex(forDraftRowID: rowID),
            let tableColumn = inlineEditingTableColumnIndex
        else {
            return false
        }
        inlineEditingText = inlineEditor?.currentEditor()?.string
            ?? inlineEditor?.stringValue
            ?? inlineEditingText
        finishInlineEditing(commit: true)
        pasteRows(
            content,
            startingTableColumn: tableColumn,
            tableRow: tableRow
        )
        return true
    }

    private func moveInlineEditingVertically(by offset: Int) {
        guard
            offset != 0,
            let tableView = tableView as? WorkspaceDirectDrawTableView,
            let tableColumnIndex = inlineEditingTableColumnIndex
        else {
            return
        }
        let currentRow = inlineEditingLoadedContext?.rowIndex
            ?? inlineEditingDraftRowID.flatMap(tableRowIndex(forDraftRowID:))
        guard let currentRow else { return }
        let targetRow = currentRow + offset
        guard targetRow >= 0, targetRow < tableView.numberOfRows else {
            NSSound.beep()
            return
        }

        finishInlineEditing(commit: true)
        let coordinate = WorkspaceGridCoordinate(
            row: targetRow,
            column: tableColumnIndex
        )
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollRowToVisible(targetRow)
        tableView.scrollColumnToVisible(tableColumnIndex)
        beginEditingCell(
            row: targetRow,
            tableColumnIndex: tableColumnIndex
        )
    }

    private func adjacentEditableTableColumn(
        from current: Int,
        offset: Int
    ) -> Int? {
        guard let tableView else { return nil }
        let editable = tableView.tableColumns.indices.filter { index in
            guard
                let dataColumnIndex = columnIndexes[
                    tableView.tableColumns[index].identifier
                ]
            else {
                return false
            }
            if inlineEditingLoadedContext != nil {
                return page.columns.contains { $0.id == dataColumnIndex }
            }
            guard
                let name = page.columns.first(where: {
                    $0.id == dataColumnIndex
                })?.name
            else {
                return false
            }
            return rowInsertEditor.column(named: name) != nil
        }
        guard
            let position = editable.firstIndex(of: current),
            !editable.isEmpty
        else {
            return nil
        }
        let target = (position + offset + editable.count) % editable.count
        return editable[target]
    }

    private func redrawDraftRow(_ rowID: UUID) {
        guard
            let tableView,
            let row = tableRowIndex(forDraftRowID: rowID)
        else {
            return
        }
        guard
            let rowView = tableView.rowView(
                atRow: row,
                makeIfNecessary: false
            ) as? WorkspaceDatabaseDataRowView
        else {
            tableView.reloadData()
            return
        }
        let presentation = makeDraftRowPresentation(rowID: rowID)
        configure(
            rowView,
            dataRow: presentation.row,
            rowIndex: row,
            insertDraftModes: presentation.modes,
            tableView: tableView
        )
    }

    private func refreshPendingPresentation(
        in tableView: WorkspaceDirectDrawTableView,
        previousUpdates: [WorkspaceDatabaseInspectorPendingUpdate],
        previousDeleteRowIndexes: IndexSet
    ) {
        var changedRows = WorkspaceLoadedDataPendingPresentation
            .changedVisibleRowIndexes(
                in: tableView,
                columns: page.columns,
                previousUpdates: previousUpdates,
                updates: pendingLoadedUpdates,
                rowAt: page.row(at:)
            )
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        for rowIndex in visibleRows.location..<NSMaxRange(visibleRows) {
            let deletionChanged = previousDeleteRowIndexes.contains(rowIndex)
                != pendingDeleteRowIndexes.contains(rowIndex)
            if deletionChanged { changedRows.insert(rowIndex) }
        }
        for rowIndex in changedRows {
            reconfigureLoadedRow(at: rowIndex, in: tableView)
        }
    }

    private func reconfigureLoadedRow(
        at rowIndex: Int,
        in tableView: WorkspaceDirectDrawTableView
    ) {
        guard
            let row = page.row(at: rowIndex),
            let rowView = tableView.rowView(
                atRow: rowIndex,
                makeIfNecessary: false
            ) as? WorkspaceDatabaseDataRowView
        else {
            return
        }
        configure(
            rowView,
            dataRow: effectiveLoadedRow(row),
            rowIndex: rowIndex,
            insertDraftModes: nil,
            tableView: tableView
        )
    }

    private func draftContextMenu(
        row: Int,
        tableColumnIndex: Int
    ) -> NSMenu? {
        guard
            isDraftRow(row),
            let tableView,
            tableView.tableColumns.indices.contains(tableColumnIndex),
            let dataColumnIndex = columnIndexes[
                tableView.tableColumns[tableColumnIndex].identifier
            ],
            let columnName = page.columns.first(where: {
                $0.id == dataColumnIndex
            })?.name
        else {
            return nil
        }
        let menu = NSMenu()
        if let column = rowInsertEditor.column(named: columnName) {
            let target = NSValue(
                point: NSPoint(x: tableColumnIndex, y: row)
            )
            addDraftMenuItem(
                to: menu,
                title: AppCopy.current.text("输入值", "Enter Value"),
                action: #selector(editDraftValue(_:)),
                representedObject: target,
                keyEquivalent: "\r"
            )
            addDraftMenuItem(
                to: menu,
                title: AppCopy.current.text(
                    "设为空字符串",
                    "Set to Empty String"
                ),
                action: #selector(setEmptyForDraftCell(_:)),
                representedObject: target
            )
            if column.canUseDefault {
                addDraftMenuItem(
                    to: menu,
                    title: AppCopy.current.text("使用默认值", "Use Default"),
                    action: #selector(useDefaultForDraftCell(_:)),
                    representedObject: target
                )
            }
            if column.column.isNullable {
                addDraftMenuItem(
                    to: menu,
                    title: AppCopy.current.text("设为 NULL", "Set to NULL"),
                    action: #selector(setNullForDraftCell(_:)),
                    representedObject: target
                )
            }
        }
        let rowItems = rowActionMenuItems(row: row)
        if !menu.items.isEmpty, !rowItems.isEmpty {
            menu.addItem(.separator())
        }
        rowItems.forEach(menu.addItem)
        return menu
    }

    private func rowActionMenuItems(row: Int) -> [NSMenuItem] {
        if let mappingActions { return mappingActions.menuItems(row) }
        guard isDraftRow(row) || page.row(at: row) != nil else { return [] }
        let selectedRows = (tableView as? WorkspaceDirectDrawTableView)?
            .selectedDataRowIndexesForActions ?? IndexSet()
        let actionRows = selectedRows.contains(row)
            ? selectedRows
            : IndexSet(integer: row)
        let isPendingDelete = pendingDeleteRowIndexes.contains(row)
        if rowActionKind == .elasticsearchDocument {
            let isCreationDraft = isDraftRow(row)
            let undoesDeletion = actionRows.isSubset(of: pendingDeleteRowIndexes)
            let addItem = NSMenuItem(
                title: AppCopy.current.text("新增文档", "Add Document"),
                action: #selector(addRowFromMenu(_:)),
                keyEquivalent: "i"
            )
            addItem.keyEquivalentModifierMask = .command
            addItem.target = self
            addItem.isEnabled = addRow != nil

            let copyItem = NSMenuItem(
                title: AppCopy.current.text("复制文档", "Copy Document"),
                action: #selector(copyRowFromMenu(_:)),
                keyEquivalent: "c"
            )
            copyItem.keyEquivalentModifierMask = .command
            copyItem.target = self
            copyItem.representedObject = row

            let duplicateItem = NSMenuItem(
                title: AppCopy.current.text(
                    "复制为新增文档",
                    "Duplicate as New Document"
                ),
                action: #selector(duplicateRowFromMenu(_:)),
                keyEquivalent: "d"
            )
            duplicateItem.keyEquivalentModifierMask = .command
            duplicateItem.target = self
            duplicateItem.representedObject = row
            duplicateItem.isEnabled = duplicateRow != nil
                && !rowInsertEditor.isSubmitting
                && !isCreationDraft
                && !isPendingDelete

            let deleteItem = NSMenuItem(
                title: isCreationDraft
                    ? AppCopy.current.text(
                        "放弃新增文档",
                        "Discard New Document"
                    )
                    : undoesDeletion
                        ? AppCopy.current.text("撤销删除", "Undo Delete")
                        : actionRows.count > 1
                            ? AppCopy.current.text(
                                "删除 \(actionRows.count) 篇文档",
                                "Delete \(actionRows.count) Documents"
                            )
                            : AppCopy.current.text("删除文档", "Delete Document"),
                action: #selector(deleteRowFromMenu(_:)),
                keyEquivalent: isPendingDelete ? "" : "\u{8}"
            )
            deleteItem.keyEquivalentModifierMask = []
            deleteItem.target = self
            deleteItem.representedObject = actionRows
            deleteItem.isEnabled = deleteRows != nil
                && !rowInsertEditor.isSubmitting
                && (isCreationDraft || actionRows.allSatisfy { page.row(at: $0) != nil })
            return isCreationDraft
                ? [addItem, copyItem, deleteItem]
                : [addItem, copyItem, duplicateItem, deleteItem]
        }
        let addItem = NSMenuItem(
            title: AppCopy.current.text("新增行", "Add Row"),
            action: #selector(addRowFromMenu(_:)),
            keyEquivalent: "i"
        )
        addItem.keyEquivalentModifierMask = .command
        addItem.target = self
        addItem.isEnabled = addRow != nil

        let copyItem = NSMenuItem(
            title: AppCopy.current.text("复制行", "Copy Row"),
            action: #selector(copyRowFromMenu(_:)),
            keyEquivalent: "c"
        )
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = self
        copyItem.representedObject = row

        let duplicateItem = NSMenuItem(
            title: AppCopy.current.text("复制为新增行", "Duplicate as New Row"),
            action: #selector(duplicateRowFromMenu(_:)),
            keyEquivalent: "d"
        )
        duplicateItem.keyEquivalentModifierMask = .command
        duplicateItem.target = self
        duplicateItem.representedObject = row
        duplicateItem.isEnabled = duplicateRow != nil
            && !rowInsertEditor.isSubmitting
            && !isPendingDelete

        let deleteItem = NSMenuItem(
            title: isPendingDelete
                ? AppCopy.current.text("撤销删除", "Undo Delete")
                : actionRows.count == 1
                    ? AppCopy.current.text("删除行", "Delete Row")
                    : AppCopy.current.text(
                        "删除 \(actionRows.count) 行",
                        "Delete \(actionRows.count) Rows"
                    ),
            action: #selector(deleteRowFromMenu(_:)),
            keyEquivalent: isPendingDelete ? "" : "\u{8}"
        )
        deleteItem.keyEquivalentModifierMask = []
        deleteItem.target = self
        deleteItem.representedObject = isPendingDelete
            ? IndexSet(integer: row)
            : actionRows
        deleteItem.isEnabled = deleteRows != nil
            && !rowInsertEditor.isSubmitting
            && (isPendingDelete || actionRows.allSatisfy {
                isDraftRow($0)
                    || (page.row(at: $0) != nil
                        && !pendingDeleteRowIndexes.contains($0))
            })
        return [addItem, copyItem, duplicateItem, deleteItem]
    }

    private func loadedValueMutationMenuItems(
        row: Int,
        tableColumnIndex: Int
    ) -> [NSMenuItem] {
        guard mappingActions == nil else { return [] }
        guard
            !isDraftRow(row),
            prepareCellEdit != nil || prepareCellEditAsync != nil,
            !isFetching,
            !pendingDeleteRowIndexes.contains(row)
        else {
            return []
        }
        let target = NSValue(point: NSPoint(x: tableColumnIndex, y: row))
        var mutations: [(
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
                AppCopy.current.text("设为空字符串", "Set to Empty String"),
                #selector(setEmptyForLoadedCells(_:)),
                .value("")
            ),
        ]
        if prepareCellEdit != nil {
            mutations.insert(
                (
                    AppCopy.current.text("使用默认值", "Use Default"),
                    #selector(useDefaultForLoadedCells(_:)),
                    .useDefault
                ),
                at: 1
            )
        }
        return mutations.compactMap { item in
            guard canApplyLoadedMutation(
                item.mutation,
                clickedRow: row,
                clickedTableColumnIndex: tableColumnIndex
            ) else {
                return nil
            }
            let menuItem = NSMenuItem(
                title: item.title,
                action: item.action,
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = target
            return menuItem
        }
    }

    @objc private func setNullForLoadedCells(_ sender: NSMenuItem) {
        applyLoadedMutation(.null, from: sender)
    }

    @objc private func useDefaultForLoadedCells(_ sender: NSMenuItem) {
        applyLoadedMutation(.useDefault, from: sender)
    }

    @objc private func setEmptyForLoadedCells(_ sender: NSMenuItem) {
        applyLoadedMutation(.value(""), from: sender)
    }

    private func applyLoadedMutation(
        _ mutation: WorkspaceDatabaseInspectorMutation,
        from sender: NSMenuItem
    ) {
        guard let point = (sender.representedObject as? NSValue)?.pointValue else {
            return
        }
        let coordinates = loadedMutationCoordinates(
            clickedRow: Int(point.y),
            clickedTableColumnIndex: Int(point.x)
        )
        if let prepareCellEdit {
            for coordinate in coordinates {
                guard
                    let target = loadedCellEditTarget(
                        row: coordinate.row,
                        tableColumnIndex: coordinate.column
                    ),
                    let context = prepareCellEdit(target)
                else {
                    continue
                }
                updateCellEdit(context, mutation)
            }
            return
        }
        guard
            let prepareCellEditAsync,
            let coordinate = coordinates.first,
            let target = loadedCellEditTarget(
                row: coordinate.row,
                tableColumnIndex: coordinate.column
            )
        else { return }
        let preparationID = UUID()
        let pageRevision = page.revision
        cellEditPreparationTask?.cancel()
        cellEditPreparationID = preparationID
        cellEditPreparationTask = Task { @MainActor [weak self] in
            let context = await prepareCellEditAsync(target)
            guard let self else { return }
            guard self.cellEditPreparationID == preparationID else { return }
            self.cellEditPreparationTask = nil
            self.cellEditPreparationID = nil
            guard
                !Task.isCancelled,
                self.page.revision == pageRevision,
                let context
            else { return }
            self.updateCellEdit(context, mutation)
        }
    }

    private func canApplyLoadedMutation(
        _ mutation: WorkspaceDatabaseInspectorMutation,
        clickedRow: Int,
        clickedTableColumnIndex: Int
    ) -> Bool {
        let coordinates = loadedMutationCoordinates(
            clickedRow: clickedRow,
            clickedTableColumnIndex: clickedTableColumnIndex
        )
        guard !coordinates.isEmpty else { return false }
        return coordinates.allSatisfy { coordinate in
            guard
                !pendingDeleteRowIndexes.contains(coordinate.row),
                let target = loadedCellEditTarget(
                    row: coordinate.row,
                    tableColumnIndex: coordinate.column
                ),
                isLoadedValueEditable(target.originalValue),
                let name = target.column?.name
            else {
                return false
            }
            if prepareCellEditAsync != nil {
                return mutation != .useDefault
                    && WorkspaceElasticsearchDocumentCellEditor.canEdit(
                        fieldName: name
                    )
            }
            guard
                let column = databaseColumns.first(where: { $0.name == name }),
                !column.isGenerated
            else { return false }
            return switch mutation {
            case .null:
                column.isNullable
            case .useDefault:
                column.defaultValue != nil
                    || column.extra.localizedCaseInsensitiveContains(
                        "default_generated"
                    )
            case .value:
                true
            }
        }
    }

    private func loadedMutationCoordinates(
        clickedRow: Int,
        clickedTableColumnIndex: Int
    ) -> [WorkspaceGridCoordinate] {
        if prepareCellEditAsync != nil {
            return [WorkspaceGridCoordinate(
                row: clickedRow,
                column: clickedTableColumnIndex
            )]
        }
        return selectedLoadedCoordinates(
            clickedRow: clickedRow,
            clickedTableColumnIndex: clickedTableColumnIndex
        )
    }

    private func isLoadedValueEditable(
        _ value: WorkspaceDatabaseDataCell
    ) -> Bool {
        if case .binary = value { return false }
        return true
    }

    private func selectedLoadedCoordinates(
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

    private func pendingChangeMenuItems(
        row: Int,
        tableColumnIndex: Int
    ) -> [NSMenuItem] {
        guard
            !pendingDeleteRowIndexes.contains(row),
            let dataRow = page.row(at: row)
        else {
            return []
        }
        let rowUpdates = pendingLoadedUpdates.filter {
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
           let columnName = page.columns.first(where: {
               $0.id == dataColumnIndex
           })?.name,
           rowUpdates.contains(where: { $0.update.columnName == columnName })
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
            item.representedObject = NSValue(
                point: NSPoint(x: tableColumnIndex, y: row)
            )
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
            item.representedObject = row
            items.append(item)
        }
        return items
    }

    @objc private func addRowFromMenu(_ sender: Any?) {
        addRow?()
    }

    @objc private func duplicateRowFromMenu(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        duplicateRow?(row)
    }

    @objc private func copyRowFromMenu(_ sender: NSMenuItem) {
        guard
            let row = sender.representedObject as? Int,
            let tableView = tableView as? WorkspaceDirectDrawTableView
        else {
            return
        }
        tableView.copyRow(at: row)
    }

    @objc private func deleteRowFromMenu(_ sender: NSMenuItem) {
        guard let rows = sender.representedObject as? IndexSet else { return }
        deleteRows?(rows)
    }

    @objc private func undoCellChangeFromMenu(_ sender: NSMenuItem) {
        guard
            let target = sender.representedObject as? NSValue,
            let context = pendingUpdateContext(
                row: Int(target.pointValue.y),
                tableColumnIndex: Int(target.pointValue.x)
            )
        else {
            return
        }
        updateCellEdit(context.context, context.originalMutation)
    }

    @objc private func undoRowChangesFromMenu(_ sender: NSMenuItem) {
        guard
            let row = sender.representedObject as? Int,
            let dataRow = page.row(at: row)
        else {
            return
        }
        let updates = pendingLoadedUpdates.filter {
            $0.applies(to: dataRow, columns: page.columns)
        }
        for update in updates {
            guard
                let dataColumnIndex = page.columns.first(where: {
                    $0.name == update.update.columnName
                })?.id
            else {
                continue
            }
            let context = WorkspaceDatabaseDataCellInlineEditContext(
                rowIndex: row,
                dataColumnIndex: dataColumnIndex,
                columnName: update.update.columnName,
                initialText: "",
                initialMutation: mutation(for: update.update.originalValue)
            )
            updateCellEdit(context, context.initialMutation)
        }
    }

    private func pendingUpdateContext(
        row: Int,
        tableColumnIndex: Int
    ) -> (
        context: WorkspaceDatabaseDataCellInlineEditContext,
        originalMutation: WorkspaceDatabaseInspectorMutation
    )? {
        guard
            let tableView,
            tableView.tableColumns.indices.contains(tableColumnIndex),
            let dataColumnIndex = columnIndexes[
                tableView.tableColumns[tableColumnIndex].identifier
            ],
            let dataColumn = page.columns.first(where: {
                $0.id == dataColumnIndex
            }),
            let dataRow = page.row(at: row),
            let update = pendingLoadedUpdates.last(where: {
                $0.applies(
                    to: dataRow,
                    columns: page.columns,
                    dataColumnIndex: dataColumnIndex
                )
            })
        else {
            return nil
        }
        let originalMutation = mutation(for: update.update.originalValue)
        return (
            WorkspaceDatabaseDataCellInlineEditContext(
                rowIndex: row,
                dataColumnIndex: dataColumnIndex,
                columnName: dataColumn.name,
                initialText: "",
                initialMutation: originalMutation
            ),
            originalMutation
        )
    }

    private func mutation(
        for cell: WorkspaceDatabaseDataCell
    ) -> WorkspaceDatabaseInspectorMutation {
        switch cell {
        case .null: .null
        case let .text(value): .value(value)
        case .binary: .value("")
        }
    }

    private func addDraftMenuItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        representedObject: Any?,
        keyEquivalent: String = ""
    ) {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = []
        item.target = self
        item.representedObject = representedObject
        menu.addItem(item)
    }

    private func pasteRows(
        _ content: WorkspaceGridPasteboardContent,
        startingTableColumn: Int,
        tableRow: Int?
    ) {
        guard let tableView else { return }
        let targetColumnNames = tableView.tableColumns.indices
            .dropFirst(max(0, startingTableColumn))
            .compactMap { index -> String? in
                guard
                    let dataIndex = columnIndexes[
                        tableView.tableColumns[index].identifier
                    ]
                else {
                    return nil
                }
                return page.columns.first(where: { $0.id == dataIndex })?.name
            }
        let draftRowID = tableRow.flatMap(draftRowID(forTableRow:))
        pasteRows?(content, targetColumnNames, draftRowID)
    }

    @objc private func editDraftValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSValue else { return }
        beginEditingDraftCell(
            row: Int(value.pointValue.y),
            tableColumnIndex: Int(value.pointValue.x)
        )
    }

    @objc private func useDefaultForDraftCell(_ sender: NSMenuItem) {
        updateDraftMode(from: sender, mode: .useDefault)
    }

    @objc private func setNullForDraftCell(_ sender: NSMenuItem) {
        updateDraftMode(from: sender, mode: .null)
    }

    @objc private func setEmptyForDraftCell(_ sender: NSMenuItem) {
        updateDraftMode(from: sender, mode: .value, text: "")
    }

    private func updateDraftMode(
        from sender: NSMenuItem,
        mode: WorkspaceDatabaseDataRowInsertMode,
        text: String? = nil
    ) {
        guard
            let target = sender.representedObject as? NSValue,
            let draftRowID = draftRowID(
                forTableRow: Int(target.pointValue.y)
            ),
            let tableView,
            tableView.tableColumns.indices.contains(Int(target.pointValue.x)),
            let dataColumnIndex = columnIndexes[
                tableView.tableColumns[Int(target.pointValue.x)].identifier
            ],
            let columnName = page.columns.first(where: {
                $0.id == dataColumnIndex
            })?.name,
            var draft = rowInsertEditor.draft(
                rowID: draftRowID,
                for: columnName
            )
        else {
            return
        }
        finishInlineEditing(commit: true)
        draft.mode = mode
        if let text {
            draft.text = text
        }
        rowInsertEditor.update(
            rowID: draftRowID,
            columnName: columnName,
            draft: draft
        )
        updateRowInsertDraft(draftRowID, columnName, draft)
        redrawDraftRow(draftRowID)
    }

}

extension WorkspaceDatabaseDataTableCoordinator: NSTableViewDataSource {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated {
            page.rowCount + rowInsertEditor.rowCount
        }
    }
}

extension WorkspaceDatabaseDataTableCoordinator: NSTableViewDelegate {
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
        didClick tableColumn: NSTableColumn
    ) {
        MainActor.assumeIsolated {
            guard
                !isFetching,
                mappingActions == nil,
                let columnIndex = columnIndexes[tableColumn.identifier],
                page.columns.indices.contains(columnIndex)
            else {
                return
            }

            let sort = displayedSort.toggled(
                for: page.columns[columnIndex].name
            )
            displayedSort = sort
            isFetching = true
            updateSortIndicator(in: tableView)
            sortData(sort)
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
            let insertDraftModes: [Int: WorkspaceDatabaseDataRowInsertMode]?
            let dataRow: WorkspaceDatabaseDataRow
            if let draftRowID = draftRowID(forTableRow: row) {
                let presentation = makeDraftRowPresentation(rowID: draftRowID)
                dataRow = presentation.row
                insertDraftModes = presentation.modes
            } else {
                guard let loadedRow = page.row(at: row) else { return nil }
                dataRow = effectiveLoadedRow(loadedRow)
                insertDraftModes = nil
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
            configure(
                rowView,
                dataRow: dataRow,
                rowIndex: row,
                insertDraftModes: insertDraftModes,
                tableView: tableView
            )
            return rowView
        }
    }
}

extension WorkspaceDatabaseDataTableCoordinator: NSTextFieldDelegate {
    nonisolated func controlTextDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard
                let editor = inlineEditor
            else {
                return
            }
            let text = editor.currentEditor()?.string
                ?? editor.stringValue
            guard text != inlineEditingText else { return }
            if isRowShortcutEvent(NSApp.currentEvent) {
                editor.stringValue = inlineEditingText
                editor.currentEditor()?.string = inlineEditingText
                return
            }
            inlineEditingText = text
            if let loadedContext = inlineEditingLoadedContext {
                updateCellEdit(loadedContext, .value(text))
            }
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
                inlineEditingText = textView.string
                let submitsRow = NSApp.currentEvent?.modifierFlags
                    .contains(.command) == true
                finishInlineEditing(commit: true, movingBy: submitsRow ? nil : 1)
                if submitsRow {
                    submitRowInsert()
                }
                return true
            case #selector(NSResponder.insertTab(_:)):
                inlineEditingText = textView.string
                finishInlineEditing(commit: true, movingBy: 1)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                inlineEditingText = textView.string
                finishInlineEditing(commit: true, movingBy: -1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                inlineEditingText = textView.string
                moveInlineEditingVertically(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                inlineEditingText = textView.string
                moveInlineEditingVertically(by: 1)
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

private extension WorkspaceDatabaseDataTableCoordinator {
    func isRowShortcutEvent(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        guard modifiers == .command else { return false }
        return event.matchesWorkspaceShortcut(keyCode: 34, character: "i")
            || event.matchesWorkspaceShortcut(keyCode: 2, character: "d")
    }

    func configure(
        _ rowView: WorkspaceDatabaseDataRowView,
        dataRow: WorkspaceDatabaseDataRow,
        rowIndex: Int,
        insertDraftModes: [Int: WorkspaceDatabaseDataRowInsertMode]?,
        tableView: NSTableView
    ) {
        rowView.configure(
            tableView: tableView,
            dataRow: dataRow,
            rowIndex: rowIndex,
            columnIndexes: columnIndexes,
            rowNumberIdentifier: Self.rowNumberIdentifier,
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText,
            cellFont: cellFont,
            accessibilityPrefix: "databaseData",
            insertDraftModes: insertDraftModes,
            isInsertDraftEditing: insertDraftModes != nil
                && draftRowID(forTableRow: rowIndex)
                    == inlineEditingDraftRowID,
            pendingUpdateColumnIndexes: insertDraftModes == nil
                ? page.row(at: rowIndex).map(
                    pendingUpdateColumnIndexes(for:)
                ) ?? []
                : [],
            isPendingDeletion: pendingDeleteRowIndexes.contains(rowIndex),
            cellControls: mappingActions?.cellControls(rowIndex) ?? [:]
        )
        rowView.toolTip = mappingActions == nil ? nil : AppCopy.current.text(
            "已索引：半选表示服务器默认，勾选表示开启，空框表示关闭；— 表示不适用。新增字段点击可切换，右侧检查器也可选择服务器默认。可搜索、可聚合由服务器提供，只读。",
            "Indexed: mixed means Server Default, checked means enabled, unchecked means disabled; — means not applicable. Click to cycle for new fields, or choose Server Default in the inspector. Searchable and Aggregatable are read-only server capabilities."
        )
    }

    private func effectiveLoadedRow(
        _ row: WorkspaceDatabaseDataRow
    ) -> WorkspaceDatabaseDataRow {
        WorkspaceLoadedDataPendingPresentation.effectiveRow(
            row,
            columns: page.columns,
            updates: pendingLoadedUpdates
        )
    }

    private func pendingUpdateColumnIndexes(
        for row: WorkspaceDatabaseDataRow
    ) -> Set<Int> {
        if let mappingActions { return mappingActions.changedColumns[row.id] ?? [] }
        return WorkspaceLoadedDataPendingPresentation.pendingUpdateColumnIndexes(
            for: row,
            columns: page.columns,
            updates: pendingLoadedUpdates
        )
    }

    func makeDraftRowPresentation(rowID: UUID) -> (
        row: WorkspaceDatabaseDataRow,
        modes: [Int: WorkspaceDatabaseDataRowInsertMode]
    ) {
        let valueCount = (page.columns.map(\.id).max() ?? -1) + 1
        var values = Array(
            repeating: WorkspaceDatabaseDataCell.text("DEFAULT"),
            count: valueCount
        )
        var modes: [Int: WorkspaceDatabaseDataRowInsertMode] = [:]
        for column in page.columns {
            guard let draft = rowInsertEditor.draft(
                rowID: rowID,
                for: column.name
            ) else {
                modes[column.id] = rowActionKind == .elasticsearchDocument
                    ? .unfilled
                    : .useDefault
                if rowActionKind == .elasticsearchDocument {
                    values[column.id] = .text("")
                }
                continue
            }
            modes[column.id] = draft.mode
            switch draft.mode {
            case .unfilled:
                values[column.id] = .text("")
            case .useDefault:
                values[column.id] = .text("DEFAULT")
            case .null:
                values[column.id] = .null
            case .value:
                values[column.id] = .text(draft.text)
            }
        }
        return (
            WorkspaceDatabaseDataRow(
                id: page.offset
                    + page.rowCount
                    + (rowInsertEditor.rowIndex(id: rowID) ?? 0),
                values: values
            ),
            modes
        )
    }

    static func rowHeight(for font: NSFont) -> CGFloat {
        max(24, ceil(font.ascender - font.descender + font.leading) + 6)
    }
}

extension WorkspaceDatabaseDataTableCoordinator:
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
        let draftRows = rowInsertEditor.rowIDs.map {
            makeDraftRowPresentation(rowID: $0).row
        }
        return WorkspaceGridCopySnapshot(rowAt: { rowIndex in
            if rowIndex < page.rowCount {
                return page.row(at: rowIndex)
            }
            let draftIndex = rowIndex - page.rowCount
            return draftRows.indices.contains(draftIndex)
                ? draftRows[draftIndex]
                : nil
        })
    }
}
