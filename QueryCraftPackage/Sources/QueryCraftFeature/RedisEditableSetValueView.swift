import SwiftUI

struct RedisEditableSetValueView: View {
    @Bindable var editor: RedisKeyEditorState
    let isEnabled: Bool
    let searchController: WorkspaceGridSearchController
    let searchPresentationActions: WorkspaceGridSearchCommandActions

    var body: some View {
        RedisCollectionGrid(
            rows: editor.rows,
            kind: .set,
            isEnabled: isEnabled,
            selectedRowIndexes: editor.selectedRowIndexes,
            searchController: searchController,
            searchPresentationActions: searchPresentationActions,
            addRow: editor.addRow,
            updateValue: editor.updateRow,
            removeRow: editor.removeRow,
            selectRows: editor.selectRows
        )
    }
}
