import Foundation

actor WorkspaceElasticsearchDocumentCellEditor {
    nonisolated static let readOnlyMetadataFieldNames: Set<String> = [
        "_id", "_index", "_score", "_routing",
    ]

    nonisolated static func canEdit(fieldName: String) -> Bool {
        !readOnlyMetadataFieldNames.contains(fieldName)
    }

    struct InitialValue: Equatable, Sendable {
        let text: String
        let mutation: WorkspaceDatabaseInspectorMutation
    }

    func initialValue(
        sourceJSON: Data,
        fieldName: String
    ) throws -> InitialValue {
        let source = try sourceObject(from: sourceJSON)
        guard let value = source[fieldName] else {
            return InitialValue(text: "", mutation: .null)
        }
        if value is NSNull {
            return InitialValue(text: "", mutation: .null)
        }
        let text = try editableText(for: value)
        return InitialValue(text: text, mutation: .value(text))
    }

    nonisolated static func cellValue(
        forInput text: String
    ) -> WorkspaceDatabaseDataCell {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "null"
            ? .null
            : .text(text)
    }

    func replacingFields(
        in sourceJSON: Data,
        edits: [String: WorkspaceDatabaseDataCell]
    ) throws -> Data {
        var source = try sourceObject(from: sourceJSON)
        for (fieldName, cell) in edits {
            try Task.checkCancellation()
            source[fieldName] = try jsonValue(for: cell)
        }
        try Task.checkCancellation()
        return try JSONSerialization.data(
            withJSONObject: source,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    func changedFieldsJSON(
        edits: [String: WorkspaceDatabaseDataCell]
    ) throws -> Data {
        guard !edits.isEmpty else {
            throw WorkspaceDocumentEditingError.invalidSource
        }
        var changedFields: [String: Any] = [:]
        for (fieldName, cell) in edits {
            try Task.checkCancellation()
            guard Self.canEdit(fieldName: fieldName) else {
                throw WorkspaceDocumentEditingError.invalidSource
            }
            changedFields[fieldName] = try jsonValue(for: cell)
        }
        try Task.checkCancellation()
        return try JSONSerialization.data(
            withJSONObject: changedFields,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    func normalizedEdits(
        in sourceJSON: Data,
        edits: [String: WorkspaceDatabaseDataCell]
    ) throws -> [String: WorkspaceDatabaseDataCell] {
        let source = try sourceObject(from: sourceJSON)
        var result: [String: WorkspaceDatabaseDataCell] = [:]
        for (field, cell) in edits {
            try Task.checkCancellation()
            guard Self.canEdit(fieldName: field) else { throw WorkspaceDocumentEditingError.invalidSource }
            let value = try jsonValue(for: cell)
            // JSON encoding distinguishes strings, booleans, numbers and explicit null.
            if let original = source[field] {
                let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
                if try JSONSerialization.data(withJSONObject: original, options: options)
                    == JSONSerialization.data(withJSONObject: value, options: options) { continue }
            }
            result[field] = cell
        }
        return result
    }

    func sourceText(_ sourceJSON: Data) -> String {
        String(decoding: sourceJSON, as: UTF8.self)
    }

    func creationDrafts(
        sourceJSON: Data,
        fieldNames: Set<String>
    ) throws -> [String: WorkspaceDatabaseDataRowInsertDraft] {
        let source = try sourceObject(from: sourceJSON)
        var drafts: [String: WorkspaceDatabaseDataRowInsertDraft] = [:]
        for fieldName in fieldNames {
            try Task.checkCancellation()
            guard let value = source[fieldName] else { continue }
            if value is NSNull {
                drafts[fieldName] = WorkspaceDatabaseDataRowInsertDraft(
                    mode: .null,
                    text: ""
                )
            } else {
                drafts[fieldName] = WorkspaceDatabaseDataRowInsertDraft(
                    mode: .value,
                    text: try editableText(for: value)
                )
            }
        }
        return drafts
    }

    private func sourceObject(from data: Data) throws -> [String: Any] {
        guard
            let source = try? JSONSerialization.jsonObject(with: data),
            let object = source as? [String: Any]
        else {
            throw WorkspaceDocumentEditingError.invalidSource
        }
        return object
    }

    private func editableText(for value: Any) throws -> String {
        if let string = value as? String {
            let parsed = parsedInputValue(string)
            if let parsedString = parsed as? String, parsedString == string {
                return string
            }
            let data = try JSONSerialization.data(
                withJSONObject: string,
                options: [.fragmentsAllowed, .withoutEscapingSlashes]
            )
            guard let text = String(data: data, encoding: .utf8) else {
                throw WorkspaceDocumentEditingError.invalidSource
            }
            return text
        }
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceDocumentEditingError.invalidSource
        }
        return text
    }

    private func parsedInputValue(_ text: String) -> Any {
        guard !text.isEmpty else { return "" }
        let data = Data(text.utf8)
        return (try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )) ?? text
    }

    private func jsonValue(for cell: WorkspaceDatabaseDataCell) throws -> Any {
        switch cell {
        case .null:
            NSNull()
        case let .text(text):
            parsedInputValue(text)
        case .binary:
            throw WorkspaceDocumentEditingError.invalidSource
        }
    }
}
