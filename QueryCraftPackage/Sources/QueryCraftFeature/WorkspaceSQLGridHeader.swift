import AppKit

struct WorkspaceSQLGridHeaderConfiguration: Equatable {
    var showsComments = true
    var showsTypes = true
    var columnDetails: [Int: WorkspaceDatabaseColumn] = [:]
    var scope = ""
    var retainsMissingDetails = false

    @MainActor var height: CGFloat {
        WorkspaceGridMetrics.headerHeight
            + CGFloat((showsComments ? 1 : 0) + (showsTypes ? 1 : 0)) * 18
    }
}

@MainActor
enum WorkspaceSQLGridHeader {
    static func commentColor(isDark: Bool) -> NSColor {
        // Keep comments equally readable on the header and inspector backgrounds.
        NSColor(srgbRed: isDark ? 0.65 : 0.52,
                green: isDark ? 0.65 : 0.52,
                blue: isDark ? 0.65 : 0.52,
                alpha: 1)
    }

    static func configure(
        in tableView: NSTableView,
        columns: [WorkspaceDatabaseDataColumn],
        configuration: WorkspaceSQLGridHeaderConfiguration?
    ) {
        guard let headerView = tableView.headerView as? WorkspaceGridHeaderView else { return }
        var configuration = configuration
        if var incoming = configuration,
           incoming.retainsMissingDetails,
           let previous = headerView.sqlHeaderConfiguration,
           incoming.scope == previous.scope {
            incoming.columnDetails = previous.columnDetails.merging(incoming.columnDetails) { _, new in new }
            configuration = incoming
        }
        headerView.sqlHeaderConfiguration = configuration
        let height = configuration?.height ?? WorkspaceGridMetrics.headerHeight
        if headerView.frame.height != height {
            headerView.frame.size.height = height
            tableView.enclosingScrollView?.tile()
        }
        let columnsByID = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
        for tableColumn in tableView.tableColumns {
            guard let id = Int(tableColumn.identifier.rawValue.split(separator: ".").last ?? ""),
                  let column = columnsByID[id] else { continue }
            guard let configuration else {
                if tableColumn.headerCell is WorkspaceSQLGridHeaderCell {
                    tableColumn.headerCell = NSTableHeaderCell(textCell: column.name)
                    WorkspaceGridMetrics.configureHeaderCell(tableColumn.headerCell)
                    tableColumn.headerToolTip = nil
                }
                continue
            }
            let cell: WorkspaceSQLGridHeaderCell
            if let existing = tableColumn.headerCell as? WorkspaceSQLGridHeaderCell {
                cell = existing
            } else {
                cell = WorkspaceSQLGridHeaderCell(textCell: column.name)
                WorkspaceGridMetrics.configureHeaderCell(cell)
                cell.setAccessibilityIdentifier(tableColumn.headerCell.accessibilityIdentifier())
                tableColumn.headerCell = cell
            }
            let details = configuration.columnDetails[id]
            cell.comment = details?.comment ?? ""
            // Expressions have their own result type and no source-column comment.
            cell.columnType = details?.type ?? column.type ?? ""
            cell.showsComments = configuration.showsComments
            cell.showsTypes = configuration.showsTypes
            let tooltip = ([column.name]
                + (configuration.showsComments ? [cell.comment] : [])
                + (configuration.showsTypes ? [cell.columnType] : []))
                .filter { !$0.isEmpty }.joined(separator: "\n")
            tableColumn.headerToolTip = tooltip
            cell.setAccessibilityLabel(tooltip)
        }
        headerView.needsLayout = true
        headerView.needsDisplay = true
    }
}

final class WorkspaceSQLGridHeaderCell: NSTableHeaderCell {
    var comment = ""
    var columnType = ""
    var showsComments = true
    var showsTypes = true
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let lineHeight: CGFloat = 18
        let count = 1 + (showsComments ? 1 : 0) + (showsTypes ? 1 : 0)
        let padding = max(0, (cellFrame.height - CGFloat(count) * lineHeight) / 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        var lines: [(String, NSFont, NSColor)] = [
            (stringValue, font ?? WorkspaceGridMetrics.headerFont, textColor ?? .labelColor),
        ]
        if showsComments {
            let isDark = controlView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            lines.append((comment, .systemFont(ofSize: 11), WorkspaceSQLGridHeader.commentColor(isDark: isDark)))
        }
        if showsTypes {
            lines.append((columnType, .monospacedSystemFont(ofSize: 11, weight: .regular), .secondaryLabelColor))
        }
        for (index, line) in lines.enumerated() {
            let y = controlView.isFlipped
                ? cellFrame.minY + padding + CGFloat(index) * lineHeight
                : cellFrame.maxY - padding - CGFloat(index + 1) * lineHeight
            let rect = NSRect(
                x: cellFrame.minX + 6,
                y: y + (lineHeight - line.1.ascender + line.1.descender) / 2,
                width: max(0, cellFrame.width - (index == 0 ? 24 : 12)),
                height: lineHeight
            )
            let text = line.0.components(separatedBy: .newlines).joined(separator: " ")
            (text as NSString).draw(in: rect, withAttributes: [
                .font: line.1,
                .foregroundColor: line.2,
                .paragraphStyle: paragraph,
            ])
        }
        if let header = controlView as? NSTableHeaderView,
           let table = header.tableView,
           let column = table.tableColumns.first(where: { $0.headerCell === self }),
           let indicator = table.indicatorImage(in: column) {
            let image = indicator.withSymbolConfiguration(
                .init(paletteColors: [textColor ?? .labelColor])
            ) ?? (indicator.copy() as? NSImage) ?? indicator
            image.isTemplate = false
            let y = controlView.isFlipped
                ? cellFrame.minY + padding + 4
                : cellFrame.maxY - padding - 14
            image.draw(
                in: NSRect(x: cellFrame.maxX - 16, y: y, width: 10, height: 10),
                from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil
            )
        }
    }

    override func drawSortIndicator(
        withFrame cellFrame: NSRect,
        in controlView: NSView,
        ascending: Bool,
        priority: Int
    ) {
        // Draw the table's indicator beside the name in drawInterior instead.
    }
}
