import AppKit

enum WorkspaceLoadedDataPendingPresentation {
    @MainActor
    static func changedVisibleRowIndexes(
        in tableView: NSTableView,
        columns: [WorkspaceDatabaseDataColumn],
        previousUpdates: [WorkspaceDatabaseInspectorPendingUpdate],
        updates: [WorkspaceDatabaseInspectorPendingUpdate],
        rowAt: (Int) -> WorkspaceDatabaseDataRow?
    ) -> IndexSet {
        let changedUpdates = previousUpdates.filter {
            !updates.contains($0)
        } + updates.filter {
            !previousUpdates.contains($0)
        }
        guard !changedUpdates.isEmpty else { return [] }

        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound else { return [] }
        var changedRows = IndexSet()
        for rowIndex in visibleRows.location..<NSMaxRange(visibleRows) {
            guard let row = rowAt(rowIndex) else { continue }
            if changedUpdates.contains(where: {
                $0.applies(to: row, columns: columns)
            }) {
                changedRows.insert(rowIndex)
            }
        }
        return changedRows
    }

    static func effectiveRow(
        _ row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceDatabaseDataColumn],
        updates: [WorkspaceDatabaseInspectorPendingUpdate]
    ) -> WorkspaceDatabaseDataRow {
        var values = row.values
        for pendingUpdate in updates {
            guard
                let column = columns.first(where: {
                    $0.sourceColumnName == pendingUpdate.update.columnName
                }),
                values.indices.contains(column.id),
                pendingUpdate.applies(
                    to: row,
                    columns: columns,
                    dataColumnIndex: column.id
                )
            else { continue }
            values[column.id] = switch pendingUpdate.update.assignment {
            case .value:
                pendingUpdate.update.newValue
            case .useDefault:
                .text("DEFAULT")
            }
        }
        return WorkspaceDatabaseDataRow(id: row.id, values: values)
    }

    static func pendingUpdateColumnIndexes(
        for row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceDatabaseDataColumn],
        updates: [WorkspaceDatabaseInspectorPendingUpdate]
    ) -> Set<Int> {
        Set(updates.compactMap { pendingUpdate in
            guard let column = columns.first(where: {
                $0.sourceColumnName == pendingUpdate.update.columnName
            }) else { return nil }
            guard pendingUpdate.applies(
                to: row,
                columns: columns,
                dataColumnIndex: column.id
            ) else { return nil }
            return column.id
        })
    }
}
