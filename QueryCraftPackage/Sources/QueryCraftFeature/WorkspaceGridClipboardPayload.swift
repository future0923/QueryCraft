import AppKit
import Foundation

typealias WorkspaceGridPasteRowsAction = @MainActor (
    WorkspaceGridPasteboardContent,
    [String],
    UUID?
) -> Void

struct WorkspaceGridPasteboardContent: Sendable {
    let internalPayload: Data?
    let tabSeparatedText: String?

    @MainActor
    static func read(from pasteboard: NSPasteboard) -> Self {
        Self(
            internalPayload: pasteboard.data(
                forType: WorkspaceGridClipboardPayload.pasteboardType
            ),
            tabSeparatedText: pasteboard.string(
                forType: WorkspaceGridClipboardEncoder.tabSeparatedTextType
            ) ?? pasteboard.string(forType: .string)
        )
    }
}

struct WorkspaceGridClipboardPayload: Codable, Equatable, Sendable {
    static let pasteboardType = NSPasteboard.PasteboardType(
        "com.querycraft.grid-rows-v1"
    )

    let version: Int
    let columnNames: [String]
    let rows: [[WorkspaceDatabaseDataCell]]

    init(
        columnNames: [String],
        rows: [[WorkspaceDatabaseDataCell]]
    ) {
        version = 1
        self.columnNames = columnNames
        self.rows = rows
    }
}

enum WorkspaceGridPasteError: Error, Equatable {
    case unavailable
    case malformed
    case tooLarge
    case noWritableColumns
    case binaryValueUnavailable(String)
}

extension WorkspaceGridPasteError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            AppCopy.current.text(
                "剪贴板中没有可粘贴的表格数据。",
                "The clipboard does not contain tabular data that can be pasted."
            )
        case .malformed:
            AppCopy.current.text(
                "剪贴板中的表格数据格式不完整。",
                "The tabular data on the clipboard is malformed."
            )
        case .tooLarge:
            AppCopy.current.text(
                "一次最多粘贴 1,000 行、100,000 个单元格。",
                "Paste is limited to 1,000 rows and 100,000 cells at a time."
            )
        case .noWritableColumns:
            AppCopy.current.text(
                "粘贴内容没有对应到可写入的列。请先选中目标列。",
                "The pasted data does not map to any writable columns. Select a target column first."
            )
        case let .binaryValueUnavailable(columnName):
            AppCopy.current.text(
                "列“\(columnName)”只保留了二进制值大小，无法粘贴。",
                "Column \"\(columnName)\" retains only the binary value size and cannot be pasted."
            )
        }
    }
}

actor WorkspaceGridPasteParser {
    static let shared = WorkspaceGridPasteParser()

    private static let maximumRows = 1_000
    private static let maximumColumns = 1_000
    private static let maximumCells = 100_000
    private static let maximumUTF8Bytes = 8 * 1_024 * 1_024

    func makeDraftRows(
        from content: WorkspaceGridPasteboardContent,
        targetColumnNames: [String],
        request: WorkspaceDatabaseDataRowInsertRequest
    ) throws -> [WorkspaceDatabaseDataRowInsertDraftRow] {
        let source: PasteSource
        if let data = content.internalPayload {
            guard data.count <= Self.maximumUTF8Bytes else {
                throw WorkspaceGridPasteError.tooLarge
            }
            let payload: WorkspaceGridClipboardPayload
            do {
                payload = try JSONDecoder().decode(
                    WorkspaceGridClipboardPayload.self,
                    from: data
                )
            } catch {
                throw WorkspaceGridPasteError.malformed
            }
            guard payload.version == 1 else {
                throw WorkspaceGridPasteError.malformed
            }
            guard payload.rows.allSatisfy({
                $0.count == payload.columnNames.count
            }) else {
                throw WorkspaceGridPasteError.malformed
            }
            try validate(
                rows: payload.rows,
                columnCount: payload.columnNames.count
            )
            source = .named(
                columnNames: payload.columnNames,
                rows: payload.rows
            )
        } else if let text = content.tabSeparatedText {
            guard text.utf8.count <= Self.maximumUTF8Bytes else {
                throw WorkspaceGridPasteError.tooLarge
            }
            let fields = try Self.parseDelimitedText(text)
            let rows = fields.map { row in
                row.map { value in
                    value == "NULL"
                        ? WorkspaceDatabaseDataCell.null
                        : WorkspaceDatabaseDataCell.text(value)
                }
            }
            try validate(
                rows: rows,
                columnCount: rows.map(\.count).max() ?? 0
            )
            source = .positional(
                targetColumnNames: targetColumnNames,
                rows: rows
            )
        } else {
            throw WorkspaceGridPasteError.unavailable
        }

        return try makeDraftRows(source: source, request: request)
    }

    private func makeDraftRows(
        source: PasteSource,
        request: WorkspaceDatabaseDataRowInsertRequest
    ) throws -> [WorkspaceDatabaseDataRowInsertDraftRow] {
        var mappedAnyColumn = false
        let rows: [WorkspaceDatabaseDataRowInsertDraftRow]
        switch source {
        case let .named(columnNames, sourceRows):
            rows = try sourceRows.map { sourceRow in
                try makeDraftRow(
                    cells: sourceRow,
                    targetNameAt: { index in
                        columnNames.indices.contains(index)
                            ? columnNames[index]
                            : nil
                    },
                    request: request,
                    mappedAnyColumn: &mappedAnyColumn
                )
            }
        case let .positional(targetColumnNames, sourceRows):
            rows = try sourceRows.map { sourceRow in
                try makeDraftRow(
                    cells: sourceRow,
                    targetNameAt: { index in
                        targetColumnNames.indices.contains(index)
                            ? targetColumnNames[index]
                            : nil
                    },
                    request: request,
                    mappedAnyColumn: &mappedAnyColumn
                )
            }
        }
        guard mappedAnyColumn, !rows.isEmpty else {
            throw WorkspaceGridPasteError.noWritableColumns
        }
        return rows
    }

    private func makeDraftRow(
        cells: [WorkspaceDatabaseDataCell],
        targetNameAt: (Int) -> String?,
        request: WorkspaceDatabaseDataRowInsertRequest,
        mappedAnyColumn: inout Bool
    ) throws -> WorkspaceDatabaseDataRowInsertDraftRow {
        var row = WorkspaceDatabaseDataRowInsertDraftRow(
            drafts: Dictionary(
                uniqueKeysWithValues: request.columns.map {
                    ($0.id, $0.initialDraft)
                }
            )
        )
        for (index, cell) in cells.enumerated() {
            guard
                let targetName = targetNameAt(index),
                let column = request.columns.first(where: {
                    $0.id == targetName
                        || $0.id.caseInsensitiveCompare(targetName) == .orderedSame
                }),
                !column.isAutoIncrement
            else {
                continue
            }
            switch cell {
            case .null:
                row.drafts[column.id] = WorkspaceDatabaseDataRowInsertDraft(
                    mode: .null,
                    text: ""
                )
            case let .text(text):
                row.drafts[column.id] = WorkspaceDatabaseDataRowInsertDraft(
                    mode: .value,
                    text: text
                )
            case .binary:
                throw WorkspaceGridPasteError.binaryValueUnavailable(column.id)
            }
            row.editedColumnNames.insert(column.id)
            mappedAnyColumn = true
        }
        return row
    }

    private func validate(
        rows: [[WorkspaceDatabaseDataCell]],
        columnCount: Int
    ) throws {
        guard
            !rows.isEmpty,
            rows.count <= Self.maximumRows,
            columnCount <= Self.maximumColumns
        else {
            throw rows.isEmpty
                ? WorkspaceGridPasteError.malformed
                : WorkspaceGridPasteError.tooLarge
        }
        var cellCount = 0
        for row in rows {
            try Task.checkCancellation()
            guard row.count <= Self.maximumColumns else {
                throw WorkspaceGridPasteError.tooLarge
            }
            let addition = cellCount.addingReportingOverflow(row.count)
            guard
                !addition.overflow,
                addition.partialValue <= Self.maximumCells
            else {
                throw WorkspaceGridPasteError.tooLarge
            }
            cellCount = addition.partialValue
        }
    }

    nonisolated static func parseDelimitedText(
        _ text: String, delimiter: Character = "\t", maximumRows: Int = 1_000
    ) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var closedQuote = false
        var endedWithRowSeparator = false
        var processedCharacters = 0
        var index = text.startIndex

        func appendField() throws {
            row.append(field)
            field.removeAll(keepingCapacity: true)
            closedQuote = false
            guard row.count <= Self.maximumColumns else {
                throw WorkspaceGridPasteError.tooLarge
            }
        }

        func appendRow() throws {
            try appendField()
            rows.append(row)
            row.removeAll(keepingCapacity: true)
            guard rows.count <= maximumRows else {
                throw WorkspaceGridPasteError.tooLarge
            }
        }

        while index < text.endIndex {
            if processedCharacters.isMultiple(of: 4_096) {
                try Task.checkCancellation()
            }
            processedCharacters += 1
            let character = text[index]
            let next = text.index(after: index)
            if inQuotes {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                    } else {
                        inQuotes = false
                        closedQuote = true
                        index = next
                    }
                } else {
                    field.append(character)
                    index = next
                }
                endedWithRowSeparator = false
                continue
            }

            if closedQuote,
               character != delimiter,
               character != "\n",
               character != "\r",
               character != "\r\n"
            {
                throw WorkspaceGridPasteError.malformed
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
                endedWithRowSeparator = false
                index = next
            case delimiter:
                try appendField()
                endedWithRowSeparator = false
                index = next
            case "\n", "\r\n":
                try appendRow()
                endedWithRowSeparator = true
                index = next
            case "\r":
                try appendRow()
                endedWithRowSeparator = true
                if next < text.endIndex, text[next] == "\n" {
                    index = text.index(after: next)
                } else {
                    index = next
                }
            default:
                field.append(character)
                endedWithRowSeparator = false
                index = next
            }
        }
        guard !inQuotes else {
            throw WorkspaceGridPasteError.malformed
        }
        if !endedWithRowSeparator || rows.isEmpty {
            try appendRow()
        }
        return rows
    }

    private enum PasteSource {
        case named(
            columnNames: [String],
            rows: [[WorkspaceDatabaseDataCell]]
        )
        case positional(
            targetColumnNames: [String],
            rows: [[WorkspaceDatabaseDataCell]]
        )
    }
}
