import SwiftUI

struct WorkspaceDatabaseStructureView: View {
    let columns: [WorkspaceDatabaseSchemaEditorState.ColumnItem]
    let descriptor: WorkspaceDatabaseSchemaEditingDescriptor
    let schemaChoices: WorkspaceDatabaseSchemaChoices
    @Binding var selection: UUID?
    let isEditable: Bool
    let add: @MainActor () -> Void
    let duplicate: @MainActor (UUID) -> Void
    let update: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    ) -> Void
    let primaryKeyColumnIDs: Set<UUID>
    let setPrimaryKey: @MainActor (UUID, Bool) -> Void
    let delete: @MainActor (UUID) -> Void

    @State private var preferences = ApplicationPreferences.shared

    var body: some View {
        Group {
            if columns.isEmpty {
                ContentUnavailableView(
                    AppCopy.current.text("没有字段", "No Columns"),
                    systemImage: "rectangle.split.3x1"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkspaceDatabaseSchemaGrid(
                    content: .columns(columns),
                    descriptor: descriptor,
                    schemaChoices: schemaChoices,
                    availableColumnNames: columns
                        .filter { !$0.isDeleted }
                        .map(\.definition.name)
                        .filter { !$0.isEmpty },
                    selection: $selection,
                    isEditable: isEditable,
                    usesAlternatingRows: preferences.usesAlternatingTableRows,
                    accessibilityIdentifier: "databaseObjectStructure",
                    add: add,
                    duplicate: duplicate,
                    updateColumn: update,
                    updateIndex: { _, _ in },
                    primaryKeyColumnIDs: primaryKeyColumnIDs,
                    setPrimaryKey: setPrimaryKey,
                    delete: delete
                )
            }
        }
        .accessibilityIdentifier("databaseObjectStructure")
    }
}
