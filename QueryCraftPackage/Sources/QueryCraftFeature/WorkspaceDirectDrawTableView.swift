import AppKit
import QuartzCore
import SwiftUI

final class WorkspaceGridViewportClipView: NSClipView {
    override func layout() {
        super.layout()
        guard let tableView = documentView as? NSTableView else { return }
        let naturalWidth = tableView.tableColumns.indices.last.map {
            tableView.rect(ofColumn: $0).maxX
        } ?? 0
        let targetWidth = Self.documentWidth(
            viewportWidth: bounds.width,
            naturalContentWidth: naturalWidth
        )
        guard abs(tableView.frame.width - targetWidth) >= 0.5 else { return }
        tableView.setFrameSize(
            NSSize(width: targetWidth, height: tableView.frame.height)
        )
    }

    static func documentWidth(
        viewportWidth: CGFloat,
        naturalContentWidth: CGFloat
    ) -> CGFloat {
        max(viewportWidth, naturalContentWidth)
    }
}

@MainActor
protocol WorkspaceDirectDrawTableViewDataSource: AnyObject {
    func workspaceTableView(
        _ tableView: WorkspaceDirectDrawTableView,
        dataColumnIndexFor identifier: NSUserInterfaceItemIdentifier
    ) -> Int?

    func workspaceTableViewCopySnapshot(
        _ tableView: WorkspaceDirectDrawTableView
    ) -> WorkspaceGridCopySnapshot

    func workspaceTableView(
        _ tableView: WorkspaceDirectDrawTableView,
        dataExportSourceFor rows: WorkspaceGridCopyRows
    ) -> (any WorkspaceDataExportRowSource)?
}

extension WorkspaceDirectDrawTableViewDataSource {
    func workspaceTableView(
        _ tableView: WorkspaceDirectDrawTableView,
        dataExportSourceFor rows: WorkspaceGridCopyRows
    ) -> (any WorkspaceDataExportRowSource)? {
        nil
    }
}

final class WorkspaceDirectDrawTableView: NSTableView {
    private static let immediateCopyCellLimit = 10_000
    private static let columnReorderAnimationDuration: TimeInterval = 0.14

    weak var workspaceDataSource:
        (any WorkspaceDirectDrawTableViewDataSource)?
    var rowNumberIdentifier: NSUserInterfaceItemIdentifier?
    var copyPasteboard = NSPasteboard.general
    var nullDisplayText = "NULL"
    var emptyStringDisplayText = ""
    var copyIncludesColumnNames = false
    weak var dataExportController: WorkspaceDataExportController?
    weak var gridSearchController: WorkspaceGridSearchController?
    var gridSearchPresentationActions: WorkspaceGridSearchCommandActions?
    var cellEditHandler: ((Int, Int) -> Void)?
    var canEditCellHandler: ((Int, Int) -> Bool)?
    var singleClickCellHandler: ((Int, Int) -> Bool)?
    var auxiliaryCellSingleClickHandler: ((Int, Int) -> Bool)?
    var cellTypingHandler: ((Int, Int, String) -> Bool)?
    var cellContextMenuProvider: ((Int, Int) -> NSMenu?)?
    var cellValueMutationMenuItemsProvider: ((Int, Int) -> [NSMenuItem])?
    var additionalCellContextMenuItemsProvider: ((Int, Int) -> [NSMenuItem])?
    var rowInsertSubmitHandler: (() -> Void)?
    var addDataRowHandler: (() -> Void)?
    var duplicateDataRowHandler: ((Int) -> Void)?
    var deleteDataRowsHandler: ((IndexSet) -> Void)?
    var pasteDataRowsHandler: ((WorkspaceGridPasteboardContent, Int, Int?) -> Void)?
    var canDuplicateDataRowHandler: ((Int) -> Bool)?
    var canDeleteDataRowsHandler: ((IndexSet) -> Bool)?
    var selectedDataRowsChanged: ((IndexSet) -> Void)?
    var inlineEditorLayoutHandler: (() -> Void)?

    private(set) var gridSelection = WorkspaceGridSelection.empty
    private(set) var suppressedActiveCellIndicator:
        WorkspaceGridCoordinate?
    private var lastGridSelectedRow: Int?
    private(set) var draggedColumnIdentifier:
        NSUserInterfaceItemIdentifier?
    private var backgroundCopyTask: Task<String?, Never>?
    private var fullCellValuePopover: NSPopover?
    private var copyGeneration = UUID()
    private var columnDragOverlay: WorkspaceColumnSnapshotView?
    private var columnDragOverlayOriginX: CGFloat?
    private var preparedDraggedColumnIdentifier:
        NSUserInterfaceItemIdentifier?
    private var columnPositions:
        [NSUserInterfaceItemIdentifier: CGFloat] = [:]
    private var columnTransitionOverlay: WorkspaceColumnSnapshotView?
    private(set) var transitionHiddenColumnIdentifiers:
        Set<NSUserInterfaceItemIdentifier> = []
    private var pendingSelectionAnnouncement: WorkspaceGridSelection?
    private var isSelectionAnnouncementScheduled = false

    override var acceptsFirstResponder: Bool { true }

    static func visibleSearchTarget(
        in window: NSWindow?
    ) -> WorkspaceDirectDrawTableView? {
        guard let window, let contentView = window.contentView else {
            return nil
        }
        return visibleSearchTarget(in: contentView, window: window)
    }

    private static func visibleSearchTarget(
        in view: NSView,
        window: NSWindow
    ) -> WorkspaceDirectDrawTableView? {
        guard
            view.window === window,
            !view.isHiddenOrHasHiddenAncestor
        else {
            return nil
        }
        if let tableView = view as? WorkspaceDirectDrawTableView,
           !tableView.visibleRect.isEmpty,
           tableView.canFindInData
        {
            return tableView
        }
        for subview in view.subviews.reversed() {
            if let target = visibleSearchTarget(
                in: subview,
                window: window
            ) {
                return target
            }
        }
        return nil
    }

    deinit {
        backgroundCopyTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            fullCellValuePopover?.close()
            fullCellValuePopover = nil
        }
    }

    override func tile() {
        super.tile()
        WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: self)
        inlineEditorLayoutHandler?()
    }

    func suppressActiveCellIndicator(
        at coordinate: WorkspaceGridCoordinate?
    ) {
        guard suppressedActiveCellIndicator != coordinate else { return }
        let affectedRows = Set(
            [suppressedActiveCellIndicator?.row, coordinate?.row].compactMap {
                $0
            }
        )
        suppressedActiveCellIndicator = coordinate
        for row in affectedRows where row >= 0 && row < numberOfRows {
            rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedColumn = column(at: point)
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        guard clickedRow >= 0 else {
            clearGridSelection()
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        if event.clickCount == 1,
           modifiers.isEmpty,
           auxiliaryCellSingleClickHandler?(clickedRow, clickedColumn) == true
        {
            return
        }
        if isRowNumberColumn(clickedColumn) {
            selectGridRow(
                clickedRow,
                extending: modifiers.contains(.shift),
                toggling: modifiers.contains(.command)
            )
            return
        }
        guard isDataColumn(clickedColumn) else {
            selectGridRow(
                clickedRow,
                extending: modifiers.contains(.shift),
                toggling: modifiers.contains(.command)
            )
            return
        }
        if modifiers.contains(.command) {
            selectGridRow(clickedRow, extending: false, toggling: true)
            return
        }

        deselectAll(nil)
        let coordinate = WorkspaceGridCoordinate(
            row: clickedRow,
            column: clickedColumn
        )
        if modifiers.contains(.shift) {
            updateGridSelection(gridSelection.extending(to: coordinate))
        } else {
            updateGridSelection(.cell(coordinate))
        }
        if event.clickCount == 1,
           modifiers.isEmpty,
           singleClickCellHandler?(clickedRow, clickedColumn) == true
        {
            return
        }
        if event.clickCount == 2,
           modifiers.isEmpty
        {
            if cellEditHandler != nil, canEditCellHandler?(clickedRow, clickedColumn) != false {
                requestCellEdit(row: clickedRow, column: clickedColumn)
                return
            }
            if showFullCellValue(row: clickedRow, column: clickedColumn) { return }
        }
        trackSelectionDrag()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        let shortcutModifiers = modifiers.intersection([
            .command,
            .control,
            .option,
            .shift,
        ])
        if shortcutModifiers == .command,
           event.matchesWorkspaceShortcut(keyCode: 3, character: "f"),
           canFindInData
        {
            findInData(nil)
            return
        }
        if shortcutModifiers == .command,
           event.matchesWorkspaceShortcut(keyCode: 34, character: "i"),
           let addDataRowHandler
        {
            addDataRowHandler()
            return
        }
        if shortcutModifiers == .command,
           event.matchesWorkspaceShortcut(keyCode: 2, character: "d"),
           let row = singleSelectedRow,
           canDuplicateDataRowHandler?(row) == true,
           let duplicateDataRowHandler
        {
            duplicateDataRowHandler(row)
            return
        }
        if shortcutModifiers.isEmpty,
           [51, 117].contains(event.keyCode),
           !selectedDataRows.isEmpty,
           canDeleteDataRowsHandler?(selectedDataRows) == true,
           let deleteDataRowsHandler
        {
            deleteDataRowsHandler(selectedDataRows)
            return
        }
        if shortcutModifiers == .command,
           [36, 76].contains(event.keyCode),
           rowInsertSubmitHandler != nil
        {
            rowInsertSubmitHandler?()
            return
        }
        if shortcutModifiers.isEmpty,
           [36, 76].contains(event.keyCode),
           gridSelection.cellCount == 1,
           let active = gridSelection.active,
           cellEditHandler != nil
        {
            requestCellEdit(row: active.row, column: active.column)
            return
        }

        let direction: WorkspaceGridDirection? = switch event.keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
        if let direction {
            if gridSelection.active == nil,
               shortcutModifiers.isEmpty,
               direction == .up || direction == .down,
               let originRow = lastGridSelectedRow,
               let firstColumn = dataTableColumnIndexes.first,
               numberOfRows > 0
            {
                let rowOffset = direction == .up ? -1 : 1
                let target = WorkspaceGridCoordinate(
                    row: min(max(0, originRow + rowOffset), numberOfRows - 1),
                    column: firstColumn
                )
                updateGridSelection(.cell(target))
                scrollRowToVisible(target.row)
                scrollColumnToVisible(target.column)
                return
            }

            guard let active = gridSelection.active else {
                super.keyDown(with: event)
                return
            }

            let target = movedCoordinate(
                from: active,
                direction: direction,
                toEdge: modifiers.contains(.command)
            )
            deselectAll(nil)
            if modifiers.contains(.shift) {
                updateGridSelection(gridSelection.extending(to: target))
            } else {
                updateGridSelection(.cell(target))
            }
            scrollRowToVisible(target.row)
            scrollColumnToVisible(target.column)
            return
        }

        if shortcutModifiers.isEmpty,
           let active = gridSelection.active,
           let characters = event.characters,
           isDirectTextEntry(characters),
           cellTypingHandler?(active.row, active.column, characters) == true
        {
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        copyCurrentSelection(
            includesColumnNames: copyIncludesColumnNames
        )
    }

    @objc func copyWithColumnNames(_ sender: Any?) {
        copyCurrentSelection(includesColumnNames: true)
    }

    @objc func paste(_ sender: Any?) {
        guard
            let pasteDataRowsHandler,
            let firstDataColumn = dataTableColumnIndexes.first
        else {
            NSSound.beep()
            return
        }
        let active = gridSelection.active
        let startingColumn = active.map(\.column) ?? firstDataColumn
        pasteDataRowsHandler(
            WorkspaceGridPasteboardContent.read(from: copyPasteboard),
            startingColumn,
            active?.row
        )
    }

    func copyRow(at row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        writeCopy(
            rows: .indexes(IndexSet(integer: row)),
            columns: dataTableColumnIndexes.compactMap(copyColumn(at:)),
            includesColumnNames: false
        )
    }

    @objc func findInData(_ sender: Any?) {
        if let gridSearchPresentationActions {
            gridSearchPresentationActions.search()
        } else {
            gridSearchController?.present()
        }
    }

    @objc func copyColumn(_ sender: NSMenuItem) {
        copyColumn(from: sender, includesColumnName: false)
    }

    @objc func copyColumnWithName(_ sender: NSMenuItem) {
        copyColumn(from: sender, includesColumnName: true)
    }

    override func selectAll(_ sender: Any?) {
        guard
            numberOfRows > 0,
            let firstColumn = dataTableColumnIndexes.first,
            let lastColumn = dataTableColumnIndexes.last
        else {
            super.selectAll(sender)
            return
        }
        deselectAll(nil)
        updateGridSelection(
            WorkspaceGridSelection(
                anchor: WorkspaceGridCoordinate(row: 0, column: firstColumn),
                active: WorkspaceGridCoordinate(
                    row: numberOfRows - 1,
                    column: lastColumn
                )
            )
        )
    }

    override func cancelOperation(_ sender: Any?) {
        if gridSearchPresentationActions?.isPresented?() == true {
            gridSearchPresentationActions?.dismiss?()
            return
        }
        if gridSearchController?.isPresented == true {
            gridSearchController?.dismiss()
            return
        }
        guard !gridSelection.isEmpty else {
            super.cancelOperation(sender)
            return
        }
        clearGridSelection()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedColumn = column(at: point)
        guard clickedRow >= 0, isDataColumn(clickedColumn) else {
            return super.menu(for: event)
        }

        window?.makeFirstResponder(self)
        if !gridSelection.contains(row: clickedRow, column: clickedColumn) {
            deselectAll(nil)
            updateGridSelection(
                .cell(
                    WorkspaceGridCoordinate(
                        row: clickedRow,
                        column: clickedColumn
                    )
                )
            )
        }

        if let menu = cellContextMenuProvider?(clickedRow, clickedColumn) {
            return menu
        }

        let menu = NSMenu()
        if fullCellText(row: clickedRow, column: clickedColumn) != nil {
            let viewItem = NSMenuItem(
                title: AppCopy.current.viewFullCellContent,
                action: #selector(viewFullCellFromMenu(_:)), keyEquivalent: ""
            )
            viewItem.target = self
            viewItem.representedObject = NSValue(point: NSPoint(x: clickedColumn, y: clickedRow))
            menu.addItem(viewItem)
        }
        if cellEditHandler != nil {
            let editItem = NSMenuItem(
                title: AppCopy.current.text(
                    "编辑单元格…",
                    "Edit Cell..."
                ),
                action: #selector(editCell(_:)),
                keyEquivalent: ""
            )
            editItem.target = self
            editItem.isEnabled = canEditCellHandler?(
                clickedRow,
                clickedColumn
            ) ?? true
            editItem.representedObject = NSValue(
                point: NSPoint(x: clickedColumn, y: clickedRow)
            )
            menu.addItem(editItem)
        }
        cellValueMutationMenuItemsProvider?(clickedRow, clickedColumn)
            .forEach(menu.addItem)
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let copyItem = NSMenuItem(
            title: AppCopy.current.text("复制", "Copy"),
            action: #selector(copyFromContextMenu(_:)),
            keyEquivalent: "c"
        )
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = self
        menu.addItem(copyItem)

        let copyWithNamesItem = NSMenuItem(
            title: AppCopy.current.text(
                "复制并包含列名",
                "Copy with Column Names"
            ),
            action: #selector(copyWithColumnNames(_:)),
            keyEquivalent: ""
        )
        copyWithNamesItem.target = self
        menu.addItem(copyWithNamesItem)
        if dataExportController != nil {
            menu.addItem(.separator())
            let exportItem = NSMenuItem(
                title: AppCopy.current.text(
                    "导出所选内容…",
                    "Export Selection..."
                ),
                action: #selector(exportSelection(_:)),
                keyEquivalent: ""
            )
            exportItem.target = self
            menu.addItem(exportItem)
        }
        let additionalItems = additionalCellContextMenuItemsProvider?(
            clickedRow,
            clickedColumn
        ) ?? []
        if !additionalItems.isEmpty {
            menu.addItem(.separator())
            additionalItems.forEach(menu.addItem)
        }
        return menu
    }

    @objc private func copyFromContextMenu(_ sender: Any?) {
        copy(sender)
    }

    @objc private func exportSelection(_ sender: Any?) {
        dataExportController?.presentOptions(defaultScope: .selection)
    }

    @objc private func editCell(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? NSValue else { return }
        let point = location.pointValue
        requestCellEdit(row: Int(point.y), column: Int(point.x))
    }

    func fullCellText(row: Int, column: Int) -> String? {
        guard row >= 0, row < numberOfRows,
              let dataColumn = copyColumn(at: column),
              let source = workspaceDataSource,
              let value = source.workspaceTableViewCopySnapshot(self).rowAt(row)?.value(at: dataColumn.dataIndex),
              value.textExceeds(characterCount: WorkspaceDatabaseDataRowView.maximumDrawnTextCharacters),
              case .text(let text) = value else { return nil }
        return text
    }

    @objc private func viewFullCellFromMenu(_ sender: NSMenuItem) {
        guard let point = (sender.representedObject as? NSValue)?.pointValue else { return }
        _ = showFullCellValue(row: Int(point.y), column: Int(point.x))
    }

    @discardableResult
    private func showFullCellValue(row: Int, column: Int) -> Bool {
        guard let text = fullCellText(row: row, column: column),
              let name = copyColumn(at: column)?.name else { return false }
        fullCellValuePopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 560, height: 360)
        popover.contentViewController = NSHostingController(rootView:
            WorkspaceReadOnlyTextView(text: text, usesMonospacedFont: false,
                accessibilityLabel: AppCopy.current.text("\(name)，完整内容", "\(name), full content"),
                showsBorder: false, presentation: .automaticJSON)
        )
        fullCellValuePopover = popover
        popover.show(relativeTo: frameOfCell(atColumn: column, row: row), of: self, preferredEdge: .maxY)
        return true
    }

    override func validateUserInterfaceItem(
        _ item: NSValidatedUserInterfaceItem
    ) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(copyWithColumnNames(_:)):
            !gridSelection.isEmpty || !selectedRowIndexes.isEmpty
        case #selector(findInData(_:)):
            canFindInData
        case #selector(paste(_:)):
            pasteDataRowsHandler != nil
                && copyPasteboard.availableType(from: [
                    WorkspaceGridClipboardPayload.pasteboardType,
                    WorkspaceGridClipboardEncoder.tabSeparatedTextType,
                    .string,
                ]) != nil
        case #selector(selectAll(_:)):
            numberOfRows > 0 && !dataTableColumnIndexes.isEmpty
        default:
            super.validateUserInterfaceItem(item)
        }
    }

    private var canFindInData: Bool {
        gridSearchPresentationActions != nil
            || gridSearchController?.canSearch == true
    }

    func clearGridSelection() {
        let hadGridSelection = !gridSelection.isEmpty
        let hadRowSelection = !selectedRowIndexes.isEmpty
        guard hadGridSelection || hadRowSelection else { return }
        deselectAll(nil)
        if hadGridSelection {
            updateGridSelection(.empty)
        } else {
            selectedDataRowsChanged?(IndexSet())
            WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: self)
        }
    }

    func dataExportSnapshot() -> WorkspaceDataExportSnapshot? {
        guard
            numberOfRows > 0,
            let workspaceDataSource
        else {
            return nil
        }
        let allColumns = dataTableColumnIndexes.compactMap(copyColumn(at:))
        guard !allColumns.isEmpty else { return nil }

        let selectedRows: WorkspaceGridCopyRows?
        let selectedColumns: [WorkspaceGridCopyColumn]?
        if let gridRows = gridSelection.rows,
           let gridColumns = gridSelection.columns
        {
            selectedRows = .range(gridRows)
            selectedColumns = gridColumns.compactMap(copyColumn(at:))
        } else if !selectedRowIndexes.isEmpty {
            selectedRows = .indexes(selectedRowIndexes)
            selectedColumns = allColumns
        } else {
            selectedRows = nil
            selectedColumns = nil
        }
        let allRows = WorkspaceGridCopyRows.range(0...(numberOfRows - 1))
        let snapshot = workspaceDataSource.workspaceTableViewCopySnapshot(self)
        return WorkspaceDataExportSnapshot(
            allRows: allRows,
            allColumns: allColumns,
            selectedRows: selectedRows,
            selectedColumns: selectedColumns,
            rowAt: snapshot.rowAt,
            allRowsSource: workspaceDataSource.workspaceTableView(
                self,
                dataExportSourceFor: allRows
            ),
            selectedRowsSource: selectedRows.flatMap {
                workspaceDataSource.workspaceTableView(
                    self,
                    dataExportSourceFor: $0
                )
            }
        )
    }

    func selectGridRange(
        anchor: WorkspaceGridCoordinate,
        active: WorkspaceGridCoordinate
    ) {
        deselectAll(nil)
        updateGridSelection(
            WorkspaceGridSelection(anchor: anchor, active: active)
        )
    }

    func copyColumn(
        identifiedBy identifier: NSUserInterfaceItemIdentifier,
        includesColumnName: Bool
    ) {
        guard
            numberOfRows > 0,
            let tableColumnIndex = tableColumns.firstIndex(where: {
                $0.identifier == identifier
            }),
            let column = copyColumn(at: tableColumnIndex)
        else {
            return
        }
        writeCopy(
            rows: .range(0...(numberOfRows - 1)),
            columns: [column],
            includesColumnNames: includesColumnName
        )
    }

    func updateColumnDragVisual(
        column tableColumnIndex: Int,
        distance: CGFloat
    ) {
        if columnDragOverlay == nil {
            beginColumnDragVisual(column: tableColumnIndex)
        }
        guard
            let overlay = columnDragOverlay,
            let originX = columnDragOverlayOriginX
        else {
            return
        }
        var frame = overlay.frame
        frame.origin.x = originX + distance
        overlay.frame = frame
    }

    func prepareColumnDragVisual(column tableColumnIndex: Int) {
        guard
            tableColumns.indices.contains(tableColumnIndex),
            tableColumns[tableColumnIndex].identifier
                != rowNumberIdentifier
        else {
            return
        }
        finishColumnTransitionAnimation()
        preparedDraggedColumnIdentifier =
            tableColumns[tableColumnIndex].identifier
        columnPositions = currentColumnPositions
    }

    func animateColumnsAfterReordering() {
        let currentPositions = currentColumnPositions
        guard !columnPositions.isEmpty else {
            columnPositions = currentPositions
            WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: self)
            return
        }

        let draggedIdentifier =
            draggedColumnIdentifier ?? preparedDraggedColumnIdentifier
        let transition = WorkspaceGridColumnTransition.make(
            previousPositions: columnPositions,
            currentPositions: currentPositions,
            excluding: draggedIdentifier
        )
        columnPositions = currentPositions

        guard let transition else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            finishColumnTransitionAnimation()
            WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: self)
            return
        }
        animateColumnBand(
            identifiedBy: transition.columnIdentifiers,
            fromOffset: transition.offset
        )
    }

    func endColumnDragVisual() {
        let hadOverlay = columnDragOverlay != nil
        columnDragOverlay?.removeFromSuperview()
        columnDragOverlay = nil
        columnDragOverlayOriginX = nil
        draggedColumnIdentifier = nil
        preparedDraggedColumnIdentifier = nil
        columnPositions.removeAll(keepingCapacity: true)
        if hadOverlay {
            WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: self)
        }
    }

    private func beginColumnDragVisual(column tableColumnIndex: Int) {
        guard
            tableColumns.indices.contains(tableColumnIndex),
            tableColumns[tableColumnIndex].identifier
                != rowNumberIdentifier,
            let clipView = enclosingScrollView?.contentView
        else {
            return
        }

        let snapshotRect = rect(ofColumn: tableColumnIndex)
            .intersection(visibleRect)
        guard
            !snapshotRect.isNull,
            snapshotRect.width > 0,
            snapshotRect.height > 0,
            let bitmap = bitmapImageRepForCachingDisplay(in: snapshotRect)
        else {
            return
        }

        cacheDisplay(in: snapshotRect, to: bitmap)
        let image = NSImage(size: snapshotRect.size)
        image.addRepresentation(bitmap)

        let overlayFrame = clipView.convert(snapshotRect, from: self)
        let overlay = WorkspaceColumnSnapshotView(
            frame: overlayFrame,
            image: image,
            opacity: 0.72
        )
        clipView.addSubview(
            overlay,
            positioned: .above,
            relativeTo: self
        )
        overlay.displayIfNeeded()

        columnDragOverlay = overlay
        columnDragOverlayOriginX = overlayFrame.minX
        draggedColumnIdentifier = tableColumns[tableColumnIndex].identifier
        WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: self)
        displayIfNeeded()
    }

    private var currentColumnPositions:
        [NSUserInterfaceItemIdentifier: CGFloat] {
        Dictionary(
            uniqueKeysWithValues: tableColumns.indices.map { index in
                (
                    tableColumns[index].identifier,
                    rect(ofColumn: index).minX
                )
            }
        )
    }

    private func animateColumnBand(
        identifiedBy identifiers: Set<NSUserInterfaceItemIdentifier>,
        fromOffset: CGFloat
    ) {
        finishColumnTransitionAnimation()
        WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: self)
        displayIfNeeded()
        guard let clipView = enclosingScrollView?.contentView else { return }

        let columnIndexes = tableColumns.indices.filter {
            identifiers.contains(tableColumns[$0].identifier)
        }
        guard
            let firstIndex = columnIndexes.first,
            let lastIndex = columnIndexes.last
        else {
            return
        }
        let firstRect = rect(ofColumn: firstIndex)
        let lastRect = rect(ofColumn: lastIndex)
        let snapshotRect = NSRect(
            x: firstRect.minX,
            y: visibleRect.minY,
            width: lastRect.maxX - firstRect.minX,
            height: visibleRect.height
        ).intersection(visibleRect)
        guard
            !snapshotRect.isNull,
            snapshotRect.width > 0,
            snapshotRect.height > 0,
            let bitmap = bitmapImageRepForCachingDisplay(in: snapshotRect)
        else {
            return
        }

        cacheDisplay(in: snapshotRect, to: bitmap)
        let image = NSImage(size: snapshotRect.size)
        image.addRepresentation(bitmap)

        let targetFrame = clipView.convert(snapshotRect, from: self)
        var startFrame = targetFrame
        startFrame.origin.x += fromOffset
        let overlay = WorkspaceColumnSnapshotView(
            frame: startFrame,
            image: image,
            opacity: 1
        )
        clipView.addSubview(
            overlay,
            positioned: .above,
            relativeTo: self
        )
        columnTransitionOverlay = overlay
        transitionHiddenColumnIdentifiers = identifiers
        WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: self)
        displayIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.columnReorderAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().setFrameOrigin(targetFrame.origin)
        }
        perform(
            #selector(completeColumnTransitionAnimation(_:)),
            with: overlay,
            afterDelay: Self.columnReorderAnimationDuration,
            inModes: [.common]
        )
    }

    private func finishColumnTransitionAnimation() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(completeColumnTransitionAnimation(_:)),
            object: nil
        )
        columnTransitionOverlay?.removeFromSuperview()
        columnTransitionOverlay = nil
        guard !transitionHiddenColumnIdentifiers.isEmpty else { return }
        transitionHiddenColumnIdentifiers.removeAll(keepingCapacity: true)
        WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: self)
    }

    @objc private func completeColumnTransitionAnimation(
        _ overlay: WorkspaceColumnSnapshotView
    ) {
        guard columnTransitionOverlay === overlay else { return }
        finishColumnTransitionAnimation()
    }

    private var dataTableColumnIndexes: [Int] {
        tableColumns.indices.filter(isDataColumn)
    }

    private func isDataColumn(_ tableColumnIndex: Int) -> Bool {
        guard tableColumns.indices.contains(tableColumnIndex) else {
            return false
        }
        return tableColumns[tableColumnIndex].identifier
            != rowNumberIdentifier
    }

    private func isRowNumberColumn(_ tableColumnIndex: Int) -> Bool {
        guard tableColumns.indices.contains(tableColumnIndex) else {
            return false
        }
        return tableColumns[tableColumnIndex].identifier == rowNumberIdentifier
    }

    private func isDirectTextEntry(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        return !characters.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || (0xF700...0xF8FF).contains(scalar.value)
        }
    }

    private func selectGridRow(
        _ row: Int,
        extending: Bool,
        toggling: Bool
    ) {
        guard
            row >= 0,
            row < numberOfRows,
            let firstColumn = dataTableColumnIndexes.first,
            let lastColumn = dataTableColumnIndexes.last
        else {
            return
        }
        if toggling {
            var selectedRows = selectedRowIndexes
            if selectedRows.contains(row) {
                selectedRows.remove(row)
            } else {
                selectedRows.insert(row)
            }
            lastGridSelectedRow = row
            selectRowIndexes(
                selectedRows,
                byExtendingSelection: false
            )
            if gridSelection.isEmpty {
                selectedDataRowsChanged?(selectedDataRows)
                WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: self)
            } else {
                updateGridSelection(.empty)
            }
            return
        }
        let anchorRow = extending
            ? gridSelection.anchor?.row ?? lastGridSelectedRow ?? row
            : row
        let selectedRows = min(anchorRow, row)...max(anchorRow, row)
        selectRowIndexes(
            IndexSet(integersIn: selectedRows),
            byExtendingSelection: false
        )
        updateGridSelection(
            WorkspaceGridSelection(
                anchor: WorkspaceGridCoordinate(
                    row: anchorRow,
                    column: firstColumn
                ),
                active: WorkspaceGridCoordinate(
                    row: row,
                    column: lastColumn
                )
            )
        )
    }

    private func requestCellEdit(row: Int, column: Int) {
        guard
            row >= 0,
            row < numberOfRows,
            isDataColumn(column),
            canEditCellHandler?(row, column) ?? true
        else {
            return
        }
        cellEditHandler?(row, column)
    }

    private func updateGridSelection(
        _ selection: WorkspaceGridSelection
    ) {
        guard selection != gridSelection else { return }
        let previousSelection = gridSelection
        gridSelection = selection
        if let row = singleSelectedRow {
            lastGridSelectedRow = row
        }
        invalidateGridSelectionChange(
            from: previousSelection,
            to: selection
        )
        selectedDataRowsChanged?(selectedDataRows)
        scheduleSelectionAnnouncement(selection)
    }

    private var singleSelectedRow: Int? {
        selectedDataRows.count == 1 ? selectedDataRows.first : nil
    }

    private var selectedDataRows: IndexSet {
        if let rows = gridSelection.rows {
            return IndexSet(integersIn: rows)
        }
        return selectedRowIndexes
    }

    var selectedDataRowIndexesForActions: IndexSet {
        selectedDataRows
    }

    private func scheduleSelectionAnnouncement(
        _ selection: WorkspaceGridSelection
    ) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        pendingSelectionAnnouncement = selection
        guard !isSelectionAnnouncementScheduled else { return }
        isSelectionAnnouncementScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.postPendingSelectionAnnouncement()
        }
    }

    private func postPendingSelectionAnnouncement() {
        isSelectionAnnouncementScheduled = false
        guard let selection = pendingSelectionAnnouncement else { return }
        pendingSelectionAnnouncement = nil
        let announcement: String
        if let rows = selection.rows,
           let columns = selection.columns {
            announcement = selection.cellCount == 1
                ? AppCopy.current.text("已选择单元格", "Cell selected")
                : AppCopy.current.text(
                    "已选择 \(selection.cellCount) 个单元格，"
                        + "第 \(rows.lowerBound + 1) 至 \(rows.upperBound + 1) 行，"
                        + "第 \(columns.lowerBound) 至 \(columns.upperBound) 列",
                    "\(selection.cellCount) cells selected, rows "
                        + "\(rows.lowerBound + 1) to \(rows.upperBound + 1), "
                        + "columns \(columns.lowerBound) to \(columns.upperBound)"
                )
        } else {
            announcement = AppCopy.current.text(
                "已清除单元格选择",
                "Cell selection cleared"
            )
        }
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func trackSelectionDrag() {
        guard let window else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let event = window.nextEvent(matching: mask) {
            guard event.type != .leftMouseUp else { return }
            autoscroll(with: event)
            let point = convert(event.locationInWindow, from: nil)
            guard
                let row = clampedRow(row(at: point)),
                let column = clampedDataColumn(column(at: point))
            else {
                continue
            }
            updateGridSelection(
                gridSelection.extending(
                    to: WorkspaceGridCoordinate(row: row, column: column)
                )
            )
        }
    }

    private func invalidateGridSelectionChange(
        from previousSelection: WorkspaceGridSelection,
        to selection: WorkspaceGridSelection
    ) {
        enumerateAvailableRowViews { rowView, row in
            var invalidatedRects: [NSRect] = []
            for changedSelection in [previousSelection, selection] {
                guard
                    changedSelection.rows?.contains(row) == true,
                    let columns = changedSelection.columns,
                    tableColumns.indices.contains(columns.lowerBound),
                    tableColumns.indices.contains(columns.upperBound)
                else {
                    continue
                }
                let firstColumnRect = rect(ofColumn: columns.lowerBound)
                let lastColumnRect = rect(ofColumn: columns.upperBound)
                let selectionRect = NSRect(
                    x: firstColumnRect.minX,
                    y: rowView.bounds.minY,
                    width: lastColumnRect.maxX - firstColumnRect.minX,
                    height: rowView.bounds.height
                ).intersection(rowView.visibleRect)
                guard
                    !selectionRect.isEmpty,
                    !invalidatedRects.contains(selectionRect)
                else {
                    continue
                }
                invalidatedRects.append(selectionRect)
                rowView.setNeedsDisplay(selectionRect)
            }
        }
    }

    private func clampedRow(_ row: Int) -> Int? {
        guard numberOfRows > 0 else { return nil }
        return min(max(row, 0), numberOfRows - 1)
    }

    private func clampedDataColumn(_ column: Int) -> Int? {
        let columns = dataTableColumnIndexes
        guard let first = columns.first, let last = columns.last else {
            return nil
        }
        if column <= first { return first }
        if column >= last { return last }
        return isDataColumn(column) ? column : first
    }

    private func movedCoordinate(
        from coordinate: WorkspaceGridCoordinate,
        direction: WorkspaceGridDirection,
        toEdge: Bool
    ) -> WorkspaceGridCoordinate {
        let columns = dataTableColumnIndexes
        guard
            numberOfRows > 0,
            let currentColumnIndex = columns.firstIndex(of: coordinate.column)
        else {
            return coordinate
        }

        let row: Int
        let columnListIndex: Int
        switch direction {
        case .up:
            row = toEdge ? 0 : max(0, coordinate.row - 1)
            columnListIndex = currentColumnIndex
        case .down:
            row = toEdge
                ? numberOfRows - 1
                : min(numberOfRows - 1, coordinate.row + 1)
            columnListIndex = currentColumnIndex
        case .left:
            row = coordinate.row
            columnListIndex = toEdge
                ? 0
                : max(0, currentColumnIndex - 1)
        case .right:
            row = coordinate.row
            columnListIndex = toEdge
                ? columns.count - 1
                : min(columns.count - 1, currentColumnIndex + 1)
        }
        return WorkspaceGridCoordinate(
            row: row,
            column: columns[columnListIndex]
        )
    }

    private func copyCurrentSelection(includesColumnNames: Bool) {
        let rows: WorkspaceGridCopyRows
        let columns: [WorkspaceGridCopyColumn]
        if let selectedRows = gridSelection.rows,
           let selectedColumns = gridSelection.columns {
            rows = .range(selectedRows)
            columns = selectedColumns.compactMap(copyColumn(at:))
        } else {
            rows = .indexes(selectedRowIndexes)
            columns = dataTableColumnIndexes.compactMap(copyColumn(at:))
        }
        writeCopy(
            rows: rows,
            columns: columns,
            includesColumnNames: includesColumnNames
        )
    }

    private func copyColumn(
        from sender: NSMenuItem,
        includesColumnName: Bool
    ) {
        guard
            let rawIdentifier = sender.representedObject as? String
        else {
            return
        }
        copyColumn(
            identifiedBy: NSUserInterfaceItemIdentifier(rawIdentifier),
            includesColumnName: includesColumnName
        )
    }

    private func copyColumn(
        at tableColumnIndex: Int
    ) -> WorkspaceGridCopyColumn? {
        guard
            isDataColumn(tableColumnIndex),
            let workspaceDataSource,
            let dataIndex = workspaceDataSource.workspaceTableView(
                self,
                dataColumnIndexFor:
                    tableColumns[tableColumnIndex].identifier
            )
        else {
            return nil
        }
        return WorkspaceGridCopyColumn(
            name: tableColumns[tableColumnIndex].title,
            dataIndex: dataIndex
        )
    }

    private func writeCopy(
        rows: WorkspaceGridCopyRows,
        columns: [WorkspaceGridCopyColumn],
        includesColumnNames: Bool
    ) {
        guard let workspaceDataSource else { return }
        let snapshot = workspaceDataSource.workspaceTableViewCopySnapshot(self)
        let multiplication = rows.count.multipliedReportingOverflow(
            by: columns.count
        )
        guard !multiplication.overflow else { return }
        let cellCount = multiplication.partialValue
        guard cellCount > 0 else { return }

        copyGeneration = UUID()
        backgroundCopyTask?.cancel()
        if cellCount <= Self.immediateCopyCellLimit,
           !snapshot.requiresBackgroundEncoding {
            guard let text = WorkspaceGridClipboardEncoder.encode(
                rows: rows,
                columns: columns,
                includesColumnNames: includesColumnNames,
                nullDisplayText: nullDisplayText,
                emptyStringDisplayText: emptyStringDisplayText,
                rowAt: snapshot.rowAt
            ) else {
                return
            }
            let payload = WorkspaceGridClipboardEncoder.encodeInternalPayload(
                rows: rows,
                columns: columns,
                rowAt: snapshot.rowAt
            )
            WorkspaceGridClipboardEncoder.write(
                text,
                internalPayload: payload,
                to: copyPasteboard
            )
            return
        }

        let generation = copyGeneration
        let copiedNullDisplayText = nullDisplayText
        let copiedEmptyStringDisplayText = emptyStringDisplayText
        copyPasteboard.clearContents()
        postCopyAnnouncement(
            AppCopy.current.text(
                "正在复制 \(cellCount) 个单元格",
                "Copying \(cellCount) cells"
            )
        )
        let task = Task.detached(priority: .userInitiated) {
            WorkspaceGridClipboardEncoder.encode(
                rows: rows,
                columns: columns,
                includesColumnNames: includesColumnNames,
                nullDisplayText: copiedNullDisplayText,
                emptyStringDisplayText: copiedEmptyStringDisplayText,
                rowAt: snapshot.rowAt
            )
        }
        backgroundCopyTask = task
        Task { @MainActor [weak self] in
            guard
                let self,
                let text = await task.value,
                generation == copyGeneration,
                !task.isCancelled
            else {
                return
            }
            WorkspaceGridClipboardEncoder.write(
                text,
                to: copyPasteboard
            )
            backgroundCopyTask = nil
            postCopyAnnouncement(
                AppCopy.current.text(
                    "已复制 \(cellCount) 个单元格",
                    "Copied \(cellCount) cells"
                )
            )
        }
    }

    private func postCopyAnnouncement(_ announcement: String) {
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

struct WorkspaceGridColumnTransition: Equatable {
    let columnIdentifiers: Set<NSUserInterfaceItemIdentifier>
    let offset: CGFloat

    static func make(
        previousPositions:
            [NSUserInterfaceItemIdentifier: CGFloat],
        currentPositions:
            [NSUserInterfaceItemIdentifier: CGFloat],
        excluding excludedIdentifier: NSUserInterfaceItemIdentifier?
    ) -> Self? {
        var movedIdentifiers:
            Set<NSUserInterfaceItemIdentifier> = []
        var offset: CGFloat?
        for (identifier, currentX) in currentPositions {
            guard
                identifier != excludedIdentifier,
                let previousX = previousPositions[identifier]
            else {
                continue
            }
            let columnOffset = previousX - currentX
            guard abs(columnOffset) >= 0.5 else { continue }
            movedIdentifiers.insert(identifier)
            offset = offset ?? columnOffset
        }
        guard let offset, !movedIdentifiers.isEmpty else { return nil }
        return Self(
            columnIdentifiers: movedIdentifiers,
            offset: offset
        )
    }
}

private enum WorkspaceGridDirection: Equatable {
    case up
    case down
    case left
    case right
}

final class WorkspaceGridHeaderView: NSTableHeaderView {
    private static let dragThreshold: CGFloat = 4
    private static let resizeZoneWidth: CGFloat = 4

    private var dragStartLocationInWindow: NSPoint?
    private var dragColumnIdentifier: NSUserInterfaceItemIdentifier?
    var resetColumnWidths: (() -> Void)?

    private lazy var resetColumnWidthsButton: NSButton = {
        let description = AppCopy.current.text(
            "重置列宽",
            "Reset Column Widths"
        )
        let image = NSImage(
            systemSymbolName: "arrow.left.and.right",
            accessibilityDescription: description
        )
        image?.isTemplate = true
        let button = NSButton(
            image: image ?? NSImage(),
            target: self,
            action: #selector(resetColumnWidthsButtonPressed(_:))
        )
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        button.toolTip = description
        button.setAccessibilityLabel(description)
        button.setAccessibilityIdentifier("resetGridColumnWidthsButton")
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(resetColumnWidthsButton)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(resetColumnWidthsButton)
    }

    override func layout() {
        super.layout()
        guard
            let tableView = tableView as? WorkspaceDirectDrawTableView,
            let rowNumberIdentifier = tableView.rowNumberIdentifier,
            let columnIndex = tableView.tableColumns.firstIndex(where: {
                $0.identifier == rowNumberIdentifier
            })
        else {
            resetColumnWidthsButton.isHidden = true
            return
        }

        resetColumnWidthsButton.isHidden = false
        let columnRect = headerRect(ofColumn: columnIndex)
        let side = min(24, max(0, columnRect.height - 2))
        resetColumnWidthsButton.frame = NSRect(
            x: floor(columnRect.midX - side / 2),
            y: floor(columnRect.midY - side / 2),
            width: side,
            height: side
        )
    }

    @objc private func resetColumnWidthsButtonPressed(_ sender: NSButton) {
        resetColumnWidths?()
    }

    override func mouseDown(with event: NSEvent) {
        guard
            let tableView = tableView as? WorkspaceDirectDrawTableView
        else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let columnIndex = column(at: point)
        if !isInResizeZone(point),
           tableView.tableColumns.indices.contains(columnIndex),
           tableView.tableColumns[columnIndex].identifier
            != tableView.rowNumberIdentifier {
            dragStartLocationInWindow = event.locationInWindow
            dragColumnIdentifier =
                tableView.tableColumns[columnIndex].identifier
            tableView.prepareColumnDragVisual(column: columnIndex)
        }

        super.mouseDown(with: event)
        tableView.endColumnDragVisual()
        dragStartLocationInWindow = nil
        dragColumnIdentifier = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawHeaderBackground(in: dirtyRect)
        drawBottomSeparator(in: dirtyRect)
        guard
            draggedColumn >= 0,
            let tableView = tableView as? WorkspaceDirectDrawTableView,
            let currentLocationInWindow =
                window?.mouseLocationOutsideOfEventStream
        else {
            return
        }
        tableView.animateColumnsAfterReordering()
        updateColumnDragVisual(
            currentLocationInWindow: currentLocationInWindow,
            requiresNativeDragState: true
        )
    }

    private func drawHeaderBackground(in dirtyRect: NSRect) {
        WorkspaceGridMetrics.headerBackgroundColor.setFill()
        dirtyRect.fill()
    }

    private func drawBottomSeparator(in dirtyRect: NSRect) {
        let height: CGFloat = 1
        NSColor.separatorColor.setFill()
        NSRect(
            x: dirtyRect.minX,
            y: bounds.maxY - height,
            width: dirtyRect.width,
            height: height
        ).fill()
    }

    override func mouseDragged(with event: NSEvent) {
        updateColumnDragVisual(
            currentLocationInWindow: event.locationInWindow,
            requiresNativeDragState: false
        )
        super.mouseDragged(with: event)
        updateColumnDragVisual(
            currentLocationInWindow: event.locationInWindow,
            requiresNativeDragState: true
        )
    }

    private func updateColumnDragVisual(
        currentLocationInWindow: NSPoint,
        requiresNativeDragState: Bool
    ) {
        guard
            !requiresNativeDragState || draggedColumn >= 0,
            let tableView = tableView as? WorkspaceDirectDrawTableView,
            let dragStartLocationInWindow,
            let dragColumnIdentifier,
            let currentColumnIndex = tableView.tableColumns.firstIndex(
                where: { $0.identifier == dragColumnIdentifier }
            )
        else {
            return
        }
        let distance =
            currentLocationInWindow.x - dragStartLocationInWindow.x
        guard abs(distance) > Self.dragThreshold else { return }
        tableView.updateColumnDragVisual(
            column: currentColumnIndex,
            distance: distance
        )
    }

    private func isInResizeZone(_ point: NSPoint) -> Bool {
        guard let tableView else { return false }
        return tableView.tableColumns.enumerated().contains { index, column in
            guard column.resizingMask.contains(.userResizingMask) else {
                return false
            }
            return abs(headerRect(ofColumn: index).maxX - point.x)
                <= Self.resizeZoneWidth
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedColumn = column(at: point)
        guard
            let tableView = tableView as? WorkspaceDirectDrawTableView,
            tableView.tableColumns.indices.contains(clickedColumn),
            tableView.tableColumns[clickedColumn].identifier
                != tableView.rowNumberIdentifier
        else {
            return super.menu(for: event)
        }

        let identifier = tableView.tableColumns[clickedColumn]
            .identifier.rawValue
        let menu = NSMenu()
        let copyColumnItem = NSMenuItem(
            title: AppCopy.current.text("复制列", "Copy Column"),
            action: #selector(WorkspaceDirectDrawTableView.copyColumn(_:)),
            keyEquivalent: ""
        )
        copyColumnItem.target = tableView
        copyColumnItem.representedObject = identifier
        menu.addItem(copyColumnItem)

        let copyWithNameItem = NSMenuItem(
            title: AppCopy.current.text(
                "复制列并包含列名",
                "Copy Column with Name"
            ),
            action:
                #selector(
                    WorkspaceDirectDrawTableView.copyColumnWithName(_:)
                ),
            keyEquivalent: ""
        )
        copyWithNameItem.target = tableView
        copyWithNameItem.representedObject = identifier
        menu.addItem(copyWithNameItem)
        return menu
    }
}

private final class WorkspaceColumnSnapshotView: NSView {
    private let image: NSImage
    private let opacity: CGFloat

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, image: NSImage, opacity: CGFloat) {
        self.image = image
        self.opacity = opacity
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        image.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: opacity,
            respectFlipped: true,
            hints: nil
        )
    }
}
