import Foundation

struct WorkspaceDatabaseDataRowInsertRequest: Equatable, Identifiable, Sendable {
    let id = UUID()
    let selection: WorkspaceDatabaseObjectSelection
    let columns: [WorkspaceDatabaseDataRowInsertColumn]

    static func make(
        selection: WorkspaceDatabaseObjectSelection,
        details: WorkspaceDatabaseObjectDetails
    ) throws -> Self {
        guard selection.kind == .table else {
            throw WorkspaceDatabaseDataRowInsertError.tableRequired
        }
        let columns: [WorkspaceDatabaseDataRowInsertColumn] =
            details.columns.compactMap { column in
            guard !column.isGenerated else { return nil }
            return WorkspaceDatabaseDataRowInsertColumn(column: column)
        }
        return Self(selection: selection, columns: columns)
    }

    static func makeElasticsearchDocument(
        selection: WorkspaceDatabaseObjectSelection,
        pageColumns: [WorkspaceDatabaseDataColumn]
    ) -> Self {
        let metadataNames = Set(["_id", "_index", "_score", "_routing"])
        let sourceColumns = pageColumns.compactMap { column ->
            WorkspaceDatabaseDataRowInsertColumn? in
            guard !metadataNames.contains(column.name) else { return nil }
            return WorkspaceDatabaseDataRowInsertColumn(
                column: WorkspaceDatabaseColumn(
                    name: column.name,
                    type: column.type ?? "json",
                    collation: nil,
                    isNullable: true,
                    key: "",
                    defaultValue: nil,
                    extra: "",
                    comment: ""
                )
            )
        }
        let identityColumns = ["_id", "_routing"].map { name in
            WorkspaceDatabaseDataRowInsertColumn(
                column: WorkspaceDatabaseColumn(
                    name: name,
                    type: "keyword",
                    collation: nil,
                    isNullable: false,
                    key: "",
                    defaultValue: nil,
                    extra: "",
                    comment: ""
                )
            )
        }
        return Self(
            selection: selection,
            columns: sourceColumns + identityColumns
        )
    }

    func makeInsert(
        drafts: [String: WorkspaceDatabaseDataRowInsertDraft]
    ) -> WorkspaceDatabaseDataRowInsert {
        makeInsert(
            drafts: drafts,
            includedColumnNames: Set(columns.map(\.id))
        )
    }

    func makeInsert(
        drafts: [String: WorkspaceDatabaseDataRowInsertDraft],
        includedColumnNames: Set<String>
    ) -> WorkspaceDatabaseDataRowInsert {
        let values: [WorkspaceDatabaseDataRowInsertValue] =
            columns.compactMap { column in
            guard includedColumnNames.contains(column.id) else { return nil }
            let draft = drafts[column.id] ?? column.initialDraft
            switch draft.mode {
            case .unfilled, .useDefault:
                return nil
            case .null:
                return WorkspaceDatabaseDataRowInsertValue(
                    columnName: column.column.name,
                    value: .null
                )
            case .value:
                return WorkspaceDatabaseDataRowInsertValue(
                    columnName: column.column.name,
                    value: .text(draft.text)
                )
            }
        }
        return WorkspaceDatabaseDataRowInsert(
            selection: selection,
            values: values
        )
    }
}

struct WorkspaceDatabaseDataRowInsertColumn: Equatable, Identifiable, Sendable {
    let column: WorkspaceDatabaseColumn

    var id: String { column.name }

    var canUseDefault: Bool {
        column.defaultValue != nil
            || column.extra.localizedCaseInsensitiveContains("auto_increment")
            || column.extra.localizedCaseInsensitiveContains("identity")
            || column.extra.localizedCaseInsensitiveContains("default_generated")
    }

    var isAutoIncrement: Bool {
        column.extra.localizedCaseInsensitiveContains("auto_increment")
            || column.extra.localizedCaseInsensitiveContains("identity")
    }

    private var initialMode: WorkspaceDatabaseDataRowInsertMode {
        if canUseDefault {
            return .useDefault
        }
        if column.isNullable {
            return .null
        }
        return .unfilled
    }

    var initialDraft: WorkspaceDatabaseDataRowInsertDraft {
        WorkspaceDatabaseDataRowInsertDraft(
            mode: initialMode,
            text: ""
        )
    }
}

struct WorkspaceDatabaseDataRowInsertDraft: Equatable, Sendable {
    var mode: WorkspaceDatabaseDataRowInsertMode
    var text: String
}

enum WorkspaceDatabaseDataRowInsertMode: String, CaseIterable, Sendable {
    case unfilled
    case useDefault
    case null
    case value
}
