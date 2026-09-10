import AppKit
import SwiftUI

@MainActor
final class WorkspaceDatabaseSchemaGridCoordinator: NSObject {
    private static let statusIdentifier = NSUserInterfaceItemIdentifier(
        "databaseSchema.status"
    )
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier(
        "databaseSchema.row"
    )

    private var content: WorkspaceDatabaseSchemaGridContent
    private var descriptor: WorkspaceDatabaseSchemaEditingDescriptor
    private var schemaChoices: WorkspaceDatabaseSchemaChoices
    private var availableColumnNames: [String]
    private var selection: Binding<UUID?>
    private var isEditable: Bool
    private var usesAlternatingRows: Bool
    private var accessibilityIdentifier: String
    private var add: @MainActor () -> Void
    private var duplicate: @MainActor (UUID) -> Void
    private var updateColumn: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    ) -> Void
    private var updateIndex: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.IndexDefinition
    ) -> Void
    private var primaryKeyColumnIDs: Set<UUID>
    private var setPrimaryKey: @MainActor (UUID, Bool) -> Void
    private var delete: @MainActor (UUID) -> Void
    private var fields: [WorkspaceDatabaseSchemaGridField]
    private var columnIndexes: [NSUserInterfaceItemIdentifier: Int] = [:]
    private weak var tableView: WorkspaceDirectDrawTableView?
    private weak var inlineEditor: NSTextField?
    private var inlineEditingRowID: UUID?
    private var inlineEditingDataIndex: Int?
    private var inlineEditingTableColumnIndex: Int?
    private var inlineEditingInitialText = ""
    private var inlineEditingText = ""
    private var keyCommandMonitor: Any?
    private var optionPopover: NSPopover?
    private let optionPopoverModel =
        WorkspaceDatabaseSchemaGridOptionPopoverModel()
    private var optionPopoverRowID: UUID?
    private var optionPopoverDataIndex: Int?
    private var indexColumnsPopover: NSPopover?
    private let indexColumnsPopoverModel =
        WorkspaceDatabaseSchemaIndexColumnsPopoverModel()
    private var indexColumnsPopoverRowID: UUID?
    private var isEndingInlineEdit = false
    private var isSynchronizingSelection = false

    isolated deinit {
        if let keyCommandMonitor {
            NSEvent.removeMonitor(keyCommandMonitor)
        }
        optionPopover?.close()
        indexColumnsPopover?.close()
    }

    init(
        content: WorkspaceDatabaseSchemaGridContent,
        descriptor: WorkspaceDatabaseSchemaEditingDescriptor,
        schemaChoices: WorkspaceDatabaseSchemaChoices,
        availableColumnNames: [String],
        selection: Binding<UUID?>,
        isEditable: Bool,
        usesAlternatingRows: Bool,
        accessibilityIdentifier: String,
        add: @escaping @MainActor () -> Void,
        duplicate: @escaping @MainActor (UUID) -> Void,
        updateColumn: @escaping @MainActor (
            UUID,
            WorkspaceDatabaseSchemaEditorState.ColumnDefinition
        ) -> Void,
        updateIndex: @escaping @MainActor (
            UUID,
            WorkspaceDatabaseSchemaEditorState.IndexDefinition
        ) -> Void,
        primaryKeyColumnIDs: Set<UUID>,
        setPrimaryKey: @escaping @MainActor (UUID, Bool) -> Void,
        delete: @escaping @MainActor (UUID) -> Void
    ) {
        self.content = content
        self.descriptor = descriptor
        self.schemaChoices = schemaChoices
        self.availableColumnNames = availableColumnNames
        self.selection = selection
        self.isEditable = isEditable
        self.usesAlternatingRows = usesAlternatingRows
        self.accessibilityIdentifier = accessibilityIdentifier
        self.add = add
        self.duplicate = duplicate
        self.updateColumn = updateColumn
        self.updateIndex = updateIndex
        self.primaryKeyColumnIDs = primaryKeyColumnIDs
        self.setPrimaryKey = setPrimaryKey
        self.delete = delete
        fields = WorkspaceDatabaseSchemaGridField.fields(
            for: content.kind,
            descriptor: descriptor
        )
    }

    func makeScrollView() -> NSScrollView {
        let tableView = WorkspaceDirectDrawTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.workspaceDataSource = self
        tableView.rowNumberIdentifier = Self.statusIdentifier
        let headerView = WorkspaceGridHeaderView()
        headerView.resetColumnWidths = { [weak self] in
            self?.resetColumnWidths()
        }
        headerView.frame.size.height = WorkspaceGridMetrics.headerHeight
        tableView.headerView = headerView
        let cellFont = WorkspaceGridMetrics.cellFont
        tableView.rowHeight = max(
            24,
            ceil(cellFont.ascender - cellFont.descender + cellFont.leading) + 6
        )
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = usesAlternatingRows
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.style = .fullWidth
        tableView.setAccessibilityIdentifier(accessibilityIdentifier)
        installHandlers(in: tableView)

        let scrollView = NSScrollView()
        scrollView.contentView = WorkspaceGridViewportClipView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.setAccessibilityIdentifier(accessibilityIdentifier)

        self.tableView = tableView
        startKeyCommandMonitoring()
        rebuildColumns(in: tableView)
        syncTableSelection()
        return scrollView
    }

    func update(
        content: WorkspaceDatabaseSchemaGridContent,
        descriptor: WorkspaceDatabaseSchemaEditingDescriptor,
        schemaChoices: WorkspaceDatabaseSchemaChoices,
        availableColumnNames: [String],
        selection: Binding<UUID?>,
        isEditable: Bool,
        usesAlternatingRows: Bool,
        accessibilityIdentifier: String,
        add: @escaping @MainActor () -> Void,
        duplicate: @escaping @MainActor (UUID) -> Void,
        updateColumn: @escaping @MainActor (
            UUID,
            WorkspaceDatabaseSchemaEditorState.ColumnDefinition
        ) -> Void,
        updateIndex: @escaping @MainActor (
            UUID,
            WorkspaceDatabaseSchemaEditorState.IndexDefinition
        ) -> Void,
        primaryKeyColumnIDs: Set<UUID>,
        setPrimaryKey: @escaping @MainActor (UUID, Bool) -> Void,
        delete: @escaping @MainActor (UUID) -> Void
    ) {
        let previousKind = self.content.kind
        let previousDescriptor = self.descriptor
        let previousContent = self.content
        let previousIsEditable = self.isEditable
        let previousPrimaryKeyColumnIDs = self.primaryKeyColumnIDs
        self.content = content
        self.descriptor = descriptor
        self.schemaChoices = schemaChoices
        self.availableColumnNames = availableColumnNames
        self.selection = selection
        self.isEditable = isEditable
        self.usesAlternatingRows = usesAlternatingRows
        self.accessibilityIdentifier = accessibilityIdentifier
        self.add = add
        self.duplicate = duplicate
        self.updateColumn = updateColumn
        self.updateIndex = updateIndex
        self.primaryKeyColumnIDs = primaryKeyColumnIDs
        self.setPrimaryKey = setPrimaryKey
        self.delete = delete

        guard let tableView else { return }
        tableView.usesAlternatingRowBackgroundColors = usesAlternatingRows
        tableView.setAccessibilityIdentifier(accessibilityIdentifier)
        installHandlers(in: tableView)

        let updatedFields = WorkspaceDatabaseSchemaGridField.fields(
            for: content.kind,
            descriptor: descriptor
        )
        if previousKind != content.kind
            || previousDescriptor != descriptor
            || updatedFields.map(\.identifier) != fields.map(\.identifier)
        {
            fields = updatedFields
            finishInlineEditing(commit: true)
            rebuildColumns(in: tableView)
        } else {
            fields = updatedFields
            updateColumnHeaders(in: tableView)
        }

        if previousContent != content {
            tableView.reloadData()
        } else {
            var rowIDs = previousPrimaryKeyColumnIDs
                .symmetricDifference(primaryKeyColumnIDs)
            if previousIsEditable != isEditable {
                rowIDs.formUnion(content.rowIDs)
            }
            if rowIDs.isEmpty {
                WorkspaceDatabaseSchemaRowView.invalidateVisibleRows(
                    in: tableView
                )
            } else {
                refreshVisibleRows(withIDs: rowIDs, in: tableView)
            }
        }
        syncTableSelection()
    }

    private func refreshVisibleRows(
        withIDs rowIDs: Set<UUID>,
        in tableView: NSTableView
    ) {
        for rowID in rowIDs {
            guard
                let row = content.rowIDs.firstIndex(of: rowID),
                let presentation = rowPresentation(at: row),
                let rowView = tableView.rowView(
                    atRow: row,
                    makeIfNecessary: false
                ) as? WorkspaceDatabaseSchemaRowView
            else {
                continue
            }
            rowView.configure(
                tableView: tableView,
                presentation: presentation,
                rowIndex: row,
                columnIndexes: columnIndexes,
                statusIdentifier: Self.statusIdentifier,
                accessibilityPrefix: accessibilityIdentifier
            )
        }
    }

    private func installHandlers(in tableView: WorkspaceDirectDrawTableView) {
        tableView.canEditCellHandler = { [weak self] row, column in
            self?.canEdit(row: row, tableColumnIndex: column) == true
        }
        tableView.cellEditHandler = { [weak self] row, column in
            self?.beginEditingCell(row: row, tableColumnIndex: column)
        }
        tableView.cellTypingHandler = { [weak self] row, column, text in
            self?.beginTyping(
                row: row,
                tableColumnIndex: column,
                replacement: text
            ) == true
        }
        tableView.singleClickCellHandler = { [weak self] row, column in
            self?.handleSingleClick(row: row, tableColumnIndex: column) == true
        }
        tableView.cellContextMenuProvider = { [weak self] row, _ in
            self?.makeRowContextMenu(row: row)
        }
        tableView.addDataRowHandler = isEditable
            ? { [weak self] in self?.performAdd() }
            : nil
        tableView.duplicateDataRowHandler = { [weak self] row in
            self?.performDuplicate(row: row)
        }
        tableView.deleteDataRowsHandler = { [weak self] rows in
            self?.performDelete(rows: rows)
        }
        tableView.canDuplicateDataRowHandler = { [weak self] row in
            self?.canDuplicate(row: row) == true
        }
        tableView.canDeleteDataRowsHandler = { [weak self] rows in
            self?.canDelete(rows: rows) == true
        }
        tableView.selectedDataRowsChanged = { [weak self] rows in
            self?.tableSelectionChanged(rows: rows)
        }
        tableView.inlineEditorLayoutHandler = { [weak self] in
            self?.layoutInlineEditor()
        }
    }

    private func rebuildColumns(in tableView: WorkspaceDirectDrawTableView) {
        tableView.clearGridSelection()
        tableView.tableColumns.forEach(tableView.removeTableColumn)
        columnIndexes.removeAll(keepingCapacity: true)

        let statusColumn = NSTableColumn(identifier: Self.statusIdentifier)
        statusColumn.title = ""
        WorkspaceGridMetrics.configureHeaderCell(statusColumn.headerCell)
        statusColumn.width = 48
        statusColumn.minWidth = 48
        statusColumn.maxWidth = 48
        statusColumn.resizingMask = []
        tableView.addTableColumn(statusColumn)

        for (dataIndex, field) in fields.enumerated() {
            columnIndexes[field.identifier] = dataIndex
            let column = NSTableColumn(identifier: field.identifier)
            column.title = field.title
            WorkspaceGridMetrics.configureHeaderCell(column.headerCell)
            column.headerToolTip = field.title
            column.headerCell.setAccessibilityIdentifier(
                "\(accessibilityIdentifier).header.\(dataIndex)"
            )
            column.width = 160
            column.minWidth = field.minimumWidth
            column.maxWidth = field.maximumWidth
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
        }
        applyAutomaticColumnWidths(in: tableView)
        tableView.headerView?.needsLayout = true
    }

    private func updateColumnHeaders(
        in tableView: WorkspaceDirectDrawTableView
    ) {
        for field in fields {
            guard let column = tableView.tableColumn(withIdentifier: field.identifier)
            else { continue }
            column.title = field.title
            column.headerToolTip = field.title
        }
        tableView.headerView?.needsDisplay = true
    }

    func resetColumnWidths() {
        guard let tableView else { return }
        applyAutomaticColumnWidths(in: tableView)
    }

    private func applyAutomaticColumnWidths(
        in tableView: WorkspaceDirectDrawTableView
    ) {
        let sampleRows = 0..<min(content.count, 30)
        for (dataIndex, field) in fields.enumerated() {
            guard let column = tableView.tableColumn(withIdentifier: field.identifier)
            else { continue }
            var width = measuredWidth(
                field.title,
                font: WorkspaceGridMetrics.headerFont
            ) + 12
            for row in sampleRows {
                guard let presentation = rowPresentation(at: row) else { continue }
                width = max(
                    width,
                    measuredWidth(
                        presentation.values[dataIndex],
                        font: WorkspaceGridMetrics.cellFont
                    ) + WorkspaceGridMetrics.cellTrailingPadding
                        + (presentation.optionIndexes.contains(dataIndex) ? 20 : 0)
                )
            }
            column.width = min(
                max(ceil(width), field.minimumWidth),
                field.maximumWidth
            )
        }
        if content.kind == .column,
           let nameField = fields.first,
           let commentField = fields.last,
           let nameColumn = tableView.tableColumn(
               withIdentifier: nameField.identifier
           ),
           let commentColumn = tableView.tableColumn(
               withIdentifier: commentField.identifier
           )
        {
            commentColumn.width = max(commentColumn.width, nameColumn.width)
        }
    }

    private func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func syncTableSelection() {
        guard let tableView, !isSynchronizingSelection else { return }
        guard let selectedID = selection.wrappedValue else {
            if !tableView.gridSelection.isEmpty
                || !tableView.selectedRowIndexes.isEmpty
            {
                isSynchronizingSelection = true
                tableView.clearGridSelection()
                isSynchronizingSelection = false
            }
            return
        }
        guard
            let row = content.rowIDs.firstIndex(of: selectedID),
            let firstColumn = firstDataTableColumnIndex(in: tableView)
        else {
            selection.wrappedValue = nil
            return
        }
        if tableView.gridSelection.active?.row == row
            || tableView.selectedRowIndexes == IndexSet(integer: row)
        {
            return
        }
        isSynchronizingSelection = true
        let coordinate = WorkspaceGridCoordinate(row: row, column: firstColumn)
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollRowToVisible(row)
        isSynchronizingSelection = false
    }

    private func tableSelectionChanged(rows: IndexSet) {
        guard !isSynchronizingSelection, let tableView else { return }
        let row = tableView.gridSelection.active?.row ?? rows.last
        let selectedID = row.flatMap(rowID(at:))
        if selection.wrappedValue != selectedID {
            selection.wrappedValue = selectedID
        }
    }

    private func firstDataTableColumnIndex(
        in tableView: WorkspaceDirectDrawTableView
    ) -> Int? {
        tableView.tableColumns.firstIndex {
            $0.identifier != Self.statusIdentifier
        }
    }

    private func rowID(at row: Int) -> UUID? {
        guard content.rowIDs.indices.contains(row) else { return nil }
        return content.rowIDs[row]
    }

    private func canDuplicate(row: Int) -> Bool {
        guard isEditable else { return false }
        switch content {
        case let .columns(items):
            return items.indices.contains(row) && !items[row].isDeleted
        case let .indexes(items):
            return items.indices.contains(row) && !items[row].isDeleted
        }
    }

    private func canDelete(rows: IndexSet) -> Bool {
        guard isEditable, !rows.isEmpty else { return false }
        return rows.allSatisfy { row in
            switch content {
            case let .columns(items):
                items.indices.contains(row) && !items[row].isDeleted
            case let .indexes(items):
                items.indices.contains(row) && !items[row].isDeleted
            }
        }
    }

    private func performAdd() {
        guard isEditable else { return }
        finishInlineEditing(commit: true)
        indexColumnsPopover?.close()
        add()
    }

    private func performDuplicate(row: Int) {
        guard canDuplicate(row: row), let id = rowID(at: row) else {
            NSSound.beep()
            return
        }
        finishInlineEditing(commit: true)
        duplicate(id)
    }

    private func performDelete(rows: IndexSet) {
        guard canDelete(rows: rows) else {
            NSSound.beep()
            return
        }
        finishInlineEditing(commit: true)
        let ids = rows.compactMap(rowID(at:))
        ids.forEach(delete)
    }

    private func makeRowContextMenu(row: Int) -> NSMenu? {
        guard let rowID = rowID(at: row) else { return nil }
        let menu = NSMenu()

        let addItem = NSMenuItem(
            title: content.kind.addTitle,
            action: #selector(addMenuItemPressed(_:)),
            keyEquivalent: "i"
        )
        addItem.keyEquivalentModifierMask = .command
        addItem.target = self
        addItem.isEnabled = isEditable
        menu.addItem(addItem)

        let duplicateItem = NSMenuItem(
            title: content.kind.duplicateTitle,
            action: #selector(duplicateMenuItemPressed(_:)),
            keyEquivalent: "d"
        )
        duplicateItem.keyEquivalentModifierMask = .command
        duplicateItem.target = self
        duplicateItem.representedObject = rowID as NSUUID
        duplicateItem.isEnabled = canDuplicate(row: row)
        menu.addItem(duplicateItem)
        menu.addItem(.separator())

        let deleteItem = NSMenuItem(
            title: content.kind.deleteTitle,
            action: #selector(deleteMenuItemPressed(_:)),
            keyEquivalent: "\u{8}"
        )
        deleteItem.keyEquivalentModifierMask = []
        deleteItem.target = self
        deleteItem.representedObject = rowID as NSUUID
        deleteItem.isEnabled = isEditable && canDelete(
            rows: IndexSet(integer: row)
        )
        menu.addItem(deleteItem)
        return menu
    }

    @objc private func addMenuItemPressed(_ sender: NSMenuItem) {
        performAdd()
    }

    @objc private func duplicateMenuItemPressed(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? NSUUID,
            let row = content.rowIDs.firstIndex(of: id as UUID)
        else { return }
        performDuplicate(row: row)
    }

    @objc private func deleteMenuItemPressed(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? NSUUID,
            let row = content.rowIDs.firstIndex(of: id as UUID)
        else { return }
        performDelete(rows: IndexSet(integer: row))
    }

    private func canEdit(row: Int, tableColumnIndex: Int) -> Bool {
        guard
            let dataIndex = dataIndex(for: tableColumnIndex),
            let presentation = rowPresentation(at: row)
        else {
            return false
        }
        return presentation.editableIndexes.contains(dataIndex)
    }

    private func dataIndex(for tableColumnIndex: Int) -> Int? {
        guard
            let tableView,
            tableView.tableColumns.indices.contains(tableColumnIndex)
        else {
            return nil
        }
        return columnIndexes[
            tableView.tableColumns[tableColumnIndex].identifier
        ]
    }

    private func beginEditingCell(row: Int, tableColumnIndex: Int) {
        guard
            canEdit(row: row, tableColumnIndex: tableColumnIndex),
            let dataIndex = dataIndex(for: tableColumnIndex),
            fields.indices.contains(dataIndex)
        else {
            NSSound.beep()
            return
        }
        switch fields[dataIndex].editing {
        case .boolean:
            toggleBoolean(row: row, dataIndex: dataIndex)
        case let .options(allowsCustomValue):
            if allowsCustomValue {
                beginTextEditing(
                    row: row,
                    dataIndex: dataIndex,
                    tableColumnIndex: tableColumnIndex
                )
            } else {
                presentOptions(
                    row: row,
                    dataIndex: dataIndex,
                    tableColumnIndex: tableColumnIndex
                )
            }
        case .defaultValue:
            if defaultMode(at: row) == .value
                || defaultMode(at: row) == .expression
            {
                beginTextEditing(
                    row: row,
                    dataIndex: dataIndex,
                    tableColumnIndex: tableColumnIndex
                )
            } else {
                presentOptions(
                    row: row,
                    dataIndex: dataIndex,
                    tableColumnIndex: tableColumnIndex
                )
            }
        case .indexColumns:
            presentIndexColumns(
                row: row,
                tableColumnIndex: tableColumnIndex
            )
        case .text:
            beginTextEditing(
                row: row,
                dataIndex: dataIndex,
                tableColumnIndex: tableColumnIndex
            )
        }
    }

    private func beginTyping(
        row: Int,
        tableColumnIndex: Int,
        replacement: String
    ) -> Bool {
        guard
            canEdit(row: row, tableColumnIndex: tableColumnIndex),
            let dataIndex = dataIndex(for: tableColumnIndex),
            fields.indices.contains(dataIndex)
        else {
            return false
        }
        switch fields[dataIndex].editing {
        case .text, .defaultValue, .options(allowsCustomValue: true):
            beginTextEditing(
                row: row,
                dataIndex: dataIndex,
                tableColumnIndex: tableColumnIndex,
                replacement: replacement
            )
            return true
        case .boolean, .indexColumns, .options(allowsCustomValue: false):
            return false
        }
    }

    private func handleSingleClick(
        row: Int,
        tableColumnIndex: Int
    ) -> Bool {
        guard
            canEdit(row: row, tableColumnIndex: tableColumnIndex),
            let dataIndex = dataIndex(for: tableColumnIndex),
            fields.indices.contains(dataIndex)
        else {
            return false
        }
        switch fields[dataIndex].editing {
        case .boolean:
            toggleBoolean(row: row, dataIndex: dataIndex)
            return true
        case .options, .defaultValue, .indexColumns:
            guard disclosureWasClicked(
                row: row,
                tableColumnIndex: tableColumnIndex
            ) else {
                return false
            }
            if fields[dataIndex].editing == .indexColumns {
                presentIndexColumns(
                    row: row,
                    tableColumnIndex: tableColumnIndex
                )
            } else {
                presentOptions(
                    row: row,
                    dataIndex: dataIndex,
                    tableColumnIndex: tableColumnIndex
                )
            }
            return true
        case .text:
            return false
        }
    }

    private func disclosureWasClicked(
        row: Int,
        tableColumnIndex: Int
    ) -> Bool {
        guard
            let tableView,
            let event = NSApp.currentEvent,
            event.window === tableView.window
        else {
            return false
        }
        let point = tableView.convert(event.locationInWindow, from: nil)
        let cellRect = tableView.frameOfCell(
            atColumn: tableColumnIndex,
            row: row
        )
        return point.x >= cellRect.maxX - 16
    }

    private func beginTextEditing(
        row: Int,
        dataIndex: Int,
        tableColumnIndex: Int,
        replacement: String? = nil
    ) {
        guard
            let tableView,
            let rowID = rowID(at: row),
            let initialText = editingText(row: row, dataIndex: dataIndex)
        else {
            NSSound.beep()
            return
        }
        finishInlineEditing(commit: true)
        let editor = NSTextField()
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
        editor.setAccessibilityLabel(
            AppCopy.current.text(
                "编辑\(fields[dataIndex].title)",
                "Edit \(fields[dataIndex].title)"
            )
        )
        inlineEditingRowID = rowID
        inlineEditingDataIndex = dataIndex
        inlineEditingTableColumnIndex = tableColumnIndex
        inlineEditingInitialText = initialText
        inlineEditingText = editor.stringValue
        tableView.suppressActiveCellIndicator(
            at: WorkspaceGridCoordinate(
                row: row,
                column: tableColumnIndex
            )
        )
        tableView.addSubview(editor, positioned: .above, relativeTo: nil)
        inlineEditor = editor
        startKeyCommandMonitoring()
        layoutInlineEditor()
        Task { @MainActor [weak self, weak tableView, weak editor] in
            await Task.yield()
            guard
                let self,
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
            if replacement == nil {
                editor.currentEditor()?.selectAll(nil)
            } else {
                editor.currentEditor()?.moveToEndOfDocument(nil)
            }
        }
    }

    private func layoutInlineEditor() {
        guard
            let tableView,
            let editor = inlineEditor,
            let rowID = inlineEditingRowID,
            let row = content.rowIDs.firstIndex(of: rowID),
            let column = inlineEditingTableColumnIndex
        else { return }
        editor.frame = Self.inlineEditorFrame(
            rowRect: tableView.rect(ofRow: row),
            columnRect: tableView.rect(ofColumn: column)
        )
    }

    static func inlineEditorFrame(
        rowRect: NSRect,
        columnRect: NSRect
    ) -> NSRect {
        rowRect.intersection(columnRect).insetBy(dx: 0, dy: 1)
    }

    private func finishInlineEditing(
        commit: Bool,
        movingBy offset: Int? = nil
    ) {
        guard
            !isEndingInlineEdit,
            let editor = inlineEditor,
            let rowID = inlineEditingRowID,
            let dataIndex = inlineEditingDataIndex
        else { return }
        isEndingInlineEdit = true
        inlineEditingText = editor.currentEditor()?.string
            ?? editor.stringValue
        let row = content.rowIDs.firstIndex(of: rowID)
        let currentTableColumn = inlineEditingTableColumnIndex
        editor.delegate = nil
        editor.removeFromSuperview()
        inlineEditor = nil
        tableView?.suppressActiveCellIndicator(at: nil)
        inlineEditingRowID = nil
        inlineEditingDataIndex = nil
        inlineEditingTableColumnIndex = nil
        let text = inlineEditingText
        let initialText = inlineEditingInitialText
        inlineEditingInitialText = ""
        inlineEditingText = ""
        tableView?.window?.makeFirstResponder(tableView)
        isEndingInlineEdit = false

        if commit, text != initialText {
            commitText(rowID: rowID, dataIndex: dataIndex, text: text)
        }
        guard
            let row,
            let offset,
            let currentTableColumn,
            let targetColumn = adjacentEditableTableColumn(
                row: row,
                from: currentTableColumn,
                offset: offset
            ),
            let tableView
        else {
            if let row, let tableView {
                tableView.reloadData(
                    forRowIndexes: IndexSet(integer: row),
                    columnIndexes: IndexSet(
                        integersIn: 0..<tableView.numberOfColumns
                    )
                )
            }
            return
        }
        let coordinate = WorkspaceGridCoordinate(row: row, column: targetColumn)
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        beginEditingCell(row: row, tableColumnIndex: targetColumn)
    }

    private func adjacentEditableTableColumn(
        row: Int,
        from current: Int,
        offset: Int
    ) -> Int? {
        guard let tableView else { return nil }
        let editable = tableView.tableColumns.indices.filter {
            canEdit(row: row, tableColumnIndex: $0)
        }
        guard let position = editable.firstIndex(of: current) else { return nil }
        let target = position + offset
        guard editable.indices.contains(target) else { return nil }
        return editable[target]
    }

    private func moveInlineEditingVertically(by offset: Int) {
        guard
            let rowID = inlineEditingRowID,
            let row = content.rowIDs.firstIndex(of: rowID),
            let column = inlineEditingTableColumnIndex,
            let tableView
        else { return }
        let targetRow = row + offset
        guard
            targetRow >= 0,
            targetRow < content.count,
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
        beginEditingCell(row: targetRow, tableColumnIndex: column)
    }

    private func startKeyCommandMonitoring() {
        guard keyCommandMonitor == nil else { return }
        keyCommandMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard
                    let self,
                    event.window === self.tableView?.window
                else {
                    return false
                }
                return self.handleKeyCommand(
                    event,
                    firstResponder: event.window?.firstResponder
                )
            }
            return handled ? nil : event
        }
    }

    func stopKeyCommandMonitoring() {
        guard let keyCommandMonitor else { return }
        NSEvent.removeMonitor(keyCommandMonitor)
        self.keyCommandMonitor = nil
    }

    func handleKeyCommand(
        _ event: NSEvent,
        firstResponder: NSResponder?
    ) -> Bool {
        guard isKeyCommandTarget(firstResponder) else { return false }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        guard
            modifiers == .command
        else {
            return false
        }
        if event.matchesWorkspaceShortcut(keyCode: 34, character: "i"),
           isEditable
        {
            performAdd()
            return true
        }
        if event.matchesWorkspaceShortcut(keyCode: 2, character: "d") {
            let row = inlineEditingRowID.flatMap {
                content.rowIDs.firstIndex(of: $0)
            } ?? tableView.flatMap { tableView in
                let rows = tableView.selectedDataRowIndexesForActions
                return rows.count == 1 ? rows.first : nil
            }
            guard let row, canDuplicate(row: row) else { return false }
            performDuplicate(row: row)
            return true
        }
        return false
    }

    private func isKeyCommandTarget(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === tableView || responder === inlineEditor {
            return true
        }
        return inlineEditor?.currentEditor() === responder
    }

    private func presentOptions(
        row: Int,
        dataIndex: Int,
        tableColumnIndex: Int
    ) {
        guard
            let tableView,
            let rowID = rowID(at: row)
        else { return }
        let options = options(row: row, dataIndex: dataIndex)
        guard !options.isEmpty else {
            NSSound.beep()
            return
        }
        finishInlineEditing(commit: true)
        if usesCompactMenu(dataIndex: dataIndex) {
            presentCompactMenu(
                options: options,
                row: row,
                rowID: rowID,
                dataIndex: dataIndex,
                tableColumnIndex: tableColumnIndex
            )
            return
        }
        optionPopover?.close()
        optionPopoverRowID = rowID
        optionPopoverDataIndex = dataIndex
        optionPopoverModel.prepare(
            options: options,
            selectedValue: optionValue(row: row, dataIndex: dataIndex),
            accessibilityTitle: fields[dataIndex].title
        )
        let popover = reusableOptionPopover()
        let cellRect = tableView.frameOfCell(
            atColumn: tableColumnIndex,
            row: row
        )
        popover.show(
            relativeTo: cellRect,
            of: tableView,
            preferredEdge: .maxY
        )
    }

    private func usesCompactMenu(dataIndex: Int) -> Bool {
        guard fields.indices.contains(dataIndex) else { return false }
        let field = fields[dataIndex]
        return field.columnField == .defaultValue
            || field.columnField == .automaticValue
            || field.columnField == .generatedStorage
            || field.indexField == .kind
            || field.indexField == .method
    }

    private func presentCompactMenu(
        options: [WorkspaceDatabaseSchemaOptionPicker.Option],
        row: Int,
        rowID: UUID,
        dataIndex: Int,
        tableColumnIndex: Int
    ) {
        guard let tableView else { return }
        optionPopover?.close()
        indexColumnsPopover?.close()
        optionPopoverRowID = rowID
        optionPopoverDataIndex = dataIndex
        let selectedValue = optionValue(row: row, dataIndex: dataIndex)
        let menu = NSMenu()
        menu.autoenablesItems = false
        var selectedItem: NSMenuItem?
        for (offset, option) in options.enumerated() {
            if offset > 0, needsSeparator(before: option.value, dataIndex: dataIndex) {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(
                title: option.title,
                action: #selector(compactOptionSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.value
            item.state = selectedValue == option.value ? .on : .off
            item.isEnabled = true
            menu.addItem(item)
            if item.state == .on { selectedItem = item }
        }
        let cellRect = tableView.frameOfCell(
            atColumn: tableColumnIndex,
            row: row
        )
        menu.popUp(
            positioning: selectedItem,
            at: NSPoint(x: cellRect.minX, y: cellRect.maxY),
            in: tableView
        )
    }

    private func needsSeparator(before value: String, dataIndex: Int) -> Bool {
        guard fields.indices.contains(dataIndex) else { return false }
        return switch fields[dataIndex].columnField {
        case .defaultValue:
            value == WorkspaceDatabaseSchemaEditorState.DefaultPreset
                .currentTimestamp.rawValue
                || value == WorkspaceDatabaseSchemaEditorState.DefaultPreset
                .custom.rawValue
        case .automaticValue:
            value == WorkspaceDatabaseSchemaEditorState.ExtraPreset.custom.rawValue
        case .none, .some:
            false
        }
    }

    @objc private func compactOptionSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        selectOption(value)
    }

    private func reusableOptionPopover() -> NSPopover {
        if let optionPopover { return optionPopover }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 220, height: 320)
        popover.contentViewController = NSHostingController(
            rootView: WorkspaceDatabaseSchemaGridOptionPopover(
                model: optionPopoverModel,
                select: { [weak self] value in
                    self?.selectOption(value)
                },
                dismiss: { [weak self] in
                    self?.optionPopover?.close()
                }
            )
        )
        optionPopover = popover
        return popover
    }

    private func presentIndexColumns(
        row: Int,
        tableColumnIndex: Int
    ) {
        guard
            let tableView,
            case let .indexes(items) = content,
            items.indices.contains(row)
        else { return }
        finishInlineEditing(commit: true)
        optionPopover?.close()
        indexColumnsPopover?.close()
        let item = items[row]
        indexColumnsPopoverRowID = item.id
        indexColumnsPopoverModel.prepare(
            columns: item.definition.columns,
            availableColumnNames: availableColumnNames,
            accessibilityTitle: AppCopy.current.text(
                "编辑索引字段",
                "Edit Index Columns"
            ),
            supportsPrefixLength: descriptor.supportsIndexPrefixLength,
            supportsDirection: descriptor.supportsIndexDirection
        )
        let popover = reusableIndexColumnsPopover()
        let cellRect = tableView.frameOfCell(
            atColumn: tableColumnIndex,
            row: row
        )
        popover.show(
            relativeTo: cellRect,
            of: tableView,
            preferredEdge: .maxY
        )
    }

    private func reusableIndexColumnsPopover() -> NSPopover {
        if let indexColumnsPopover { return indexColumnsPopover }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 480, height: 330)
        popover.contentViewController = NSHostingController(
            rootView: WorkspaceDatabaseSchemaIndexColumnsPopover(
                model: indexColumnsPopoverModel,
                update: { [weak self] columns in
                    self?.applyIndexColumns(columns)
                }
            )
        )
        indexColumnsPopover = popover
        return popover
    }

    private func applyIndexColumns(
        _ columns: [WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition]
    ) {
        guard
            let rowID = indexColumnsPopoverRowID,
            case var .indexes(items) = content,
            let row = items.firstIndex(where: { $0.id == rowID })
        else { return }
        var definition = items[row].definition
        definition.columns = columns
        items[row].definition = definition
        content = .indexes(items)
        updateIndex(rowID, definition)
        tableView?.reloadData()
    }

    private func selectOption(_ value: String) {
        guard
            let rowID = optionPopoverRowID,
            let dataIndex = optionPopoverDataIndex
        else { return }
        optionPopover?.close()
        applyOption(rowID: rowID, dataIndex: dataIndex, value: value)
    }

    private func options(
        row: Int,
        dataIndex: Int
    ) -> [WorkspaceDatabaseSchemaOptionPicker.Option] {
        guard fields.indices.contains(dataIndex) else { return [] }
        return switch fields[dataIndex].columnField {
        case .type:
            descriptor.columnTypes.map {
                .init(value: $0, title: $0)
            }
        case .characterSet:
            WorkspaceDatabaseSchemaChoiceCatalog.characterSets(schemaChoices)
        case .collation:
            WorkspaceDatabaseSchemaChoiceCatalog.collations(
                schemaChoices,
                characterSet: columnDefinition(at: row)?.characterSet ?? ""
            )
        case .defaultValue:
            WorkspaceDatabaseSchemaChoiceCatalog.defaultPresets(
                allowsNull: rowID(at: row).map {
                    !primaryKeyColumnIDs.contains($0)
                } ?? true
            )
        case .automaticValue:
            descriptor.automaticValueStyle == .autoIncrement
                ? WorkspaceDatabaseSchemaChoiceCatalog.extraPresets
                : []
        case .generatedStorage:
            descriptor.generatedStorages.map {
                .init(value: $0.rawValue, title: $0.rawValue)
            }
        case .name, .primaryKey, .nullable, .generationExpression, .comment,
                .none:
            switch fields[dataIndex].indexField {
            case .kind:
                indexKindOptions
            case .method:
                descriptor.indexMethods.map {
                    .init(value: $0, title: $0)
                }
            case .name, .columns, .visible, .comment, .none:
                []
            }
        }
    }

    private func optionValue(row: Int, dataIndex: Int) -> String? {
        guard fields.indices.contains(dataIndex) else { return nil }
        switch content {
        case let .columns(items):
            guard items.indices.contains(row) else { return nil }
            return switch fields[dataIndex].columnField {
            case .type: items[row].definition.type
            case .characterSet: items[row].definition.characterSet
            case .collation: items[row].definition.collation
            case .defaultValue: items[row].definition.defaultPreset.rawValue
            case .automaticValue: items[row].definition.extraPreset.rawValue
            case .generatedStorage: items[row].definition.generatedStorage.rawValue
            case .name, .primaryKey, .nullable, .generationExpression, .comment,
                    .none: nil
            }
        case let .indexes(items):
            guard items.indices.contains(row) else { return nil }
            return switch fields[dataIndex].indexField {
            case .kind: items[row].definition.kind.rawValue
            case .method: items[row].definition.method
            case .name, .columns, .visible, .comment, .none: nil
            }
        }
    }

    private func applyOption(rowID: UUID, dataIndex: Int, value: String) {
        guard fields.indices.contains(dataIndex) else { return }
        switch content {
        case var .columns(items):
            guard let row = items.firstIndex(where: { $0.id == rowID }) else {
                return
            }
            var definition = items[row].definition
            var beginsCustomEditing = false
            switch fields[dataIndex].columnField {
            case .type:
                definition.type = value
            case .characterSet:
                definition.applyCharacterSet(value, choices: schemaChoices)
            case .collation:
                definition.applyCollation(value, choices: schemaChoices)
            case .defaultValue:
                guard let preset = WorkspaceDatabaseSchemaEditorState.DefaultPreset(
                    rawValue: value
                ) else { return }
                definition.applyDefaultPreset(preset)
                beginsCustomEditing = preset == .custom
            case .automaticValue:
                guard let preset = WorkspaceDatabaseSchemaEditorState.ExtraPreset(
                    rawValue: value
                ) else { return }
                definition.applyExtraPreset(preset)
                beginsCustomEditing = preset == .custom
            case .generatedStorage:
                guard let storage = WorkspaceDatabaseSchemaEditorState
                    .GeneratedStorage(rawValue: value)
                else { return }
                definition.applyGeneratedStorage(storage)
            case .name, .primaryKey, .nullable, .generationExpression, .comment,
                    .none:
                return
            }
            items[row].definition = definition
            content = .columns(items)
            updateColumn(rowID, definition)
            if beginsCustomEditing {
                tableView?.reloadData()
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.beginCustomTextEditing(
                        rowID: rowID,
                        dataIndex: dataIndex
                    )
                }
                return
            }
        case var .indexes(items):
            guard let row = items.firstIndex(where: { $0.id == rowID }) else {
                return
            }
            var definition = items[row].definition
            switch fields[dataIndex].indexField {
            case .kind:
                guard let kind = WorkspaceDatabaseSchemaEditorState.IndexKind(
                    rawValue: value
                ) else { return }
                let wasPrimary = definition.kind == .primary
                definition.kind = kind
                if kind == .primary {
                    definition.name = "PRIMARY"
                } else if wasPrimary && definition.name == "PRIMARY" {
                    definition.name = ""
                }
            case .method:
                definition.method = value
            case .name, .columns, .visible, .comment, .none:
                return
            }
            items[row].definition = definition
            content = .indexes(items)
            updateIndex(rowID, definition)
        }
        tableView?.reloadData()
    }

    private func beginCustomTextEditing(rowID: UUID, dataIndex: Int) {
        guard
            let tableView,
            let row = content.rowIDs.firstIndex(of: rowID),
            let tableColumnIndex = tableView.tableColumns.firstIndex(where: {
                columnIndexes[$0.identifier] == dataIndex
            })
        else {
            return
        }
        beginTextEditing(
            row: row,
            dataIndex: dataIndex,
            tableColumnIndex: tableColumnIndex
        )
    }

    private func toggleBoolean(row: Int, dataIndex: Int) {
        guard
            let rowID = rowID(at: row),
            fields.indices.contains(dataIndex)
        else { return }
        switch content {
        case var .columns(items):
            guard items.indices.contains(row) else { return }
            if fields[dataIndex].columnField == .primaryKey {
                let isEnabled = !primaryKeyColumnIDs.contains(rowID)
                if isEnabled {
                    primaryKeyColumnIDs.insert(rowID)
                } else {
                    primaryKeyColumnIDs.remove(rowID)
                }
                setPrimaryKey(rowID, isEnabled)
                tableView?.reloadData()
                return
            }
            var definition = items[row].definition
            switch fields[dataIndex].columnField {
            case .nullable:
                definition.isNullable.toggle()
            case .automaticValue:
                definition.isAutoIncrement.toggle()
            case .name, .type, .characterSet, .collation, .primaryKey,
                    .defaultValue, .generatedStorage, .generationExpression,
                    .comment, .none:
                return
            }
            items[row].definition = definition
            content = .columns(items)
            updateColumn(rowID, definition)
        case var .indexes(items):
            guard
                items.indices.contains(row),
                fields[dataIndex].indexField == .visible
            else { return }
            var definition = items[row].definition
            definition.isVisible.toggle()
            items[row].definition = definition
            content = .indexes(items)
            updateIndex(rowID, definition)
        }
        tableView?.reloadData()
    }

    private func commitText(rowID: UUID, dataIndex: Int, text: String) {
        guard fields.indices.contains(dataIndex) else { return }
        switch content {
        case var .columns(items):
            guard let row = items.firstIndex(where: { $0.id == rowID }) else {
                return
            }
            var definition = items[row].definition
            switch fields[dataIndex].columnField {
            case .name: definition.name = text
            case .type: definition.type = text
            case .characterSet:
                definition.applyCharacterSet(text, choices: schemaChoices)
            case .collation:
                definition.applyCollation(text, choices: schemaChoices)
            case .defaultValue:
                if definition.defaultMode == .none
                    || definition.defaultMode == .null
                {
                    definition.defaultMode = .value
                }
                definition.defaultValue = text
            case .automaticValue: definition.applyExtraDisplayValue(text)
            case .generationExpression: definition.generationExpression = text
            case .comment: definition.comment = text
            case .primaryKey, .nullable, .generatedStorage, .none: return
            }
            items[row].definition = definition
            content = .columns(items)
            updateColumn(rowID, definition)
        case var .indexes(items):
            guard let row = items.firstIndex(where: { $0.id == rowID }) else {
                return
            }
            var definition = items[row].definition
            switch fields[dataIndex].indexField {
            case .name:
                definition.name = text
            case .method:
                definition.method = text
            case .comment:
                definition.comment = text
            case .kind, .columns, .visible, .none:
                return
            }
            items[row].definition = definition
            content = .indexes(items)
            updateIndex(rowID, definition)
        }
        tableView?.reloadData()
    }

    private func editingText(row: Int, dataIndex: Int) -> String? {
        guard fields.indices.contains(dataIndex) else { return nil }
        switch content {
        case let .columns(items):
            guard items.indices.contains(row) else { return nil }
            let definition = items[row].definition
            return switch fields[dataIndex].columnField {
            case .name: definition.name
            case .type: definition.type
            case .characterSet: definition.characterSet
            case .collation: definition.collation
            case .defaultValue: definition.defaultValue
            case .automaticValue: definition.extraDisplayValue
            case .generationExpression: definition.generationExpression
            case .comment: definition.comment
            case .primaryKey, .nullable, .generatedStorage, .none: nil
            }
        case let .indexes(items):
            guard items.indices.contains(row) else { return nil }
            let definition = items[row].definition
            return switch fields[dataIndex].indexField {
            case .name: definition.name
            case .method: definition.method
            case .comment: definition.comment
            case .kind, .columns, .visible, .none: nil
            }
        }
    }

    private func defaultMode(
        at row: Int
    ) -> WorkspaceDatabaseSchemaEditorState.DefaultMode? {
        guard case let .columns(items) = content, items.indices.contains(row)
        else { return nil }
        return items[row].definition.defaultMode
    }

    private func columnDefinition(
        at row: Int
    ) -> WorkspaceDatabaseSchemaEditorState.ColumnDefinition? {
        guard case let .columns(items) = content, items.indices.contains(row)
        else { return nil }
        return items[row].definition
    }

    private func formatIndexColumns(
        _ columns: [WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition]
    ) -> String {
        columns.map { column in
            var value = column.name
            if descriptor.supportsIndexPrefixLength,
               !column.prefixLength.isEmpty {
                value += "(\(column.prefixLength))"
            }
            if descriptor.supportsIndexDirection, column.isDescending {
                value += " DESC"
            }
            return value
        }.joined(separator: ", ")
    }

    private var indexKindOptions: [WorkspaceDatabaseSchemaOptionPicker.Option] {
        descriptor.indexKinds.map { kind in
            let title = WorkspaceDatabaseSchemaChoiceCatalog.indexKinds
                .first(where: { $0.value == kind.rawValue })?.title
                ?? kind.rawValue
            return .init(value: kind.rawValue, title: title)
        }
    }

    private func columnDisplayValue(
        _ field: WorkspaceDatabaseSchemaEditingDescriptor.ColumnField,
        definition: WorkspaceDatabaseSchemaEditorState.ColumnDefinition,
        isPrimaryKey: Bool
    ) -> String {
        switch field {
        case .name:
            definition.name
        case .type:
            definition.type
        case .characterSet:
            definition.supportsCharacterSetAndCollation
                ? (definition.characterSet.isEmpty ? "default" : definition.characterSet)
                : ""
        case .collation:
            definition.supportsCharacterSetAndCollation
                ? (definition.collation.isEmpty ? "default" : definition.collation)
                : ""
        case .primaryKey, .nullable:
            ""
        case .defaultValue:
            if definition.isGenerated {
                "EMPTY"
            } else {
                switch definition.defaultMode {
                case .none: "EMPTY"
                case .null: "NULL"
                case .value, .expression:
                    definition.defaultValue.isEmpty ? "''" : definition.defaultValue
                }
            }
        case .automaticValue:
            descriptor.automaticValueStyle == .identity
                ? ""
                : (definition.extraDisplayValue.isEmpty
                    ? "NONE"
                    : definition.extraDisplayValue)
        case .generatedStorage:
            definition.isGenerated ? definition.generatedStorage.rawValue : ""
        case .generationExpression:
            definition.generationExpression
        case .comment:
            definition.comment
        }
    }

    private func indexDisplayValue(
        _ field: WorkspaceDatabaseSchemaEditingDescriptor.IndexField,
        definition: WorkspaceDatabaseSchemaEditorState.IndexDefinition
    ) -> String {
        switch field {
        case .name:
            definition.name
        case .kind:
            indexKindOptions.first(where: {
                $0.value == definition.kind.rawValue
            })?.title ?? definition.kind.rawValue
        case .columns:
            formatIndexColumns(definition.columns)
        case .method:
            definition.method
        case .visible:
            ""
        case .comment:
            definition.comment
        }
    }

    private func rowPresentation(
        at row: Int
    ) -> WorkspaceDatabaseSchemaGridRowPresentation? {
        switch content {
        case let .columns(items):
            guard items.indices.contains(row) else { return nil }
            let item = items[row]
            let definition = item.definition
            let supportsCharacterOptions =
                definition.supportsCharacterSetAndCollation
            let isPrimaryKey = primaryKeyColumnIDs.contains(item.id)
            let canEditItem = isEditable && !item.isDeleted && item.isEditable
            var editableIndexes = canEditItem ? Set(fields.indices) : []
            for (index, field) in fields.enumerated() {
                guard let columnField = field.columnField else { continue }
                if definition.isGenerated,
                   [.nullable, .defaultValue, .automaticValue].contains(columnField)
                {
                    editableIndexes.remove(index)
                }
                if !definition.isGenerated, columnField == .generationExpression {
                    editableIndexes.remove(index)
                }
                if isPrimaryKey, columnField == .nullable {
                    editableIndexes.remove(index)
                }
                if !supportsCharacterOptions,
                   columnField == .characterSet || columnField == .collation
                {
                    editableIndexes.remove(index)
                }
                if !item.isNew
                    && !descriptor.supportsAlteringGeneratedColumns
                    && (columnField == .generatedStorage
                        || columnField == .generationExpression)
                {
                    editableIndexes.remove(index)
                }
            }
            var booleanValues: [Int: Bool] = [:]
            var placeholderIndexes = Set<Int>()
            var optionIndexes = Set<Int>()
            for (index, field) in fields.enumerated() {
                switch field.columnField {
                case .primaryKey:
                    booleanValues[index] = isPrimaryKey
                case .nullable:
                    booleanValues[index] = definition.isNullable
                case .automaticValue where descriptor.automaticValueStyle == .identity:
                    booleanValues[index] = definition.isAutoIncrement
                case .characterSet where definition.characterSet.isEmpty:
                    placeholderIndexes.insert(index)
                case .collation where definition.collation.isEmpty:
                    placeholderIndexes.insert(index)
                case .defaultValue
                    where definition.defaultMode == .none
                        || definition.defaultMode == .null:
                    placeholderIndexes.insert(index)
                case .automaticValue
                    where descriptor.automaticValueStyle == .autoIncrement
                        && definition.extraDisplayValue.isEmpty:
                    placeholderIndexes.insert(index)
                case .generatedStorage where !definition.isGenerated,
                        .generationExpression where !definition.isGenerated:
                    placeholderIndexes.insert(index)
                default:
                    break
                }
                switch field.editing {
                case .options, .defaultValue, .indexColumns:
                    optionIndexes.insert(index)
                case .text, .boolean:
                    break
                }
            }
            return WorkspaceDatabaseSchemaGridRowPresentation(
                id: item.id,
                values: fields.compactMap(\.columnField).map {
                    columnDisplayValue(
                        $0,
                        definition: definition,
                        isPrimaryKey: isPrimaryKey
                    )
                },
                booleanValues: booleanValues,
                placeholderIndexes: placeholderIndexes,
                optionIndexes: optionIndexes,
                editableIndexes: editableIndexes,
                changeState: changeState(
                    isNew: item.isNew,
                    isModified: item.isModified,
                    isDeleted: item.isDeleted
                )
            )
        case let .indexes(items):
            guard items.indices.contains(row) else { return nil }
            let item = items[row]
            let definition = item.definition
            var editableIndexes = isEditable && !item.isDeleted
                ? Set(fields.indices)
                : []
            for (index, field) in fields.enumerated() {
                if definition.kind == .primary, field.indexField == .name {
                    editableIndexes.remove(index)
                }
                if definition.kind == .fulltext || definition.kind == .spatial,
                   field.indexField == .method
                {
                    editableIndexes.remove(index)
                }
            }
            var booleanValues: [Int: Bool] = [:]
            var optionIndexes = Set<Int>()
            for (index, field) in fields.enumerated() {
                if field.indexField == .visible {
                    booleanValues[index] = definition.isVisible
                }
                switch field.editing {
                case .options, .defaultValue, .indexColumns:
                    optionIndexes.insert(index)
                case .text, .boolean:
                    break
                }
            }
            return WorkspaceDatabaseSchemaGridRowPresentation(
                id: item.id,
                values: fields.compactMap(\.indexField).map {
                    indexDisplayValue($0, definition: definition)
                },
                booleanValues: booleanValues,
                placeholderIndexes: [],
                optionIndexes: optionIndexes,
                editableIndexes: editableIndexes,
                changeState: changeState(
                    isNew: item.isNew,
                    isModified: item.isModified,
                    isDeleted: item.isDeleted
                )
            )
        }
    }

    private func changeState(
        isNew: Bool,
        isModified: Bool,
        isDeleted: Bool
    ) -> WorkspaceDatabaseSchemaGridRowPresentation.ChangeState {
        if isDeleted { return .deleted }
        if isNew { return .inserted }
        if isModified { return .modified }
        return .unchanged
    }

    private func copyRow(at row: Int) -> WorkspaceDatabaseDataRow? {
        switch content {
        case let .columns(items):
            guard items.indices.contains(row) else { return nil }
            let item = items[row]
            let definition = item.definition
            return WorkspaceDatabaseDataRow(
                id: row,
                values: fields.compactMap(\.columnField).map { field in
                    let value: String = switch field {
                    case .primaryKey:
                        primaryKeyColumnIDs.contains(item.id) ? "1" : "0"
                    case .nullable:
                        definition.isNullable ? "1" : "0"
                    case .automaticValue
                        where descriptor.automaticValueStyle == .identity:
                        definition.isAutoIncrement ? "1" : "0"
                    case .defaultValue:
                        switch definition.defaultMode {
                        case .none: ""
                        case .null: "NULL"
                        case .value, .expression: definition.defaultValue
                        }
                    default:
                        columnDisplayValue(
                            field,
                            definition: definition,
                            isPrimaryKey: primaryKeyColumnIDs.contains(item.id)
                        )
                    }
                    return .text(value)
                }
            )
        case let .indexes(items):
            guard items.indices.contains(row) else { return nil }
            let definition = items[row].definition
            return WorkspaceDatabaseDataRow(
                id: row,
                values: fields.compactMap(\.indexField).map { field in
                    .text(
                        field == .visible
                            ? (definition.isVisible ? "1" : "0")
                            : indexDisplayValue(field, definition: definition)
                    )
                }
            )
        }
    }
}

extension WorkspaceDatabaseSchemaGridCoordinator:
    NSTableViewDataSource,
    NSTableViewDelegate
{
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { content.count }
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
            guard let presentation = rowPresentation(at: row) else { return nil }
            let rowView: WorkspaceDatabaseSchemaRowView
            if let reused = tableView.makeView(
                withIdentifier: Self.rowViewIdentifier,
                owner: self
            ) as? WorkspaceDatabaseSchemaRowView {
                rowView = reused
            } else {
                rowView = WorkspaceDatabaseSchemaRowView()
                rowView.identifier = Self.rowViewIdentifier
            }
            rowView.configure(
                tableView: tableView,
                presentation: presentation,
                rowIndex: row,
                columnIndexes: columnIndexes,
                statusIdentifier: Self.statusIdentifier,
                accessibilityPrefix: accessibilityIdentifier
            )
            return rowView
        }
    }
}

extension WorkspaceDatabaseSchemaGridCoordinator:
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
        let rows = (0..<content.count).compactMap(copyRow(at:))
        return WorkspaceGridCopySnapshot { row in
            guard rows.indices.contains(row) else { return nil }
            return rows[row]
        }
    }
}

extension WorkspaceDatabaseSchemaGridCoordinator: NSTextFieldDelegate {
    nonisolated func controlTextDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let editor = inlineEditor else { return }
            inlineEditingText = editor.currentEditor()?.string
                ?? editor.stringValue
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
                finishInlineEditing(commit: true, movingBy: 1)
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
