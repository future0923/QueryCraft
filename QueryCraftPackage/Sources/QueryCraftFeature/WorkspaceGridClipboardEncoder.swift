import AppKit

struct WorkspaceGridCopyColumn: Equatable, Sendable {
    let name: String
    let dataIndex: Int
}

enum WorkspaceGridCopyRows: Sendable {
    case range(ClosedRange<Int>)
    case indexes(IndexSet)

    var count: Int {
        switch self {
        case let .range(range):
            range.count
        case let .indexes(indexes):
            indexes.count
        }
    }

    var first: Int? {
        switch self {
        case let .range(range):
            range.first
        case let .indexes(indexes):
            indexes.first
        }
    }

    func forEach(_ body: (Int) -> Bool) -> Bool {
        switch self {
        case let .range(range):
            for row in range where !body(row) {
                return false
            }
        case let .indexes(indexes):
            for row in indexes where !body(row) {
                return false
            }
        }
        return true
    }
}

struct WorkspaceGridCopySnapshot: Sendable {
    let rowAt: @Sendable (Int) -> WorkspaceDatabaseDataRow?
    let requiresBackgroundEncoding: Bool

    init(
        rowAt: @escaping @Sendable (Int) -> WorkspaceDatabaseDataRow?,
        requiresBackgroundEncoding: Bool = false
    ) {
        self.rowAt = rowAt
        self.requiresBackgroundEncoding = requiresBackgroundEncoding
    }
}

enum WorkspaceGridClipboardEncoder {
    static let tabSeparatedTextType = NSPasteboard.PasteboardType(
        "public.utf8-tab-separated-values-text"
    )

    static func encode(
        rows: WorkspaceGridCopyRows,
        columns: [WorkspaceGridCopyColumn],
        includesColumnNames: Bool,
        nullDisplayText: String = "NULL",
        emptyStringDisplayText: String = "",
        rowAt: @Sendable (Int) -> WorkspaceDatabaseDataRow?
    ) -> String? {
        guard rows.count > 0, !columns.isEmpty else { return nil }

        let isSingleCell = rows.count == 1
            && columns.count == 1
            && !includesColumnNames
        if isSingleCell {
            guard let rowIndex = rows.first,
                  let row = rowAt(rowIndex) else {
                return nil
            }
            return copyText(
                for: row.value(at: columns[0].dataIndex),
                nullDisplayText: nullDisplayText,
                emptyStringDisplayText: emptyStringDisplayText
            )
        }

        var output = ""
        var hasLine = false
        if includesColumnNames {
            appendLine(
                fieldCount: columns.count,
                fieldAt: { columns[$0].name },
                to: &output,
                hasLine: &hasLine
            )
        }

        let encodedAllRows = rows.forEach { rowIndex in
            guard !Task.isCancelled, let row = rowAt(rowIndex) else {
                return false
            }
            appendLine(
                fieldCount: columns.count,
                fieldAt: {
                    copyText(
                        for: row.value(at: columns[$0].dataIndex),
                        nullDisplayText: nullDisplayText,
                        emptyStringDisplayText: emptyStringDisplayText
                    )
                },
                to: &output,
                hasLine: &hasLine
            )
            return true
        }
        return encodedAllRows ? output : nil
    }

    static func write(_ text: String, to pasteboard: NSPasteboard) {
        write(text, internalPayload: nil, to: pasteboard)
    }

    static func encodeInternalPayload(
        rows: WorkspaceGridCopyRows,
        columns: [WorkspaceGridCopyColumn],
        rowAt: @Sendable (Int) -> WorkspaceDatabaseDataRow?
    ) -> Data? {
        guard rows.count > 0, !columns.isEmpty else { return nil }
        var copiedRows: [[WorkspaceDatabaseDataCell]] = []
        copiedRows.reserveCapacity(rows.count)
        let encodedAllRows = rows.forEach { rowIndex in
            guard !Task.isCancelled, let row = rowAt(rowIndex) else {
                return false
            }
            copiedRows.append(
                columns.map { row.value(at: $0.dataIndex) }
            )
            return true
        }
        guard encodedAllRows else { return nil }
        return try? JSONEncoder().encode(
            WorkspaceGridClipboardPayload(
                columnNames: columns.map(\.name),
                rows: copiedRows
            )
        )
    }

    static func write(
        _ text: String,
        internalPayload: Data?,
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(text, forType: tabSeparatedTextType)
        if let internalPayload {
            pasteboard.setData(
                internalPayload,
                forType: WorkspaceGridClipboardPayload.pasteboardType
            )
        }
    }

    private static func copyText(
        for cell: WorkspaceDatabaseDataCell,
        nullDisplayText: String,
        emptyStringDisplayText: String
    ) -> String {
        switch cell {
        case .null:
            nullDisplayText
        case let .text(value):
            value.isEmpty ? emptyStringDisplayText : value
        case let .binary(byteCount, _):
            "<BINARY \(byteCount) bytes>"
        }
    }

    private static func tsvField(_ value: String) -> String {
        guard value.contains(where: { character in
            character == "\t"
                || character == "\n"
                || character == "\r"
                || character == "\""
        }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func appendLine(
        fieldCount: Int,
        fieldAt: (Int) -> String,
        to output: inout String,
        hasLine: inout Bool
    ) {
        if hasLine {
            output.append("\n")
        }
        for offset in 0..<fieldCount {
            if offset > 0 {
                output.append("\t")
            }
            output.append(tsvField(fieldAt(offset)))
        }
        hasLine = true
    }
}
