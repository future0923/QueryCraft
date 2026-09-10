import AppKit

struct WorkspaceDatabaseSchemaGridRowPresentation {
    enum ChangeState {
        case unchanged
        case inserted
        case modified
        case deleted
    }

    let id: UUID
    let values: [String]
    let booleanValues: [Int: Bool]
    let placeholderIndexes: Set<Int>
    let optionIndexes: Set<Int>
    let editableIndexes: Set<Int>
    let changeState: ChangeState
}

final class WorkspaceDatabaseSchemaRowView: NSTableRowView {
    private static let leadingParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .natural
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private weak var schemaTableView: NSTableView?
    private var presentation: WorkspaceDatabaseSchemaGridRowPresentation?
    private var columnIndexes: [NSUserInterfaceItemIdentifier: Int] = [:]
    private var statusIdentifier: NSUserInterfaceItemIdentifier?
    private var tableRowIndex = -1
    private let cellFont = WorkspaceGridMetrics.cellFont
    private lazy var normalAttributes = Self.attributes(
        font: cellFont,
        color: .labelColor
    )
    private lazy var placeholderAttributes = Self.attributes(
        font: NSFontManager.shared.convert(
            cellFont,
            toHaveTrait: .italicFontMask
        ),
        color: .tertiaryLabelColor
    )
    private lazy var selectedAttributes =
        WorkspaceDatabaseDataRowView.selectedCellAttributes(
            font: cellFont,
            isEmphasized: true,
            isPlaceholder: false
        )
    private lazy var selectedPlaceholderAttributes =
        WorkspaceDatabaseDataRowView.selectedCellAttributes(
            font: NSFontManager.shared.convert(
                cellFont,
                toHaveTrait: .italicFontMask
            ),
            isEmphasized: true,
            isPlaceholder: true
        )
    private lazy var unemphasizedSelectedAttributes =
        WorkspaceDatabaseDataRowView.selectedCellAttributes(
            font: cellFont,
            isEmphasized: false,
            isPlaceholder: false
        )
    private lazy var unemphasizedSelectedPlaceholderAttributes =
        WorkspaceDatabaseDataRowView.selectedCellAttributes(
            font: NSFontManager.shared.convert(
                cellFont,
                toHaveTrait: .italicFontMask
            ),
            isEmphasized: false,
            isPlaceholder: true
        )
    private let inlineControls = WorkspaceGridInlineControls()

    override var isFlipped: Bool { true }

    static func invalidateVisibleRows(in tableView: NSTableView) {
        tableView.enumerateAvailableRowViews { rowView, _ in
            guard rowView is WorkspaceDatabaseSchemaRowView else { return }
            rowView.needsDisplay = true
        }
    }

    func booleanValue(at dataIndex: Int) -> Bool? {
        presentation?.booleanValues[dataIndex]
    }

    func isEditable(at dataIndex: Int) -> Bool {
        presentation?.editableIndexes.contains(dataIndex) == true
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard presentation?.changeState != .deleted else { return }
        super.drawSelection(in: dirtyRect)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let color = pendingBackgroundColor else { return }
        color.setFill()
        dirtyRect.fill()
    }

    func configure(
        tableView: NSTableView,
        presentation: WorkspaceDatabaseSchemaGridRowPresentation,
        rowIndex: Int,
        columnIndexes: [NSUserInterfaceItemIdentifier: Int],
        statusIdentifier: NSUserInterfaceItemIdentifier,
        accessibilityPrefix: String
    ) {
        schemaTableView = tableView
        self.presentation = presentation
        tableRowIndex = rowIndex
        self.columnIndexes = columnIndexes
        self.statusIdentifier = statusIdentifier
        setAccessibilityIdentifier("\(accessibilityPrefix).row.\(presentation.id)")
        let summary = presentation.values.joined(separator: ", ")
        setAccessibilityLabel(summary)
        setAccessibilityValue(summary)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let schemaTableView, let presentation else { return }
        let directTable = schemaTableView as? WorkspaceDirectDrawTableView

        for (tableColumnIndex, tableColumn) in
            schemaTableView.tableColumns.enumerated()
        {
            let columnRect = schemaTableView.rect(ofColumn: tableColumnIndex)
            let cellRect = NSRect(
                x: columnRect.minX,
                y: bounds.minY,
                width: columnRect.width,
                height: bounds.height
            )
            guard cellRect.intersects(dirtyRect) else { continue }

            if tableColumn.identifier == statusIdentifier {
                drawStatus(presentation.changeState, in: cellRect)
                continue
            }
            guard
                let dataIndex = columnIndexes[tableColumn.identifier],
                presentation.values.indices.contains(dataIndex),
                directTable?.draggedColumnIdentifier != tableColumn.identifier,
                directTable?.transitionHiddenColumnIdentifiers.contains(
                    tableColumn.identifier
                ) != true
            else {
                continue
            }

            NSGraphicsContext.saveGraphicsState()
            let isGridSelected = directTable?.gridSelection.contains(
                row: tableRowIndex,
                column: tableColumnIndex
            ) == true
            let showsGridSelection = isGridSelected
                && presentation.changeState != .deleted
            if showsGridSelection {
                drawGridSelectionBackground(
                    in: cellRect,
                    tableView: schemaTableView
                )
            }

            if let booleanValue = presentation.booleanValues[dataIndex] {
                drawCheckbox(
                    booleanValue,
                    in: cellRect,
                    isSelected: usesActiveInsertedAppearance
                        || isSelected
                        || showsGridSelection,
                    isEnabled: presentation.editableIndexes.contains(dataIndex)
                )
            } else {
                drawText(
                    presentation.values[dataIndex],
                    in: cellRect,
                    isPlaceholder: presentation.placeholderIndexes.contains(
                        dataIndex
                    ),
                    isSelected: usesActiveInsertedAppearance
                        || isSelected
                        || showsGridSelection,
                    isEmphasized: usesActiveInsertedAppearance
                        || (showsGridSelection
                        ? schemaTableView.window?.isKeyWindow == true
                        : isEmphasized),
                    reservesDisclosureSpace: presentation.optionIndexes.contains(
                        dataIndex
                    )
                )
                if presentation.optionIndexes.contains(dataIndex),
                   presentation.editableIndexes.contains(dataIndex) {
                    drawDisclosure(
                        in: cellRect,
                        isSelected: usesActiveInsertedAppearance
                            || isSelected
                            || showsGridSelection
                    )
                }
            }

            let coordinate = WorkspaceGridCoordinate(
                row: tableRowIndex,
                column: tableColumnIndex
            )
            if Self.shouldDrawActiveCellIndicator(
                active: directTable?.gridSelection.active,
                suppressed: directTable?.suppressedActiveCellIndicator,
                coordinate: coordinate,
                isKeyWindow: schemaTableView.window?.isKeyWindow == true
            ) {
                drawActiveCellIndicator(
                    in: cellRect,
                    usesSelectedBackground: showsGridSelection
                        || usesActiveInsertedAppearance
                )
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func shouldDrawActiveCellIndicator(
        active: WorkspaceGridCoordinate?,
        suppressed: WorkspaceGridCoordinate?,
        coordinate: WorkspaceGridCoordinate,
        isKeyWindow: Bool
    ) -> Bool {
        isKeyWindow && active == coordinate && suppressed != coordinate
    }

    private func drawStatus(
        _ state: WorkspaceDatabaseSchemaGridRowPresentation.ChangeState,
        in cellRect: NSRect
    ) {
        let color: NSColor?
        switch state {
        case .unchanged: color = nil
        case .inserted: color = .systemGreen
        case .modified: color = .systemOrange
        case .deleted: color = .systemRed
        }
        guard let color else { return }
        color.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: floor(cellRect.midX - 3.5),
                y: floor(cellRect.midY - 3.5),
                width: 7,
                height: 7
            )
        ).fill()
    }

    private func drawText(
        _ text: String,
        in cellRect: NSRect,
        isPlaceholder: Bool,
        isSelected: Bool,
        isEmphasized: Bool,
        reservesDisclosureSpace: Bool
    ) {
        let attributes: [NSAttributedString.Key: Any]
        if isSelected {
            if isEmphasized {
                attributes = isPlaceholder
                    ? selectedPlaceholderAttributes
                    : selectedAttributes
            } else {
                attributes = isPlaceholder
                    ? unemphasizedSelectedPlaceholderAttributes
                    : unemphasizedSelectedAttributes
            }
        } else {
            attributes = isPlaceholder
                ? placeholderAttributes
                : normalAttributes
        }
        let disclosureWidth = reservesDisclosureSpace ? WorkspaceGridInlineControls.disclosureWidth : 0
        let lineHeight = ceil(
            cellFont.ascender - cellFont.descender + cellFont.leading
        )
        let textRect = NSRect(
            x: cellRect.minX,
            y: floor(cellRect.midY - lineHeight / 2),
            width: max(
                0,
                cellRect.width
                    - WorkspaceGridMetrics.cellTrailingPadding
                    - disclosureWidth
            ),
            height: lineHeight
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawCheckbox(
        _ value: Bool,
        in cellRect: NSRect,
        isSelected: Bool,
        isEnabled: Bool
    ) {
        inlineControls.drawCheckbox(value ? .on : .off, in: cellRect, view: self,
                                    isSelected: isSelected, isEnabled: isEnabled)
    }

    private func drawDisclosure(in cellRect: NSRect, isSelected: Bool) {
        inlineControls.drawDisclosure(in: cellRect, isSelected: isSelected)
    }

    private func drawGridSelectionBackground(
        in cellRect: NSRect,
        tableView: NSTableView
    ) {
        let color = tableView.window?.isKeyWindow == true
            ? NSColor.selectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        cellRect.fill()
    }

    private func drawActiveCellIndicator(
        in cellRect: NSRect,
        usesSelectedBackground: Bool
    ) {
        let path = NSBezierPath(rect: cellRect.insetBy(dx: 1, dy: 1))
        path.lineJoinStyle = .miter
        path.lineWidth = 2
        let contourColor = usesSelectedBackground
            ? NSColor.shadowColor.withAlphaComponent(0.32)
            : NSColor.shadowColor.withAlphaComponent(0.20)
        contourColor.setStroke()
        path.stroke()
        NSColor.systemOrange.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private var pendingBackgroundColor: NSColor? {
        guard let presentation else { return nil }
        switch presentation.changeState {
        case .unchanged:
            return nil
        case .inserted:
            return WorkspaceDatabaseDataRowView.draftBackgroundColor(
                isDraftRow: true,
                isEditing: usesActiveInsertedAppearance,
                isWindowKey: window?.isKeyWindow == true,
                isDarkAppearance: usesDarkAppearance
            )
        case .modified:
            return WorkspaceDatabaseDataRowView.pendingDraftBackgroundColor(
                isDarkAppearance: usesDarkAppearance
            )
        case .deleted:
            return WorkspaceDatabaseDataRowView.pendingDeletionBackgroundColor(
                isDarkAppearance: usesDarkAppearance
            )
        }
    }

    private var usesDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var usesActiveInsertedAppearance: Bool {
        guard presentation?.changeState == .inserted else { return false }
        if let tableView = schemaTableView as? WorkspaceDirectDrawTableView,
           tableView.gridSelection.active?.row == tableRowIndex
        {
            return window?.isKeyWindow == true
        }
        return schemaTableView?.selectedRowIndexes.contains(tableRowIndex) == true
            && window?.isKeyWindow == true
    }

    private static func attributes(
        font: NSFont,
        color: NSColor
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: leadingParagraphStyle,
        ]
    }
}
