import Foundation

struct WorkspaceQueryResultInspectorContext: Equatable {
    let resultID: UUID?
    let pageRevision: UUID?
    let columns: [WorkspaceDatabaseDataColumn]
    let selectedRowIndex: Int?
    let row: WorkspaceDatabaseDataRow?
    let isLoading: Bool
    let dataFields: [WorkspaceDatabaseInspectorField]?
    let isUpdatingValue: Bool
    let applyMutation: @MainActor (
        WorkspaceDatabaseInspectorField,
        WorkspaceDatabaseInspectorMutation
    ) -> Void

    static let empty = WorkspaceQueryResultInspectorContext(
        resultID: nil,
        pageRevision: nil,
        columns: [],
        selectedRowIndex: nil,
        row: nil,
        isLoading: false,
        dataFields: nil,
        isUpdatingValue: false,
        applyMutation: { _, _ in }
    )

    init(
        page: WorkspaceQueryResultPage?,
        selectedRowIndex: Int? = nil,
        row: WorkspaceDatabaseDataRow? = nil,
        isLoading: Bool = false
    ) {
        resultID = page?.store.id
        pageRevision = page?.revision
        columns = page?.columns ?? []
        self.selectedRowIndex = selectedRowIndex
        self.row = row
        self.isLoading = isLoading
        dataFields = nil
        isUpdatingValue = false
        applyMutation = { _, _ in }
    }

    private init(
        resultID: UUID?,
        pageRevision: UUID?,
        columns: [WorkspaceDatabaseDataColumn],
        selectedRowIndex: Int?,
        row: WorkspaceDatabaseDataRow?,
        isLoading: Bool,
        dataFields: [WorkspaceDatabaseInspectorField]?,
        isUpdatingValue: Bool,
        applyMutation: @escaping @MainActor (
            WorkspaceDatabaseInspectorField,
            WorkspaceDatabaseInspectorMutation
        ) -> Void
    ) {
        self.resultID = resultID
        self.pageRevision = pageRevision
        self.columns = columns
        self.selectedRowIndex = selectedRowIndex
        self.row = row
        self.isLoading = isLoading
        self.dataFields = dataFields
        self.isUpdatingValue = isUpdatingValue
        self.applyMutation = applyMutation
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.resultID == rhs.resultID
            && lhs.pageRevision == rhs.pageRevision
            && lhs.columns == rhs.columns
            && lhs.selectedRowIndex == rhs.selectedRowIndex
            && lhs.row == rhs.row
            && lhs.isLoading == rhs.isLoading
            && lhs.dataFields == rhs.dataFields
            && lhs.isUpdatingValue == rhs.isUpdatingValue
    }

    func withDataEditing(
        details: WorkspaceDatabaseObjectDetails,
        selection: WorkspaceDatabaseObjectSelection,
        pendingUpdates: [WorkspaceDatabaseInspectorPendingUpdate],
        isUpdatingValue: Bool,
        applyMutation: @escaping @MainActor (
            WorkspaceDatabaseInspectorField,
            WorkspaceDatabaseInspectorMutation
        ) -> Void
    ) -> Self {
        guard let row, let selectedRowIndex else { return self }
        let detailsByName = Dictionary(
            uniqueKeysWithValues: details.columns.map { ($0.name, $0) }
        )
        let hasPrimaryKey = details.columns.contains {
            $0.key.uppercased() == "PRI"
        }
        let fields = columns.map { dataColumn in
            let column = detailsByName[dataColumn.sourceColumnName]
            let pending = pendingUpdates.last {
                $0.applies(
                    to: row,
                    columns: columns,
                    dataColumnIndex: dataColumn.id
                )
            }
            let original = Self.fieldValue(for: row.value(at: dataColumn.id))
            let effective = pending.map {
                $0.update.assignment == .useDefault
                    ? .useDefault
                    : Self.fieldValue(for: $0.update.newValue)
            } ?? original
            let disabledReason = Self.editDisabledReason(
                dataColumn: dataColumn,
                column: column,
                hasPrimaryKey: hasPrimaryKey,
                value: row.value(at: dataColumn.id)
            )
            return WorkspaceDatabaseInspectorField(
                id: "query:\(resultID?.uuidString ?? "result"):\(selectedRowIndex):\(dataColumn.id)",
                name: dataColumn.name,
                type: column?.type ?? dataColumn.type ?? "",
                value: effective,
                originalValue: original,
                hasMultipleValues: false,
                isModified: pending != nil,
                source: .loaded(
                    rowIndexes: IndexSet(integer: selectedRowIndex),
                    dataColumnIndex: dataColumn.id
                ),
                isEditable: disabledReason == nil,
                editDisabledReason: disabledReason,
                isNullable: column?.isNullable == true,
                canUseDefault: column.map {
                    $0.defaultValue != nil
                        || $0.extra.localizedCaseInsensitiveContains(
                            "default_generated"
                        )
                } == true,
                isPrimaryKey: column?.key.uppercased() == "PRI"
            )
        }
        return Self(
            resultID: resultID,
            pageRevision: pageRevision,
            columns: columns,
            selectedRowIndex: selectedRowIndex,
            row: row,
            isLoading: isLoading,
            dataFields: fields,
            isUpdatingValue: isUpdatingValue,
            applyMutation: applyMutation
        )
    }

    var fields: [WorkspaceQueryResultInspectorField]? {
        guard let row, let selectedRowIndex else { return nil }
        return columns.map { column in
            WorkspaceQueryResultInspectorField(
                id: "\(resultID?.uuidString ?? "result"):\(selectedRowIndex):\(column.id)",
                name: column.name,
                type: column.type ?? "",
                value: row.value(at: column.id)
            )
        }
    }

    private static func fieldValue(
        for cell: WorkspaceDatabaseDataCell
    ) -> WorkspaceDatabaseInspectorField.Value {
        switch cell {
        case .null: .null
        case let .text(value): .text(value)
        case let .binary(byteCount, _): .binary(byteCount: byteCount)
        }
    }

    private static func editDisabledReason(
        dataColumn: WorkspaceDatabaseDataColumn,
        column: WorkspaceDatabaseColumn?,
        hasPrimaryKey: Bool,
        value: WorkspaceDatabaseDataCell
    ) -> String? {
        guard dataColumn.origin != nil else {
            return AppCopy.current.text(
                "表达式或计算结果为只读。",
                "Expression and computed results are read-only."
            )
        }
        guard hasPrimaryKey else {
            return WorkspaceDatabaseDataCellEditError.primaryKeyRequired
                .localizedDescription
        }
        guard let column else {
            return WorkspaceDatabaseDataCellEditError.metadataUnavailable
                .localizedDescription
        }
        if column.isGenerated {
            return WorkspaceDatabaseDataCellEditError.generatedColumn
                .localizedDescription
        }
        if case .binary = value {
            return WorkspaceDatabaseDataCellEditError.binaryValueUnavailable
                .localizedDescription
        }
        return nil
    }
}
