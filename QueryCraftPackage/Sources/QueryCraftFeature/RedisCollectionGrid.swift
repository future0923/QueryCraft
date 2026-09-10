import SwiftUI

struct RedisCollectionGrid: NSViewRepresentable {
    let rows: [RedisKeyEditableRow]
    let kind: RedisCollectionGridKind
    let isEnabled: Bool
    let selectedRowIndexes: IndexSet
    let searchController: WorkspaceGridSearchController
    let searchPresentationActions: WorkspaceGridSearchCommandActions
    let addRow: @MainActor () -> Void
    let updateValue: @MainActor (
        RedisKeyEditableRow.ID,
        RedisKeyEditableCell,
        String
    ) -> Void
    let removeRow: @MainActor (RedisKeyEditableRow.ID) -> Void
    let selectRows: @MainActor (IndexSet) -> Void

    func makeCoordinator() -> RedisCollectionGridCoordinator {
        RedisCollectionGridCoordinator(
            rows: rows,
            kind: kind,
            isEnabled: isEnabled,
            selectedRowIndexes: selectedRowIndexes,
            searchController: searchController,
            searchPresentationActions: searchPresentationActions,
            addRow: addRow,
            updateValue: updateValue,
            removeRow: removeRow,
            selectRows: selectRows
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        context.coordinator.update(
            rows: rows,
            kind: kind,
            isEnabled: isEnabled,
            selectedRowIndexes: selectedRowIndexes,
            searchPresentationActions: searchPresentationActions,
            addRow: addRow,
            updateValue: updateValue,
            removeRow: removeRow,
            selectRows: selectRows
        )
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: RedisCollectionGridCoordinator
    ) {
        coordinator.finishEditing()
        coordinator.dismantleSearch()
    }
}
