import SwiftUI

struct WorkspaceInspectorView: View {
    let context: WorkspaceInspectorContext?

    @State private var searchText = ""

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                WorkspaceGridSearchField(
                    text: $searchText,
                    placeholder: AppCopy.current.text(
                        "搜索字段…",
                        "Search fields..."
                    ),
                    focusRequest: 0,
                    submit: {},
                    cancel: { searchText = "" },
                    accessibilityIdentifier: "workspaceInspectorSearchField"
                )
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                inspectorContent
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .top
            )
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task(id: databaseSelectionID) {
            guard case .database(let databaseContext) = context else { return }
            databaseContext.loadDetails()
        }
        .onChange(of: context?.searchIdentity) { _, _ in
            searchText = ""
        }
        .accessibilityIdentifier("workspaceInspector")
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch context {
        case .elasticsearchIndex(let index):
            WorkspaceElasticsearchIndexInspectorView(context: index, searchText: searchText)
        case .elasticsearchMapping(let mapping):
            WorkspaceElasticsearchMappingInspector(context: mapping, searchText: searchText)
        case let .schemaDraft(_, schemaContext):
            WorkspaceDatabaseSchemaInspectorView(
                context: schemaContext,
                searchText: searchText
            )

        case .database(let databaseContext):
            if let schemaInspector = databaseContext.schemaInspector {
                WorkspaceDatabaseSchemaInspectorView(
                    context: schemaInspector,
                    searchText: searchText
                )
            } else if let fields = databaseContext.fields {
                WorkspaceDatabaseInspectorRowView(
                    fields: fields,
                    searchText: searchText,
                    isUpdatingLoadedValue:
                        databaseContext.isUpdatingLoadedValue,
                    applyMutation: { field, mutation in
                        apply(mutation, to: field, in: databaseContext)
                    }
                )
            } else {
                WorkspaceDatabaseInspectorTableView(
                    selection: databaseContext.selection,
                    detailsState: databaseContext.detailsState,
                    searchText: searchText,
                    retry: databaseContext.loadDetails
                )
            }

        case .queryResult(let queryContext):
            WorkspaceQueryResultInspectorView(
                context: queryContext,
                searchText: searchText
            )

        case .redisKey(let redisContext):
            WorkspaceRedisKeyInspectorView(
                context: redisContext,
                searchText: searchText
            )

        case .elasticsearchDocument(let documentContext):
            WorkspaceElasticsearchDocumentInspectorView(
                context: documentContext,
                searchText: searchText
            )

        case nil:
            ContentUnavailableView(
                AppCopy.current.text("未选择内容", "No Selection"),
                systemImage: "sidebar.right",
                description: Text(
                    AppCopy.current.text(
                        "请选择表、Key 或查询结果以查看详情。",
                        "Select a table, key, or query result to inspect details."
                    )
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var databaseSelectionID: String? {
        guard case .database(let databaseContext) = context else { return nil }
        return databaseContext.selection.id
    }

    private func apply(
        _ mutation: WorkspaceDatabaseInspectorMutation,
        to field: WorkspaceDatabaseInspectorField,
        in context: WorkspaceDatabaseInspectorContext
    ) {
        switch field.source {
        case .loaded(let rowIndexes, let dataColumnIndex):
            context.updateLoadedValue(rowIndexes, dataColumnIndex, mutation)
        case .draft(let rowIDs, let columnName):
            context.updateDraftValue(rowIDs, columnName, mutation)
        }
    }
}
