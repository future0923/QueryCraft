import Foundation

struct WorkspaceElasticsearchCreationTablePresentation {
    let dataState: WorkspaceDatabaseDataState
    let countState: WorkspaceDatabaseDataCountState
    let rowInsertEditor: WorkspaceDatabaseDataRowInsertEditorState
    let selectedRowIndexes: IndexSet

    init?(
        dataState: WorkspaceDatabaseDataState,
        countState: WorkspaceDatabaseDataCountState,
        rowInsertEditor: WorkspaceDatabaseDataRowInsertEditorState,
        selectedRowIndexes: IndexSet
    ) {
        guard let page = dataState.page, rowInsertEditor.isPresented else { return nil }
        // Retain the bounded page and value-type drafts while write acknowledgements change independently.
        self.dataState = .fetching(page)
        self.countState = countState
        var editor = rowInsertEditor
        editor.setSubmitting(true)
        self.rowInsertEditor = editor
        self.selectedRowIndexes = selectedRowIndexes
    }
}
