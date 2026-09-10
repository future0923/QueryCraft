import AppKit

final class WorkspaceDatabaseDataRowView: NSTableRowView {
    static let maximumDrawnTextCharacters = 300
    static let maximumAccessibilityCellCharacters = 200
    static let maximumAccessibilityRowCharacters = 1_024

    private static let leadingParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .natural
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private static let trailingParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private weak var dataTableView: NSTableView?
    private var dataRow: WorkspaceDatabaseDataRow?
    private var columnIndexes: [
        NSUserInterfaceItemIdentifier: Int
    ] = [:]
    private var rowNumberIdentifier: NSUserInterfaceItemIdentifier?
    private var nullDisplayText = "NULL"
    private var emptyStringDisplayText = ""
    private var insertDraftModes:
        [Int: WorkspaceDatabaseDataRowInsertMode]?
    private var isInsertDraftEditing = false
    private var pendingUpdateColumnIndexes: Set<Int> = []
    private var isPendingDeletion = false
    private var cellControls: [Int: WorkspaceGridInlineControl] = [:]
    private lazy var inlineControls = WorkspaceGridInlineControls()
    private var tableRowIndex = -1
    private var cellFont = WorkspaceGridMetrics.cellFont
    private var lineHeight = WorkspaceGridMetrics.cellFont.lineHeight
    private lazy var normalAttributes = Self.attributes(
        font: cellFont,
        color: .labelColor,
        paragraphStyle: Self.leadingParagraphStyle
    )
    private lazy var nullAttributes = Self.attributes(
        font: NSFontManager.shared.convert(
            cellFont,
            toHaveTrait: .italicFontMask
        ),
        color: .tertiaryLabelColor,
        paragraphStyle: Self.leadingParagraphStyle
    )
    private lazy var binaryAttributes = Self.attributes(
        font: cellFont,
        color: .secondaryLabelColor,
        paragraphStyle: Self.leadingParagraphStyle
    )
    private lazy var emphasizedSelectedAttributes = Self.selectedCellAttributes(
        font: cellFont,
        isEmphasized: true,
        isPlaceholder: false
    )
    private lazy var unemphasizedSelectedAttributes = Self.selectedCellAttributes(
        font: cellFont,
        isEmphasized: false,
        isPlaceholder: false
    )
    private lazy var emphasizedSelectedNullAttributes = Self.selectedCellAttributes(
        font: NSFontManager.shared.convert(
            cellFont,
            toHaveTrait: .italicFontMask
        ),
        isEmphasized: true,
        isPlaceholder: true
    )
    private lazy var unemphasizedSelectedNullAttributes = Self.selectedCellAttributes(
        font: NSFontManager.shared.convert(
            cellFont,
            toHaveTrait: .italicFontMask
        ),
        isEmphasized: false,
        isPlaceholder: true
    )
    private lazy var rowNumberAttributes = Self.attributes(
        font: cellFont,
        color: .tertiaryLabelColor,
        paragraphStyle: Self.trailingParagraphStyle
    )
    private lazy var emphasizedSelectedRowNumberAttributes = Self.attributes(
        font: cellFont,
        color: Self.selectedTextColor(isEmphasized: true),
        paragraphStyle: Self.trailingParagraphStyle
    )
    private lazy var unemphasizedSelectedRowNumberAttributes = Self.attributes(
        font: cellFont,
        color: Self.selectedTextColor(isEmphasized: false),
        paragraphStyle: Self.trailingParagraphStyle
    )

    override var isFlipped: Bool { true }

    static func invalidateVisibleRows(in tableView: NSTableView) {
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard insertDraftModes == nil, !isPendingDeletion else { return }
        super.drawSelection(in: dirtyRect)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let color = pendingPresentationBackgroundColor else { return }
        color.setFill()
        dirtyRect.fill()
    }

    func configure(
        tableView: NSTableView,
        dataRow: WorkspaceDatabaseDataRow,
        rowIndex: Int,
        columnIndexes: [NSUserInterfaceItemIdentifier: Int],
        rowNumberIdentifier: NSUserInterfaceItemIdentifier,
        nullDisplayText: String = "NULL",
        emptyStringDisplayText: String = "",
        cellFont: NSFont = WorkspaceGridMetrics.cellFont,
        accessibilityPrefix: String = "databaseData",
        insertDraftModes: [Int: WorkspaceDatabaseDataRowInsertMode]? = nil,
        isInsertDraftEditing: Bool = false,
        pendingUpdateColumnIndexes: Set<Int> = [],
        isPendingDeletion: Bool = false,
        cellControls: [Int: WorkspaceGridInlineControl] = [:]
    ) {
        dataTableView = tableView
        self.dataRow = dataRow
        tableRowIndex = rowIndex
        self.columnIndexes = columnIndexes
        self.rowNumberIdentifier = rowNumberIdentifier
        self.nullDisplayText = nullDisplayText
        self.emptyStringDisplayText = emptyStringDisplayText
        self.insertDraftModes = insertDraftModes
        self.isInsertDraftEditing = isInsertDraftEditing
        self.pendingUpdateColumnIndexes = pendingUpdateColumnIndexes
        self.isPendingDeletion = isPendingDeletion
        self.cellControls = cellControls
        updateFontIfNeeded(cellFont)
        setAccessibilityIdentifier("\(accessibilityPrefix).row.\(dataRow.id)")
        let accessibilitySummary = accessibilitySummary(
            for: dataRow,
            insertDraftModes: insertDraftModes,
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText
        )
        setAccessibilityLabel(accessibilitySummary)
        setAccessibilityValue(accessibilitySummary)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let dataTableView, let dataRow else { return }
        let directDrawTableView =
            dataTableView as? WorkspaceDirectDrawTableView
        for (tableColumnIndex, tableColumn) in
            dataTableView.tableColumns.enumerated()
        {
            let tableColumnRect = dataTableView.rect(
                ofColumn: tableColumnIndex
            )
            let cellRect = NSRect(
                x: tableColumnRect.minX,
                y: bounds.minY,
                width: tableColumnRect.width,
                height: bounds.height
            )
            guard cellRect.intersects(dirtyRect) else { continue }

            if tableColumn.identifier == rowNumberIdentifier {
                if insertDraftModes == nil {
                    drawRowNumber(String(dataRow.id + 1), in: cellRect)
                } else {
                    drawRowNumber("+", in: cellRect)
                }
                continue
            }
            guard let dataColumnIndex = columnIndexes[tableColumn.identifier]
            else {
                continue
            }
            let isDraggedColumn = directDrawTableView?
                .draggedColumnIdentifier == tableColumn.identifier
            let isTransitionHidden =
                directDrawTableView?
                .transitionHiddenColumnIdentifiers
                .contains(tableColumn.identifier) == true
            guard !isDraggedColumn, !isTransitionHidden else { continue }

            NSGraphicsContext.saveGraphicsState()
            let isGridSelected =
                directDrawTableView?.gridSelection.contains(
                    row: tableRowIndex,
                    column: tableColumnIndex
                ) == true
            let showsGridSelection = isGridSelected
                && !isPendingDeletion
                && (insertDraftModes == nil || usesActiveDraftAppearance)
            if let color = cellBackgroundColor(
                at: dataColumnIndex,
                isGridSelected: showsGridSelection,
                isWindowKey: dataTableView.window?.isKeyWindow == true
            ) {
                color.setFill()
                cellRect.fill()
            }
            switch cellControls[dataColumnIndex] {
            case let .booleanIndicator(state):
                // Mapping capabilities are readable status indicators, not disabled
                // buttons. Editing remains gated by the coordinator's canEdit handler.
                inlineControls.drawCheckbox(state, in: cellRect, view: self,
                                            isSelected: isSelected || showsGridSelection, isEnabled: true)
            case .unavailable:
                inlineControls.drawUnavailable(in: cellRect,
                    isSelected: (isSelected && isEmphasized)
                        || (showsGridSelection && dataTableView.window?.isKeyWindow == true))
            case .options:
                var textRect = cellRect
                textRect.size.width = max(0, textRect.width - WorkspaceGridInlineControls.disclosureWidth)
                draw(dataRow.value(at: dataColumnIndex), in: textRect,
                     isGridSelected: showsGridSelection, insertDraftMode: nil)
                inlineControls.drawDisclosure(in: cellRect, isSelected: (isSelected && isEmphasized)
                                              || (showsGridSelection && dataTableView.window?.isKeyWindow == true))
            case nil:
                draw(dataRow.value(at: dataColumnIndex), in: cellRect,
                     isGridSelected: showsGridSelection, insertDraftMode: insertDraftModes?[dataColumnIndex])
            }
            if directDrawTableView?.gridSelection.active
                == WorkspaceGridCoordinate(
                    row: tableRowIndex,
                    column: tableColumnIndex
                ),
               dataTableView.window?.isKeyWindow == true
            {
                drawActiveCellIndicator(in: cellRect)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawRowNumber(_ rowNumber: String, in cellRect: NSRect) {
        let usesSelectionAppearance = insertDraftModes != nil
            ? usesActiveDraftAppearance
            : isSelected
        draw(
            rowNumber,
            in: cellRect,
            attributes: usesSelectionAppearance
                ? (
                    insertDraftModes != nil || isEmphasized
                        ? emphasizedSelectedRowNumberAttributes
                        : unemphasizedSelectedRowNumberAttributes
                )
                : rowNumberAttributes
        )
    }

    private func draw(
        _ cell: WorkspaceDatabaseDataCell,
        in cellRect: NSRect,
        isGridSelected: Bool,
        insertDraftMode: WorkspaceDatabaseDataRowInsertMode?
    ) {
        let text = insertDraftMode.map { mode in
            switch mode {
            case .unfilled:
                "REQUIRED"
            case .useDefault:
                "DEFAULT"
            case .null:
                "NULL"
            case .value:
                displayText(for: cell)
            }
        } ?? displayText(for: cell)
        let usesSelectionAppearance = insertDraftModes != nil
            ? usesActiveDraftAppearance
            : isSelected || isGridSelected
        if usesSelectionAppearance {
            let isEmphasizedSelection = insertDraftModes != nil
                || (isGridSelected
                    ? dataTableView?.window?.isKeyWindow == true
                    : isEmphasized)
            let usesNullStyle = insertDraftMode.map { $0 != .value } == true
                || cellUsesNullStyle(cell)
            let selectedAttributes = if usesNullStyle {
                isEmphasizedSelection
                    ? emphasizedSelectedNullAttributes
                    : unemphasizedSelectedNullAttributes
            } else {
                isEmphasizedSelection
                    ? emphasizedSelectedAttributes
                    : unemphasizedSelectedAttributes
            }
            draw(
                text,
                in: cellRect,
                attributes: selectedAttributes
            )
            return
        }

        if insertDraftMode.map({ $0 != .value }) == true {
            draw(text, in: cellRect, attributes: nullAttributes)
            return
        }

        switch cell {
        case .null:
            draw(
                displayText(for: cell),
                in: cellRect,
                attributes: nullAttributes
            )
        case let .text(value) where value.isEmpty:
            draw(
                displayText(for: cell),
                in: cellRect,
                attributes: nullAttributes
            )
        case .text:
            draw(
                displayText(for: cell),
                in: cellRect,
                attributes: normalAttributes
            )
        case .binary:
            draw(
                displayText(for: cell),
                in: cellRect,
                attributes: binaryAttributes
            )
        }
    }

    private func cellUsesNullStyle(_ cell: WorkspaceDatabaseDataCell) -> Bool {
        switch cell {
        case .null:
            true
        case let .text(value):
            value.isEmpty
        case .binary:
            false
        }
    }

    private func drawActiveCellIndicator(in cellRect: NSRect) {
        let path = NSBezierPath(
            rect: cellRect.insetBy(dx: 1, dy: 1)
        )
        path.lineJoinStyle = .miter
        path.lineWidth = 2
        Self.activeCellIndicatorColor.setStroke()
        path.stroke()
    }

    static var activeCellIndicatorColor: NSColor { .controlAccentColor }

    static func gridSelectionBackgroundColor(
        isWindowKey: Bool
    ) -> NSColor {
        isWindowKey
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
    }

    private func draw(
        _ text: String,
        in cellRect: NSRect,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let textRect = NSRect(
            x: cellRect.minX,
            y: floor(cellRect.midY - lineHeight / 2),
            width: max(
                0,
                cellRect.width - WorkspaceGridMetrics.cellTrailingPadding
            ),
            height: lineHeight
        )
        (text as NSString).draw(
            in: textRect,
            withAttributes: attributes
        )
    }

    private func updateFontIfNeeded(_ font: NSFont) {
        guard
            font.fontName != cellFont.fontName
                || font.pointSize != cellFont.pointSize
        else {
            return
        }

        cellFont = font
        lineHeight = font.lineHeight
        let italicFont = NSFontManager.shared.convert(
            font,
            toHaveTrait: .italicFontMask
        )
        normalAttributes = Self.attributes(
            font: font,
            color: .labelColor,
            paragraphStyle: Self.leadingParagraphStyle
        )
        nullAttributes = Self.attributes(
            font: italicFont,
            color: .tertiaryLabelColor,
            paragraphStyle: Self.leadingParagraphStyle
        )
        binaryAttributes = Self.attributes(
            font: font,
            color: .secondaryLabelColor,
            paragraphStyle: Self.leadingParagraphStyle
        )
        emphasizedSelectedAttributes = Self.selectedCellAttributes(
            font: font,
            isEmphasized: true,
            isPlaceholder: false
        )
        unemphasizedSelectedAttributes = Self.selectedCellAttributes(
            font: font,
            isEmphasized: false,
            isPlaceholder: false
        )
        emphasizedSelectedNullAttributes = Self.selectedCellAttributes(
            font: italicFont,
            isEmphasized: true,
            isPlaceholder: true
        )
        unemphasizedSelectedNullAttributes = Self.selectedCellAttributes(
            font: italicFont,
            isEmphasized: false,
            isPlaceholder: true
        )
        rowNumberAttributes = Self.attributes(
            font: font,
            color: .tertiaryLabelColor,
            paragraphStyle: Self.trailingParagraphStyle
        )
        emphasizedSelectedRowNumberAttributes = Self.attributes(
            font: font,
            color: Self.selectedTextColor(isEmphasized: true),
            paragraphStyle: Self.trailingParagraphStyle
        )
        unemphasizedSelectedRowNumberAttributes = Self.attributes(
            font: font,
            color: Self.selectedTextColor(isEmphasized: false),
            paragraphStyle: Self.trailingParagraphStyle
        )
    }

    static func selectedTextColor(isEmphasized: Bool) -> NSColor {
        isEmphasized
            ? .alternateSelectedControlTextColor
            : .unemphasizedSelectedTextColor
    }

    static func selectedPlaceholderTextColor(isEmphasized: Bool) -> NSColor {
        selectedTextColor(isEmphasized: isEmphasized)
            .withAlphaComponent(0.48)
    }

    static func selectedCellAttributes(
        font: NSFont,
        isEmphasized: Bool,
        isPlaceholder: Bool
    ) -> [NSAttributedString.Key: Any] {
        attributes(
            font: font,
            color: isPlaceholder
                ? selectedPlaceholderTextColor(isEmphasized: isEmphasized)
                : selectedTextColor(isEmphasized: isEmphasized),
            paragraphStyle: leadingParagraphStyle
        )
    }

    static func pendingDraftBackgroundColor(
        isDarkAppearance: Bool
    ) -> NSColor {
        // Preserve the accepted selected-row strength in one background pass.
        NSColor.systemGreen.withAlphaComponent(
            isDarkAppearance ? 0.39 : 0.45
        )
    }

    static func pendingDeletionBackgroundColor(
        isDarkAppearance: Bool
    ) -> NSColor {
        NSColor.systemRed.withAlphaComponent(
            isDarkAppearance ? 0.30 : 0.24
        )
    }

    static func pendingUpdateBackgroundColor(
        isDarkAppearance: Bool
    ) -> NSColor {
        NSColor.systemOrange.withAlphaComponent(
            isDarkAppearance ? 0.30 : 0.24
        )
    }

    static func draftBackgroundColor(
        isDraftRow: Bool,
        isEditing: Bool,
        isWindowKey: Bool,
        isDarkAppearance: Bool
    ) -> NSColor? {
        guard isDraftRow else { return nil }
        guard isEditing && isWindowKey else {
            return pendingDraftBackgroundColor(
                isDarkAppearance: isDarkAppearance
            )
        }
        return .selectedContentBackgroundColor
    }

    private static func attributes(
        font: NSFont,
        color: NSColor,
        paragraphStyle: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private func accessibilityText(
        for cell: WorkspaceDatabaseDataCell,
        insertDraftMode: WorkspaceDatabaseDataRowInsertMode?,
        nullDisplayText: String,
        emptyStringDisplayText: String
    ) -> String {
        if insertDraftMode == .unfilled {
            return AppCopy.current.text(
                "必填列未填写",
                "Required value not entered"
            )
        }
        return switch cell {
        case .null where nullDisplayText.isEmpty:
            "NULL"
        case .text("") where emptyStringDisplayText.isEmpty:
            AppCopy.current.text("空字符串", "Empty string")
        default:
            cell.gridPreviewText(
                nullDisplayText: nullDisplayText,
                emptyStringDisplayText: emptyStringDisplayText,
                maximumCharacterCount: Self.maximumAccessibilityCellCharacters
            )
        }
    }

    private func accessibilitySummary(
        for row: WorkspaceDatabaseDataRow,
        insertDraftModes: [Int: WorkspaceDatabaseDataRowInsertMode]?,
        nullDisplayText: String,
        emptyStringDisplayText: String
    ) -> String {
        var summary = ""
        summary.reserveCapacity(Self.maximumAccessibilityRowCharacters)

        for (index, cell) in row.values.enumerated() {
            let separator = summary.isEmpty ? "" : ", "
            let remaining = Self.maximumAccessibilityRowCharacters
                - summary.count
                - separator.count
            guard remaining > 0 else { break }
            let text = accessibilityText(
                for: cell,
                insertDraftMode: insertDraftModes?[index],
                nullDisplayText: nullDisplayText,
                emptyStringDisplayText: emptyStringDisplayText
            )
            summary += separator
            summary += String(text.prefix(remaining))
        }
        return summary
    }

    private func displayText(
        for cell: WorkspaceDatabaseDataCell
    ) -> String {
        cell.gridPreviewText(
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText,
            maximumCharacterCount: Self.maximumDrawnTextCharacters
        )
    }

    private var usesActiveDraftAppearance: Bool {
        isActiveDraftRow && window?.isKeyWindow == true
    }

    private var isActiveDraftRow: Bool {
        guard insertDraftModes != nil else { return false }
        if isInsertDraftEditing { return true }
        if let tableView = dataTableView as? WorkspaceDirectDrawTableView,
           tableView.gridSelection.active?.row == tableRowIndex
        {
            return true
        }
        return dataTableView?.selectedRowIndexes.contains(tableRowIndex) == true
    }

    var pendingPresentationBackgroundColor: NSColor? {
        if isPendingDeletion {
            return Self.pendingDeletionBackgroundColor(
                isDarkAppearance: usesDarkAppearance
            )
        }
        return Self.draftBackgroundColor(
            isDraftRow: insertDraftModes != nil,
            isEditing: isActiveDraftRow,
            isWindowKey: window?.isKeyWindow == true,
            isDarkAppearance: usesDarkAppearance
        )
    }

    private var usesDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func pendingUpdateBackgroundColor(
        at dataColumnIndex: Int
    ) -> NSColor? {
        guard pendingUpdateColumnIndexes.contains(dataColumnIndex) else {
            return nil
        }
        return Self.pendingUpdateBackgroundColor(
            isDarkAppearance: usesDarkAppearance
        )
    }

    func cellBackgroundColor(
        at dataColumnIndex: Int,
        isGridSelected: Bool,
        isWindowKey: Bool
    ) -> NSColor? {
        if isGridSelected {
            return Self.gridSelectionBackgroundColor(
                isWindowKey: isWindowKey
            )
        }
        guard !isPendingDeletion, insertDraftModes == nil else { return nil }
        return pendingUpdateBackgroundColor(at: dataColumnIndex)
    }
}

private extension NSFont {
    var lineHeight: CGFloat {
        ceil(ascender - descender + leading)
    }
}
