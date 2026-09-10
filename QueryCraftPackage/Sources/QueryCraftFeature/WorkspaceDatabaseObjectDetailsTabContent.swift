import SwiftUI

struct WorkspaceDatabaseObjectDetailsTabContent: Equatable, View {
    let state: WorkspaceDatabaseObjectDetailsState
    let tab: WorkspaceDatabaseObjectDetailTab
    let retry: () -> Void
    let canEditSchema: Bool
    let schemaEditingDescriptor: WorkspaceDatabaseSchemaEditingDescriptor
    nonisolated let schemaEditor: WorkspaceDatabaseSchemaEditorState
    @Binding var tableOptions: WorkspaceDatabaseTableOptions
    @Binding var selectedSchemaColumnID: UUID?
    let addSchemaColumn: @MainActor () -> Void
    let duplicateSchemaColumn: @MainActor (UUID) -> Void
    let updateSchemaColumn: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    ) -> Void
    let setSchemaColumnPrimaryKey: @MainActor (UUID, Bool) -> Void
    let deleteSchemaColumn: @MainActor (UUID) -> Void

    nonisolated static func == (
        lhs: WorkspaceDatabaseObjectDetailsTabContent,
        rhs: WorkspaceDatabaseObjectDetailsTabContent
    ) -> Bool {
        guard lhs.state == rhs.state,
              lhs.tab == rhs.tab,
              lhs.canEditSchema == rhs.canEditSchema,
              lhs.schemaEditingDescriptor == rhs.schemaEditingDescriptor
        else { return false }
        return lhs.schemaEditor == rhs.schemaEditor
    }

    var body: some View {
        switch state {
        case .notLoaded, .loading:
            VStack(spacing: 0) {
                Color(nsColor: .textBackgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                WorkspaceDatabaseDataProgressBar(
                    isActive: true,
                    accessibilityLabel: AppCopy.current.text(
                        "正在加载对象详情",
                        "Loading object details"
                    )
                )
            }

        case let .loaded(details):
            switch tab {
            case .structure:
                if let fields = details.documentMappingFields {
                    WorkspaceElasticsearchMappingView(fields: fields)
                } else {
                    WorkspaceDatabaseStructureView(
                        columns: schemaEditor.columns,
                        descriptor: schemaEditingDescriptor,
                        schemaChoices: schemaEditor.schemaChoices,
                        selection: $selectedSchemaColumnID,
                        isEditable: canEditSchema,
                        add: addSchemaColumn,
                        duplicate: duplicateSchemaColumn,
                        update: updateSchemaColumn,
                        primaryKeyColumnIDs: Set(
                            schemaEditor.columns.compactMap { item in
                                schemaEditor.isPrimaryKey(columnID: item.id)
                                    ? item.id
                                    : nil
                            }
                        ),
                        setPrimaryKey: setSchemaColumnPrimaryKey,
                        delete: deleteSchemaColumn
                    )
                }
            case .ddl:
                WorkspaceDatabaseDDLView(ddl: details.ddl)
            case .options:
                WorkspaceNewTableOptionsView(
                    options: $tableOptions,
                    schemaChoices: schemaEditor.schemaChoices,
                    isDisabled: !canEditSchema,
                    allowsDatabaseDefaults: false
                )
            case .data, .indexes:
                EmptyView()
            }

        case let .failed(message):
            ContentUnavailableView {
                Label(
                    AppCopy.current.text("无法加载详情", "Unable to Load Details"),
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
}
