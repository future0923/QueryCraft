import AppKit

/// Shared fill behavior for table data and SQL results. Prepare the whole
/// selection before staging anything, including rows outside the loaded cache.
@MainActor
enum WorkspaceGridSelectedCellEditing {
    static func coordinates(
        in table: WorkspaceDirectDrawTableView,
        clicked: WorkspaceGridCoordinate,
        dataColumns: [Int]
    ) -> [WorkspaceGridCoordinate] {
        let rows: IndexSet
        let columns: [Int]
        if !table.gridSelection.isEmpty {
            guard table.gridSelection.contains(row: clicked.row, column: clicked.column),
                  let selectedRows = table.gridSelection.rows,
                  let selectedColumns = table.gridSelection.columns else { return [clicked] }
            rows = IndexSet(integersIn: selectedRows)
            columns = dataColumns.filter(selectedColumns.contains)
        } else {
            guard table.selectedDataRowIndexesForActions.contains(clicked.row) else { return [clicked] }
            rows = table.selectedDataRowIndexesForActions
            columns = dataColumns
        }
        guard !columns.isEmpty, rows.count <= 100_000 / columns.count else { return [] }
        return rows.flatMap { row in columns.map { .init(row: row, column: $0) } }
    }

    @discardableResult
    static func apply(
        _ mutation: WorkspaceDatabaseInspectorMutation,
        coordinates: [WorkspaceGridCoordinate],
        prepare: (WorkspaceGridCoordinate) -> WorkspaceDatabaseDataCellInlineEditContext?,
        update: (WorkspaceDatabaseDataCellInlineEditContext, WorkspaceDatabaseInspectorMutation) -> Void
    ) -> Bool {
        guard !coordinates.isEmpty else { return false }
        var contexts: [WorkspaceDatabaseDataCellInlineEditContext] = []
        for coordinate in coordinates {
            guard let context = prepare(coordinate), mutation != .null || context.isNullable else { return false }
            contexts.append(context)
        }
        for context in contexts { update(context, mutation) }
        return true
    }

    /// Preserve the distinction between a copied SQL NULL and the text "NULL".
    /// Multiple cells remain on the existing paste-as-new-rows path.
    static func pastedValue(_ content: WorkspaceGridPasteboardContent) -> WorkspaceDatabaseInspectorMutation? {
        if let data = content.internalPayload {
            guard data.count <= 8 * 1_024 * 1_024,
                  let payload = try? JSONDecoder().decode(WorkspaceGridClipboardPayload.self, from: data),
                  payload.version == 1, payload.columnNames.count == 1,
                  payload.rows.count == 1, payload.rows[0].count == 1 else { return nil }
            switch payload.rows[0][0] {
            case .null: return .null
            case let .text(text): return .value(text)
            case .binary: return nil
            }
        }
        guard let text = content.tabSeparatedText, text.utf8.count <= 8 * 1_024 * 1_024,
              let rows = try? WorkspaceGridPasteParser.parseDelimitedText(text),
              rows.count == 1, rows[0].count == 1 else { return nil }
        return .value(rows[0][0])
    }
}
