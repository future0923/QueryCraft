import Foundation

enum WorkspaceDatabaseDataRowActionKind: Equatable {
    case tableRow
    case elasticsearchDocument
}

struct WorkspaceDatabaseDataRowCommandActions: Equatable {
    let selectedRowIndexes: IndexSet
    let canAddRow: Bool
    let canDuplicateRow: Bool
    let canDeleteRow: Bool
    var kind = WorkspaceDatabaseDataRowActionKind.tableRow
    let addRow: @MainActor @Sendable () -> Void
    let duplicateRow: @MainActor @Sendable (Int) -> Void
    let deleteRows: @MainActor @Sendable (IndexSet) -> Void

    var selectedRowIndex: Int? {
        selectedRowIndexes.count == 1 ? selectedRowIndexes.first : nil
    }

    static func == (
        lhs: WorkspaceDatabaseDataRowCommandActions,
        rhs: WorkspaceDatabaseDataRowCommandActions
    ) -> Bool {
        lhs.selectedRowIndexes == rhs.selectedRowIndexes
            && lhs.canAddRow == rhs.canAddRow
            && lhs.canDuplicateRow == rhs.canDuplicateRow
            && lhs.canDeleteRow == rhs.canDeleteRow
            && lhs.kind == rhs.kind
    }
}
