import SwiftUI

struct WorkspaceDatabaseItems: View {
    let database: WorkspaceDatabase
    @Bindable var model: WorkspaceModel
    let openObjectTab: @MainActor (
        WorkspaceDatabaseObjectSelection,
        WorkspaceDatabaseObjectDetailTab
    ) -> Void
    let renameTable: @MainActor (WorkspaceDatabaseObjectSelection) -> Void
    let deleteTable: @MainActor (WorkspaceDatabaseObjectSelection) -> Void
    var deleteIndex: @MainActor (WorkspaceDatabaseObjectSelection) -> Void = { _ in }

    var body: some View {
        switch database.objectsState {
        case .notLoaded:
            Label(
                AppCopy.current.text("尚未加载", "Not Loaded"),
                systemImage: "clock"
            )
            .foregroundStyle(.secondary)
            .task { model.requestObjects(in: database.name) }

        case .queued:
            Label(
                AppCopy.current.text("正在等待加载…", "Waiting to Load..."),
                systemImage: "clock"
            )
            .foregroundStyle(.secondary)

        case .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(
                    AppCopy.current.text(
                        "正在加载表和视图…",
                        "Loading tables and views..."
                    )
                )
                .foregroundStyle(.secondary)
            }

        case let .loaded(objects):
            let schemaObjects = objectsInSelectedSchema(objects)
            let visibleObjects = filteredObjects(schemaObjects)
            if schemaObjects.isEmpty {
                ContentUnavailableView(
                    model.databaseType == .elasticsearch
                        ? AppCopy.current.text("没有索引、Alias 或 Data Stream", "No Indices, Aliases or Data Streams")
                        : AppCopy.current.text("没有表或视图", "No Tables or Views"),
                    systemImage: "tablecells"
                )
            } else if visibleObjects.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                if model.databaseType == .elasticsearch {
                    WorkspaceElasticsearchObjectGroup(
                        databaseName: database.name,
                        kind: .elasticsearchDataStream,
                        objects: Self.objects(
                            of: .elasticsearchDataStream,
                            in: visibleObjects
                        ),
                        isExpanded: $model
                            .isElasticsearchDataStreamGroupExpanded,
                        openObjectTab: openObjectTab
                    )
                    WorkspaceElasticsearchObjectGroup(
                        databaseName: database.name,
                        kind: .elasticsearchAlias,
                        objects: Self.objects(
                            of: .elasticsearchAlias,
                            in: visibleObjects
                        ),
                        isExpanded: $model.isElasticsearchAliasGroupExpanded,
                        openObjectTab: openObjectTab
                    )
                    WorkspaceElasticsearchObjectGroup(
                        databaseName: database.name,
                        kind: .elasticsearchIndex,
                        objects: Self.objects(
                            of: .elasticsearchIndex,
                            in: visibleObjects
                        ),
                        isExpanded: $model.isElasticsearchIndexGroupExpanded,
                        openObjectTab: openObjectTab,
                        deleteIndex: deleteIndex
                    )
                } else {
                    objectRows(kind: .table, objects: visibleObjects)
                    objectRows(kind: .view, objects: visibleObjects)
                }
            }

        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    AppCopy.current.text(
                        "无法加载对象",
                        "Unable to Load Objects"
                    ),
                    systemImage: "exclamationmark.triangle"
                )

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("databaseObjectsLoadError")

                Button(
                    AppCopy.current.text("重试", "Retry"),
                    systemImage: "arrow.clockwise"
                ) {
                    model.requestObjects(in: database.name)
                }
                .controlSize(.small)
                .accessibilityIdentifier("retryDatabaseObjectsButton")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(message)
        }
    }

    private func filteredObjects(
        _ objects: [WorkspaceDatabaseObject]
    ) -> [WorkspaceDatabaseObject] {
        let visibleObjects = visibleSystemResources(in: objects)
        return Self.objects(
            in: visibleObjects,
            matching: model.searchText
        )
    }

    private func visibleSystemResources(
        in objects: [WorkspaceDatabaseObject]
    ) -> [WorkspaceDatabaseObject] {
        guard model.databaseType == .elasticsearch,
              !model.showsElasticsearchSystemResources
        else { return objects }
        return objects.filter {
            !$0.name.hasPrefix(".") && !$0.name.hasPrefix(".ds-")
        }
    }

    static func objects(
        of kind: WorkspaceDatabaseObjectKind,
        in objects: [WorkspaceDatabaseObject]
    ) -> [WorkspaceDatabaseObject] {
        objects.filter { $0.kind == kind }
    }

    static func objects(
        in objects: [WorkspaceDatabaseObject],
        matching searchText: String
    ) -> [WorkspaceDatabaseObject] {
        guard !searchText.isEmpty else { return objects }
        return objects.enumerated().compactMap { index, object in
            CompletionLabelMatcher.match(
                label: object.name,
                query: searchText
            ).map { match in
                (object: object, match: match, index: index)
            }
        }.sorted { lhs, rhs in
            if lhs.match.tier != rhs.match.tier {
                return lhs.match.tier < rhs.match.tier
            }
            if lhs.match.score != rhs.match.score {
                return lhs.match.score < rhs.match.score
            }
            return lhs.index < rhs.index
        }.map(\.object)
    }

    @ViewBuilder
    private func objectRows(
        kind: WorkspaceDatabaseObjectKind,
        objects: [WorkspaceDatabaseObject]
    ) -> some View {
        let matchingObjects = objects.filter { $0.kind == kind }
        ForEach(matchingObjects, id: \.id) { object in
            let selection = WorkspaceDatabaseObjectSelection(
                databaseName: database.name,
                objectName: object.name,
                kind: kind
            )
            WorkspaceDatabaseObjectRow(
                selection: selection,
                displayName: model.databaseType == .postgresql
                    ? object.nameWithinSchema
                    : object.name,
                summary: object.summary,
                openTab: { tab in openObjectTab(selection, tab) },
                renameTable: { renameTable(selection) },
                deleteTable: { deleteTable(selection) }
            )
        }
    }

    private func objectsInSelectedSchema(
        _ objects: [WorkspaceDatabaseObject]
    ) -> [WorkspaceDatabaseObject] {
        guard model.databaseType == .postgresql,
              let selectedSchema = model.selectedSchema
        else { return objects }
        return objects.filter { $0.schemaName == selectedSchema }
    }
}
