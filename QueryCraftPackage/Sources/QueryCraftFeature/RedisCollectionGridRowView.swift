import AppKit

final class RedisCollectionGridRowView: NSTableRowView {
    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .natural
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private static let rowNumberParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private weak var collectionTableView: WorkspaceDirectDrawTableView?
    private var presentation: RedisCollectionGridRowPresentation?
    private var columnIndexes: [NSUserInterfaceItemIdentifier: Int] = [:]
    private var rowNumberIdentifier: NSUserInterfaceItemIdentifier?
    private var actionIdentifier: NSUserInterfaceItemIdentifier?
    private var tableRowIndex = -1
    private let cellFont = WorkspaceGridMetrics.cellFont
    private lazy var normalAttributes = Self.attributes(
        font: cellFont,
        color: .labelColor
    )
    private lazy var selectedAttributes =
        WorkspaceDatabaseDataRowView.selectedCellAttributes(
            font: cellFont,
            isEmphasized: true,
            isPlaceholder: false
        )
    private lazy var unemphasizedSelectedAttributes =
        WorkspaceDatabaseDataRowView.selectedCellAttributes(
            font: cellFont,
            isEmphasized: false,
            isPlaceholder: false
        )
    private lazy var rowNumberAttributes = Self.attributes(
        font: cellFont,
        color: .tertiaryLabelColor,
        paragraphStyle: Self.rowNumberParagraphStyle
    )
    private lazy var emphasizedSelectedRowNumberAttributes = Self.attributes(
        font: cellFont,
        color: WorkspaceDatabaseDataRowView.selectedTextColor(
            isEmphasized: true
        ),
        paragraphStyle: Self.rowNumberParagraphStyle
    )
    private lazy var unemphasizedSelectedRowNumberAttributes = Self.attributes(
        font: cellFont,
        color: WorkspaceDatabaseDataRowView.selectedTextColor(
            isEmphasized: false
        ),
        paragraphStyle: Self.rowNumberParagraphStyle
    )
    override var isFlipped: Bool { true }

    static func invalidateVisibleRows(in tableView: NSTableView) {
        tableView.enumerateAvailableRowViews { rowView, _ in
            guard rowView is RedisCollectionGridRowView else { return }
            rowView.needsDisplay = true
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard presentation?.changeState == .unchanged
                || presentation?.changeState == .modified
        else { return }
        super.drawSelection(in: dirtyRect)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let color = fullRowBackgroundColor else { return }
        color.setFill()
        dirtyRect.fill()
    }

    func configure(
        tableView: WorkspaceDirectDrawTableView,
        presentation: RedisCollectionGridRowPresentation,
        rowIndex: Int,
        columnIndexes: [NSUserInterfaceItemIdentifier: Int],
        rowNumberIdentifier: NSUserInterfaceItemIdentifier,
        actionIdentifier: NSUserInterfaceItemIdentifier
    ) {
        collectionTableView = tableView
        self.presentation = presentation
        tableRowIndex = rowIndex
        self.columnIndexes = columnIndexes
        self.rowNumberIdentifier = rowNumberIdentifier
        self.actionIdentifier = actionIdentifier
        setAccessibilityIdentifier("redis.collection.row.\(presentation.id)")
        let summary = presentation.values.joined(separator: ", ")
        setAccessibilityLabel(summary)
        setAccessibilityValue(summary)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let tableView = collectionTableView,
              let presentation
        else { return }

        for (tableColumnIndex, column) in tableView.tableColumns.enumerated() {
            let columnRect = tableView.rect(ofColumn: tableColumnIndex)
            let cellRect = NSRect(
                x: columnRect.minX,
                y: bounds.minY,
                width: columnRect.width,
                height: bounds.height
            )
            guard cellRect.intersects(dirtyRect) else { continue }

            if column.identifier == rowNumberIdentifier {
                drawRowNumber(
                    presentation.changeState == .inserted
                        ? "+"
                        : String(tableRowIndex + 1),
                    in: cellRect
                )
                continue
            }
            if column.identifier == actionIdentifier {
                drawAction(in: cellRect, isDeleted: presentation.changeState == .deleted)
                continue
            }
            guard let dataIndex = columnIndexes[column.identifier],
                  presentation.values.indices.contains(dataIndex),
                  tableView.draggedColumnIdentifier != column.identifier,
                  !tableView.transitionHiddenColumnIdentifiers.contains(
                    column.identifier
                  )
            else { continue }

            NSGraphicsContext.saveGraphicsState()
            let coordinate = WorkspaceGridCoordinate(
                row: tableRowIndex,
                column: tableColumnIndex
            )
            let isGridSelected = tableView.gridSelection.contains(
                row: tableRowIndex,
                column: tableColumnIndex
            ) && presentation.changeState != .deleted
            if let background = cellBackgroundColor(
                dataIndex: dataIndex,
                isGridSelected: isGridSelected
            ) {
                background.setFill()
                cellRect.fill()
            }
            drawText(
                presentation.values[dataIndex],
                in: cellRect,
                isSelected: isGridSelected || usesActiveInsertedAppearance,
                isEmphasized: usesActiveInsertedAppearance
                    || tableView.window?.isKeyWindow == true
            )
            if tableView.gridSelection.active == coordinate,
               tableView.suppressedActiveCellIndicator != coordinate,
               tableView.window?.isKeyWindow == true,
               presentation.changeState != .deleted
            {
                drawActiveCellIndicator(in: cellRect)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawRowNumber(_ text: String, in cellRect: NSRect) {
        let usesSelectionAppearance = presentation?.changeState == .inserted
            ? usesActiveInsertedAppearance
            : isSelected
        let attributes = usesSelectionAppearance
            ? (
                presentation?.changeState == .inserted || isEmphasized
                    ? emphasizedSelectedRowNumberAttributes
                    : unemphasizedSelectedRowNumberAttributes
            )
            : rowNumberAttributes
        drawText(text, in: cellRect, attributes: attributes)
    }

    private func drawText(
        _ text: String,
        in cellRect: NSRect,
        isSelected: Bool,
        isEmphasized: Bool
    ) {
        let attributes = isSelected
            ? (isEmphasized ? selectedAttributes : unemphasizedSelectedAttributes)
            : normalAttributes
        drawText(text, in: cellRect, attributes: attributes)
    }

    private func drawText(
        _ text: String,
        in cellRect: NSRect,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let lineHeight = ceil(
            cellFont.ascender - cellFont.descender + cellFont.leading
        )
        let textRect = NSRect(
            x: cellRect.minX,
            y: floor(cellRect.midY - lineHeight / 2),
            width: max(
                0,
                cellRect.width - WorkspaceGridMetrics.cellTrailingPadding
            ),
            height: lineHeight
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawAction(in cellRect: NSRect, isDeleted: Bool) {
        let title = isDeleted
            ? AppCopy.current.text("撤销删除", "Undo Delete")
            : AppCopy.current.text("删除", "Delete")
        let image = NSImage(
            systemSymbolName: Self.actionSystemImageName(isDeleted: isDeleted),
            accessibilityDescription: title
        )
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .regular
        ).applying(
            NSImage.SymbolConfiguration(
                hierarchicalColor: isDeleted
                    ? NSColor.controlAccentColor
                    : NSColor.systemRed
            )
        )
        guard let configuredImage = image?.withSymbolConfiguration(configuration)
        else { return }
        let side = min(16, cellRect.height)
        configuredImage.draw(
            in: NSRect(
                x: floor(cellRect.midX - side / 2),
                y: floor(cellRect.midY - side / 2),
                width: side,
                height: side
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    static func actionSystemImageName(isDeleted: Bool) -> String {
        isDeleted ? "arrow.uturn.backward" : "trash"
    }

    private func drawActiveCellIndicator(in cellRect: NSRect) {
        let path = NSBezierPath(rect: cellRect.insetBy(dx: 1, dy: 1))
        path.lineJoinStyle = .miter
        path.lineWidth = 2
        WorkspaceDatabaseDataRowView.activeCellIndicatorColor.setStroke()
        path.stroke()
    }

    private func cellBackgroundColor(
        dataIndex: Int,
        isGridSelected: Bool
    ) -> NSColor? {
        if isGridSelected {
            return WorkspaceDatabaseDataRowView.gridSelectionBackgroundColor(
                isWindowKey: window?.isKeyWindow == true
            )
        }
        guard presentation?.changeState == .modified,
              presentation?.modifiedDataIndexes.contains(dataIndex) == true
        else { return nil }
        return WorkspaceDatabaseDataRowView.pendingUpdateBackgroundColor(
            isDarkAppearance: usesDarkAppearance
        )
    }

    private var fullRowBackgroundColor: NSColor? {
        switch presentation?.changeState {
        case .inserted:
            WorkspaceDatabaseDataRowView.draftBackgroundColor(
                isDraftRow: true,
                isEditing: usesActiveInsertedAppearance,
                isWindowKey: window?.isKeyWindow == true,
                isDarkAppearance: usesDarkAppearance
            )
        case .deleted:
            WorkspaceDatabaseDataRowView.pendingDeletionBackgroundColor(
                isDarkAppearance: usesDarkAppearance
            )
        case .unchanged, .modified, .none:
            nil
        }
    }

    private var usesActiveInsertedAppearance: Bool {
        guard presentation?.changeState == .inserted,
              let tableView = collectionTableView,
              tableView.window?.isKeyWindow == true
        else { return false }
        return tableView.gridSelection.active?.row == tableRowIndex
            || tableView.selectedRowIndexes.contains(tableRowIndex)
    }

    private var usesDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func attributes(
        font: NSFont,
        color: NSColor,
        paragraphStyle: NSParagraphStyle = paragraphStyle
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
        ]
    }
}
