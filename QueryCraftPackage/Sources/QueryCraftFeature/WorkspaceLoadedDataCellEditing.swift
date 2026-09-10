enum WorkspaceLoadedDataCellEditing {
    static func inlineContext(
        selection: WorkspaceDatabaseObjectSelection,
        target: WorkspaceDatabaseDataCellEditTarget,
        details: WorkspaceDatabaseObjectDetails,
        pendingUpdates: [WorkspaceDatabaseInspectorPendingUpdate]
    ) throws -> WorkspaceDatabaseDataCellInlineEditContext {
        _ = try WorkspaceDatabaseDataCellEditRequest.make(
            selection: selection,
            target: target,
            details: details
        )
        let pendingUpdate = pendingUpdates.last {
            $0.applies(
                to: target.row,
                columns: target.columns,
                dataColumnIndex: target.dataColumnIndex
            )
        }
        let initialMutation = pendingUpdate.map(mutation(for:))
            ?? mutation(for: target.originalValue)
        return WorkspaceDatabaseDataCellInlineEditContext(
            rowIndex: target.rowIndex,
            dataColumnIndex: target.dataColumnIndex,
            columnName: target.column?.name ?? "",
            initialText: text(for: initialMutation),
            initialMutation: initialMutation
        )
    }

    static func update(
        request: WorkspaceDatabaseDataCellEditRequest,
        mutation: WorkspaceDatabaseInspectorMutation
    ) throws -> WorkspaceDatabaseDataCellUpdate {
        switch mutation {
        case let .value(value):
            try request.makeUpdate(text: value, usesNull: false)
        case .null:
            try request.makeUpdate(text: "", usesNull: true)
        case .useDefault:
            try request.makeDefaultUpdate()
        }
    }

    static func mutation(
        for pendingUpdate: WorkspaceDatabaseInspectorPendingUpdate
    ) -> WorkspaceDatabaseInspectorMutation {
        pendingUpdate.update.assignment == .useDefault
            ? .useDefault
            : mutation(for: pendingUpdate.update.newValue)
    }

    static func mutation(
        for cell: WorkspaceDatabaseDataCell
    ) -> WorkspaceDatabaseInspectorMutation {
        switch cell {
        case .null: .null
        case let .text(value): .value(value)
        case .binary: .value("")
        }
    }

    static func text(
        for mutation: WorkspaceDatabaseInspectorMutation
    ) -> String {
        if case let .value(value) = mutation { return value }
        return ""
    }
}
