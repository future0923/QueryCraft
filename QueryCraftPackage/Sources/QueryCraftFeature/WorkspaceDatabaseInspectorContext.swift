import Foundation

struct WorkspaceDatabaseInspectorContext: Equatable {
    let selection: WorkspaceDatabaseObjectSelection
    let detailsState: WorkspaceDatabaseObjectDetailsState
    let page: WorkspaceDatabaseDataPage?
    let selectedRowIndexes: IndexSet
    let rowInsertEditor: WorkspaceDatabaseDataRowInsertEditorState
    let pendingLoadedUpdates: [WorkspaceDatabaseInspectorPendingUpdate]
    let schemaInspector: WorkspaceDatabaseSchemaInspectorContext?
    let isUpdatingLoadedValue: Bool
    let loadDetails: @MainActor () -> Void
    let updateLoadedValue: @MainActor (
        IndexSet,
        Int,
        WorkspaceDatabaseInspectorMutation
    ) -> Void
    let updateDraftValue: @MainActor (
        [UUID],
        String,
        WorkspaceDatabaseInspectorMutation
    ) -> Void

    nonisolated static func == (
        lhs: WorkspaceDatabaseInspectorContext,
        rhs: WorkspaceDatabaseInspectorContext
    ) -> Bool {
        lhs.selection == rhs.selection
            && lhs.detailsState == rhs.detailsState
            && lhs.page?.revision == rhs.page?.revision
            && lhs.selectedRowIndexes == rhs.selectedRowIndexes
            && lhs.rowInsertEditor == rhs.rowInsertEditor
            && lhs.pendingLoadedUpdates == rhs.pendingLoadedUpdates
            && lhs.schemaInspector == rhs.schemaInspector
            && lhs.isUpdatingLoadedValue == rhs.isUpdatingLoadedValue
    }

    var fields: [WorkspaceDatabaseInspectorField]? {
        guard let page else { return nil }
        let validIndexes = selectedRowIndexes.filter {
            $0 >= 0 && $0 < page.rowCount + rowInsertEditor.rowCount
        }
        guard !validIndexes.isEmpty else { return nil }

        let loadedIndexes = validIndexes.filter { $0 < page.rowCount }
        if loadedIndexes.count == validIndexes.count {
            return loadedFields(
                rowIndexes: indexSet(from: loadedIndexes),
                page: page
            )
        }

        let draftIndexes = validIndexes.filter { $0 >= page.rowCount }
        if draftIndexes.count == validIndexes.count {
            let rowIDs = draftIndexes.compactMap {
                rowInsertEditor.rowID(at: $0 - page.rowCount)
            }
            guard rowIDs.count == draftIndexes.count else { return nil }
            return draftFields(rowIDs: rowIDs, page: page)
        }

        return nil
    }

    private func loadedFields(
        rowIndexes: IndexSet,
        page: WorkspaceDatabaseDataPage
    ) -> [WorkspaceDatabaseInspectorField]? {
        let rows = rowIndexes.compactMap(page.row(at:))
        guard rows.count == rowIndexes.count else { return nil }

        let detailsByName = detailsByColumnName
        let hasPrimaryKey = detailsByName.values.contains {
            $0.key.uppercased() == "PRI"
        }
        let selectionID = rowIndexes.map(String.init).joined(separator: ",")
        let pendingUpdatesByRowID = pendingUpdatesByRowID(
            for: rows,
            page: page
        )

        return page.columns.map { dataColumn in
            let column = detailsByName[dataColumn.name]
            let originalValues = rows.map {
                Self.value(for: $0.value(at: dataColumn.id))
            }
            let effectiveValues = rows.map { row in
                pendingUpdatesByRowID[row.id]?[dataColumn.id]
                    .map(Self.value(for:))
                    ?? Self.value(for: row.value(at: dataColumn.id))
            }
            let commonOriginalValue = Self.commonValue(in: originalValues)
            let commonValue = Self.commonValue(in: effectiveValues)
            let hasPendingUpdate = rows.contains { row in
                pendingUpdatesByRowID[row.id]?[dataColumn.id] != nil
            }
            let editDisabledReason = loadedEditDisabledReason(
                column: column,
                hasPrimaryKey: hasPrimaryKey,
                containsUnavailableBinaryValue: rows.contains {
                    $0.value(at: dataColumn.id).isBinary
                }
            )
            return WorkspaceDatabaseInspectorField(
                id: "loaded:\(selectionID):\(dataColumn.name)",
                name: dataColumn.name,
                type: column?.type ?? "",
                value: commonValue ?? .text(""),
                originalValue: commonOriginalValue ?? .text(""),
                hasMultipleValues: commonValue == nil,
                isModified: hasPendingUpdate,
                source: .loaded(
                    rowIndexes: rowIndexes,
                    dataColumnIndex: dataColumn.id
                ),
                isEditable: editDisabledReason == nil,
                editDisabledReason: editDisabledReason,
                isNullable: column?.isNullable == true,
                canUseDefault: column?.canUseUpdateDefault == true,
                isPrimaryKey: column?.key.uppercased() == "PRI"
            )
        }
    }

    private func draftFields(
        rowIDs: [UUID],
        page: WorkspaceDatabaseDataPage
    ) -> [WorkspaceDatabaseInspectorField] {
        let detailsByName = detailsByColumnName
        let selectionID = rowIDs.map(\.uuidString).joined(separator: ",")

        return page.columns.map { dataColumn in
            let column = detailsByName[dataColumn.name]
            let insertColumn = rowInsertEditor.column(named: dataColumn.name)
            let originalDraft = insertColumn?.initialDraft
                ?? WorkspaceDatabaseDataRowInsertDraft(
                    mode: .useDefault,
                    text: ""
                )
            let values = rowIDs.map { rowID in
                rowInsertEditor.draft(rowID: rowID, for: dataColumn.name)
                    .map(Self.value(for:))
                    ?? .useDefault
            }
            let commonValue = Self.commonValue(in: values)
            let editDisabledReason = draftEditDisabledReason(
                column: column,
                insertColumnIsAvailable: insertColumn != nil
            )
            return WorkspaceDatabaseInspectorField(
                id: "draft:\(selectionID):\(dataColumn.name)",
                name: dataColumn.name,
                type: column?.type ?? insertColumn?.column.type ?? "",
                value: commonValue ?? .text(""),
                originalValue: Self.value(for: originalDraft),
                hasMultipleValues: commonValue == nil,
                isModified: rowIDs.contains {
                    rowInsertEditor.hasEditedColumn(
                        rowID: $0,
                        columnName: dataColumn.name
                    )
                },
                source: .draft(
                    rowIDs: rowIDs,
                    columnName: dataColumn.name
                ),
                isEditable: editDisabledReason == nil,
                editDisabledReason: editDisabledReason,
                isNullable: insertColumn?.column.isNullable == true,
                canUseDefault: insertColumn?.canUseDefault == true,
                isPrimaryKey: column?.key.uppercased() == "PRI"
            )
        }
    }

    private func loadedEditDisabledReason(
        column: WorkspaceDatabaseColumn?,
        hasPrimaryKey: Bool,
        containsUnavailableBinaryValue: Bool
    ) -> String? {
        if selection.kind != .table {
            return AppCopy.current.text(
                "视图中的数据为只读，不能直接修改。",
                "Data in views is read-only and cannot be edited directly."
            )
        }
        if !hasPrimaryKey {
            return AppCopy.current.text(
                "此表没有主键，无法确定要修改的行。",
                "This table has no primary key, so the row to update cannot be identified."
            )
        }
        guard let column else {
            return AppCopy.current.text(
                "无法读取此字段的列信息。",
                "Column information for this field is unavailable."
            )
        }
        if column.isGenerated {
            return AppCopy.current.text(
                "生成列由 MySQL 计算，不能直接修改。",
                "Generated columns are computed by MySQL and cannot be edited directly."
            )
        }
        if containsUnavailableBinaryValue {
            return AppCopy.current.text(
                "当前结果只保留了二进制值的大小，不能直接修改。",
                "The current result retains only the binary value size, so it cannot be edited directly."
            )
        }
        return nil
    }

    private func draftEditDisabledReason(
        column: WorkspaceDatabaseColumn?,
        insertColumnIsAvailable: Bool
    ) -> String? {
        if rowInsertEditor.isSubmitting {
            return AppCopy.current.text(
                "正在提交更改，请稍候。",
                "Changes are being committed. Please wait."
            )
        }
        if column?.isGenerated == true {
            return AppCopy.current.text(
                "生成列由 MySQL 计算，新增行时不需要填写。",
                "Generated columns are computed by MySQL and do not need a value for new rows."
            )
        }
        if column?.isAutoIncrement == true {
            return AppCopy.current.text(
                "自增列由 MySQL 生成，新增行时不需要填写。",
                "Auto-increment columns are generated by MySQL and do not need a value for new rows."
            )
        }
        if !insertColumnIsAvailable {
            return AppCopy.current.text(
                "此字段由数据库管理，新增行时不能直接填写。",
                "This field is managed by the database and cannot be set directly for new rows."
            )
        }
        return nil
    }

    private var detailsByColumnName: [String: WorkspaceDatabaseColumn] {
        Dictionary(
            uniqueKeysWithValues: detailsState.details?.columns.map {
                ($0.name, $0)
            } ?? []
        )
    }

    private func pendingUpdatesByRowID(
        for rows: [WorkspaceDatabaseDataRow],
        page: WorkspaceDatabaseDataPage
    ) -> [Int: [Int: WorkspaceDatabaseInspectorPendingUpdate]] {
        let dataColumnIndexesByName = Dictionary(
            uniqueKeysWithValues: page.columns.map { ($0.name, $0.id) }
        )
        var result: [Int: [Int: WorkspaceDatabaseInspectorPendingUpdate]] = [:]
        for pendingUpdate in pendingLoadedUpdates {
            guard
                let dataColumnIndex = dataColumnIndexesByName[
                    pendingUpdate.update.columnName
                ],
                let row = rows.first(where: {
                    pendingUpdate.applies(
                        to: $0,
                        columns: page.columns,
                        dataColumnIndex: dataColumnIndex
                    )
                })
            else {
                continue
            }
            result[row.id, default: [:]][dataColumnIndex] = pendingUpdate
        }
        return result
    }

    private func indexSet(from indexes: [Int]) -> IndexSet {
        var result = IndexSet()
        for index in indexes {
            result.insert(index)
        }
        return result
    }

    private static func commonValue(
        in values: [WorkspaceDatabaseInspectorField.Value]
    ) -> WorkspaceDatabaseInspectorField.Value? {
        guard let first = values.first else { return nil }
        return values.dropFirst().allSatisfy { $0 == first } ? first : nil
    }

    private static func value(
        for cell: WorkspaceDatabaseDataCell
    ) -> WorkspaceDatabaseInspectorField.Value {
        switch cell {
        case .null:
            .null
        case let .text(value):
            .text(value)
        case let .binary(byteCount, _):
            .binary(byteCount: byteCount)
        }
    }

    private static func value(
        for draft: WorkspaceDatabaseDataRowInsertDraft
    ) -> WorkspaceDatabaseInspectorField.Value {
        switch draft.mode {
        case .unfilled:
            .required
        case .useDefault:
            .useDefault
        case .null:
            .null
        case .value:
            .text(draft.text)
        }
    }

    private static func value(
        for pendingUpdate: WorkspaceDatabaseInspectorPendingUpdate
    ) -> WorkspaceDatabaseInspectorField.Value {
        switch pendingUpdate.update.assignment {
        case .value:
            value(for: pendingUpdate.update.newValue)
        case .useDefault:
            .useDefault
        }
    }
}

private extension WorkspaceDatabaseObjectDetailsState {
    var details: WorkspaceDatabaseObjectDetails? {
        guard case let .loaded(details) = self else { return nil }
        return details
    }
}

private extension WorkspaceDatabaseColumn {
    var canUseUpdateDefault: Bool {
        defaultValue != nil
            || extra.localizedCaseInsensitiveContains("default_generated")
    }

    var isAutoIncrement: Bool {
        extra.localizedCaseInsensitiveContains("auto_increment")
    }
}

private extension WorkspaceDatabaseDataCell {
    var isBinary: Bool {
        if case .binary = self { true } else { false }
    }
}
