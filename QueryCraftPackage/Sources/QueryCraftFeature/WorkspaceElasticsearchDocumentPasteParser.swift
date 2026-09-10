import CoreFoundation
import Foundation

struct WorkspaceElasticsearchPastedDocument: Sendable {
    let row: WorkspaceDatabaseDataRowInsertDraftRow
    let draft: WorkspaceDocumentCreationDraft
    let sourceText: String
}

enum WorkspaceElasticsearchPasteError: Error, LocalizedError, Equatable {
    case invalidHeader
    case invalidValue(row: Int, field: String)
    case limit

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            AppCopy.current.text(
                "表头必须使用当前表格中的字段名，不能重复；_index 和 _score 仅供读取。",
                "Headers must use unique field names from the current grid; _index and _score are read-only."
            )
        case let .invalidValue(row, field):
            AppCopy.current.text(
                "第 \(row) 行的“\(field)”值与字段类型不符，请检查后重新粘贴。",
                "Row \(row), field \"\(field)\" does not match its field type. Check the value and paste again."
            )
        case .limit:
            AppCopy.current.text(
                "最多暂存 500 篇文档；一次粘贴上限为 8 MiB、100,000 个单元格，每篇文档不超过 1 MiB。",
                "Stage up to 500 documents. Each paste is limited to 8 MiB and 100,000 cells, with at most 1 MiB per document."
            )
        }
    }
}

actor WorkspaceElasticsearchDocumentPasteParser {
    static let shared = WorkspaceElasticsearchDocumentPasteParser()
    private let editor = WorkspaceElasticsearchDocumentCellEditor()

    func parse(
        _ content: WorkspaceGridPasteboardContent,
        targetColumnNames: [String],
        request: WorkspaceDatabaseDataRowInsertRequest,
        targetKind: WorkspaceDocumentCreationTargetKind,
        mappingFields: [WorkspaceDocumentMappingField] = []
    ) async throws -> [WorkspaceElasticsearchPastedDocument] {
        try Task.checkCancellation()
        let mapping = Dictionary(uniqueKeysWithValues: mappingFields.map { ($0.path, $0) })
        let columns = Dictionary(uniqueKeysWithValues: request.columns.map {
            ($0.id, mapping[$0.id].map { $0.hasTypeConflict ? "conflict" : $0.type } ?? $0.column.type)
        })
        let names: [String]
        let rows: [[WorkspaceDatabaseDataCell]]
        let isInternal: Bool
        if let data = content.internalPayload {
            guard data.count <= 8 * 1_024 * 1_024 else { throw WorkspaceElasticsearchPasteError.limit }
            let payload: WorkspaceGridClipboardPayload
            do {
                payload = try JSONDecoder().decode(WorkspaceGridClipboardPayload.self, from: data)
            } catch {
                throw WorkspaceGridPasteError.malformed
            }
            guard payload.version == 1 else { throw WorkspaceGridPasteError.malformed }
            names = payload.columnNames
            rows = payload.rows
            isInternal = true
        } else if let text = content.tabSeparatedText {
            guard text.utf8.count <= 8 * 1_024 * 1_024 else { throw WorkspaceElasticsearchPasteError.limit }
            // The first record determines the delimiter; quoted commas/tabs remain field content.
            let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            let delimiter = try Self.delimiter(in: text)
            let fields: [[String]]
            do {
                fields = try WorkspaceGridPasteParser.parseDelimitedText(text, delimiter: delimiter, maximumRows: 501)
            } catch WorkspaceGridPasteError.tooLarge {
                throw WorkspaceElasticsearchPasteError.limit
            }
            guard let first = fields.first else { throw WorkspaceGridPasteError.malformed }
            let hasHeader = first.contains { columns[$0] != nil || $0 == "_index" || $0 == "_score" }
            if hasHeader {
                names = first
                rows = fields.dropFirst().map { $0.map(WorkspaceDatabaseDataCell.text) }
            } else {
                guard first.count <= targetColumnNames.count else { throw WorkspaceElasticsearchPasteError.invalidHeader }
                names = Array(targetColumnNames.prefix(first.count))
                rows = fields.map { $0.map(WorkspaceDatabaseDataCell.text) }
            }
            isInternal = false
        } else {
            throw WorkspaceGridPasteError.unavailable
        }
        guard !rows.isEmpty else { throw WorkspaceGridPasteError.malformed }
        guard rows.count <= 500, names.count <= 1_000, rows.count * names.count <= 100_000 else {
            throw WorkspaceElasticsearchPasteError.limit
        }
        let ignored: Set<String> = isInternal ? ["_index", "_score"] : []
        guard Set(names).count == names.count,
              names.allSatisfy({ columns[$0] != nil || ignored.contains($0) }),
              names.contains(where: { columns[$0] != nil }) else {
            throw WorkspaceElasticsearchPasteError.invalidHeader
        }
        var result: [WorkspaceElasticsearchPastedDocument] = []
        for (index, cells) in rows.enumerated() {
            try Task.checkCancellation()
            guard cells.count == names.count else { throw WorkspaceGridPasteError.malformed }
            var source: [String: Any] = [:]
            var identity: [String: String] = [:]
            for (name, cell) in zip(names, cells) where !ignored.contains(name) {
                try Task.checkCancellation()
                if name == "_id" || name == "_routing" {
                    switch cell {
                    case .null: identity[name] = ""
                    case let .text(text): identity[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    case .binary: throw WorkspaceGridPasteError.binaryValueUnavailable(name)
                    }
                } else {
                    do {
                        source[name] = try Self.value(cell, type: columns[name] ?? "json", internalCell: isInternal)
                    } catch {
                        throw WorkspaceElasticsearchPasteError.invalidValue(row: index + 1, field: name)
                    }
                }
            }
            let data = try JSONSerialization.data(
                withJSONObject: source,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            guard data.count <= WorkspaceElasticsearchDocumentValidator.maximumByteCount else {
                throw WorkspaceElasticsearchPasteError.limit
            }
            let sourceText = String(decoding: data, as: UTF8.self)
            var drafts = try await editor.creationDrafts(sourceJSON: data, fieldNames: Set(columns.keys))
            for name in ["_id", "_routing"] {
                let text = identity[name] ?? ""
                drafts[name] = WorkspaceDatabaseDataRowInsertDraft(mode: text.isEmpty ? .unfilled : .value, text: text)
            }
            let id = identity["_id"].flatMap { $0.isEmpty ? nil : $0 }
            let routing = identity["_routing"].flatMap { $0.isEmpty ? nil : $0 }
            result.append(WorkspaceElasticsearchPastedDocument(
                row: WorkspaceDatabaseDataRowInsertDraftRow(drafts: drafts, editedColumnNames: Set(names).subtracting(ignored)),
                draft: WorkspaceDocumentCreationDraft(targetName: request.selection.objectName,
                    targetKind: targetKind, id: id, routing: routing, sourceJSON: data),
                sourceText: sourceText
            ))
            if index.isMultiple(of: 32) { await Task.yield() }
        }
        try Task.checkCancellation()
        return result
    }

    private static func value(_ cell: WorkspaceDatabaseDataCell, type: String, internalCell: Bool) throws -> Any {
        guard type != "conflict" else { throw WorkspaceGridPasteError.malformed }
        switch cell {
        case .null: return NSNull()
        case .binary: throw WorkspaceGridPasteError.malformed
        case let .text(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !internalCell && (trimmed == "null" || trimmed == "NULL") { return NSNull() }
            let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            if let array = parsed as? [Any] {
                return try array.map { element in
                    let encoded = try JSONSerialization.data(withJSONObject: element, options: [.fragmentsAllowed])
                    if element is NSNull { return NSNull() as Any }
                    return try value(.text(String(decoding: encoded, as: UTF8.self)), type: type, internalCell: false)
                }
            }
            let stringTypes: Set<String> = ["text", "keyword", "constant_keyword", "wildcard", "version", "ip", "date", "date_nanos"]
            if stringTypes.contains(type.lowercased()) {
                if let string = parsed as? String { return string }
                guard !(parsed is [String: Any]) else { throw WorkspaceGridPasteError.malformed }
                return text
            }
            if type.lowercased() == "boolean" {
                guard let number = parsed as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw WorkspaceGridPasteError.malformed
                }
                return number
            }
            let numeric: Set<String> = ["byte", "short", "integer", "long", "unsigned_long", "half_float", "float", "double", "scaled_float"]
            if numeric.contains(type.lowercased()) {
                guard let number = parsed as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                    throw WorkspaceGridPasteError.malformed
                }
                if ["byte", "short", "integer", "long", "unsigned_long"].contains(type.lowercased()) {
                    var decimal = number.decimalValue
                    var rounded = Decimal()
                    NSDecimalRound(&rounded, &decimal, 0, .plain)
                    guard decimal == rounded else { throw WorkspaceGridPasteError.malformed }
                }
                return number
            }
            if ["object", "nested"].contains(type.lowercased()) {
                guard let object = parsed as? [String: Any] else { throw WorkspaceGridPasteError.malformed }
                return object
            }
            return parsed ?? text
        }
    }

    private static func delimiter(in text: String) throws -> Character {
        var inQuotes = false
        var hasComma = false
        for (index, character) in text.enumerated() {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            if character == "\"" { inQuotes.toggle() }
            if !inQuotes {
                if character == "\t" { return "\t" }
                if character == "," { hasComma = true }
                if character == "\n" || character == "\r" || character == "\r\n" { break }
            }
        }
        return hasComma ? "," : "\t"
    }
}
