import SwiftUI

struct WorkspaceDatabaseIndexesView: View {
    let state: WorkspaceDatabaseIndexesState
    let indexes: [WorkspaceDatabaseSchemaEditorState.IndexItem]
    let descriptor: WorkspaceDatabaseSchemaEditingDescriptor
    let availableColumnNames: [String]
    @Binding var selection: UUID?
    let retry: () -> Void
    let isEditable: Bool
    let add: @MainActor () -> Void
    let duplicate: @MainActor (UUID) -> Void
    let update: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.IndexDefinition
    ) -> Void
    let delete: @MainActor (UUID) -> Void

    @State private var preferences = ApplicationPreferences.shared

    var body: some View {
        Group {
            switch state {
            case .notLoaded, .loading:
                ProgressView(
                    AppCopy.current.text(
                        "正在加载索引…",
                        "Loading indexes..."
                    )
                )
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded:
                WorkspaceDatabaseSchemaGrid(
                    content: .indexes(indexes),
                    descriptor: descriptor,
                    schemaChoices: .empty,
                    availableColumnNames: availableColumnNames,
                    selection: $selection,
                    isEditable: isEditable,
                    usesAlternatingRows: preferences.usesAlternatingTableRows,
                    accessibilityIdentifier: "databaseObjectIndexes",
                    add: add,
                    duplicate: duplicate,
                    updateColumn: { _, _ in },
                    updateIndex: update,
                    primaryKeyColumnIDs: [],
                    setPrimaryKey: { _, _ in },
                    delete: delete
                )

            case let .failed(message):
                ContentUnavailableView {
                    Label(
                        AppCopy.current.text(
                            "无法加载索引",
                            "Unable to Load Indexes"
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(message)
                } actions: {
                    Button(
                        AppCopy.current.text("重试", "Retry"),
                        systemImage: "arrow.clockwise",
                        action: retry
                    )
                }
            }
        }
        .accessibilityIdentifier("databaseObjectIndexes")
    }
}
