import AppKit

@MainActor
enum WorkspaceGridMetrics {
    static let cellFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.systemFontSize,
        weight: .regular
    )
    static let headerFont = NSFont.systemFont(
        ofSize: NSFont.systemFontSize,
        weight: .bold
    )
    static let headerHeight: CGFloat = 28
    static let headerBackgroundColor = NSColor.labelColor
        .withAlphaComponent(0.08)
    static let cellTrailingPadding: CGFloat = 8

    static func configureHeaderCell(_ headerCell: NSTableHeaderCell) {
        headerCell.alignment = .left
        headerCell.font = headerFont
        headerCell.textColor = .labelColor
    }
}

@MainActor
enum WorkspaceGridColumnSizing {
    static let minimumColumnWidth: CGFloat = 60
    static let maximumAutomaticColumnWidth: CGFloat = 480
    static let sampleRowCount = 30
    static let wideGridSampleRowCount = 10
    static let wideGridColumnThreshold = 50
    static let maximumMeasuredCharacters = 50

    private static let headerHorizontalPadding: CGFloat = 8

    static func automaticWidths(
        columns: [WorkspaceDatabaseDataColumn],
        rowCount: Int,
        maximumConsideredRows: Int?,
        rowAt: (Int) -> WorkspaceDatabaseDataRow?,
        nullDisplayText: String = "NULL",
        emptyStringDisplayText: String = "",
        cellFont: NSFont = WorkspaceGridMetrics.cellFont
    ) -> [Int: CGFloat] {
        let consideredRowCount = maximumConsideredRows.map {
            min(rowCount, $0)
        } ?? rowCount
        let sampleIndexes = sampleIndexes(
            rowCount: consideredRowCount,
            columnCount: columns.count
        )
        let sampleRows = sampleIndexes.compactMap(rowAt)

        return Dictionary(uniqueKeysWithValues: columns.map { column in
            var width = measuredWidth(
                column.name,
                font: WorkspaceGridMetrics.headerFont
            )
                + headerHorizontalPadding
            for row in sampleRows {
                let text = measurementText(
                    row.value(at: column.id).gridPreviewText(
                        nullDisplayText: nullDisplayText,
                        emptyStringDisplayText: emptyStringDisplayText,
                        maximumCharacterCount: maximumMeasuredCharacters
                    )
                )
                width = max(
                    width,
                    measuredWidth(text, font: cellFont)
                        + WorkspaceGridMetrics.cellTrailingPadding
                )
                if width >= maximumAutomaticColumnWidth {
                    break
                }
            }
            return (
                column.id,
                min(
                    max(ceil(width), minimumColumnWidth),
                    maximumAutomaticColumnWidth
                )
            )
        })
    }

    static func sampleIndexes(
        rowCount: Int,
        columnCount: Int
    ) -> [Int] {
        guard rowCount > 0 else { return [] }
        let maximumSamples = columnCount > wideGridColumnThreshold
            ? wideGridSampleRowCount
            : sampleRowCount
        guard rowCount > maximumSamples else {
            return Array(0..<rowCount)
        }
        let leadingSampleCount = maximumSamples / 2
        let distributedSampleCount = maximumSamples - leadingSampleCount
        var indexes = Array(0..<leadingSampleCount)
        guard distributedSampleCount > 1 else {
            indexes.append(rowCount - 1)
            return indexes
        }

        indexes.append(contentsOf: (0..<distributedSampleCount).map {
            sampleIndex in
            leadingSampleCount
                + sampleIndex * (rowCount - 1 - leadingSampleCount)
                    / (distributedSampleCount - 1)
        })
        return indexes
    }

    private static func measuredWidth(
        _ text: String,
        font: NSFont
    ) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func measurementText(_ text: String) -> String {
        String(text.prefix(maximumMeasuredCharacters))
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
