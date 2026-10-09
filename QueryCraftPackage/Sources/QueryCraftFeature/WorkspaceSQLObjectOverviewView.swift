import SwiftUI

struct WorkspaceSQLObjectOverviewView: View {
    @Bindable var model: WorkspaceModel
    let database: String
    let refreshRegistry: WorkspaceContentRefreshRegistry
    let openObject: @MainActor (WorkspaceDatabaseObjectSelection) -> Void
    let openSavedQuery: @MainActor (SavedQuery.ID) -> Void
    let refreshSavedQueries: @MainActor () async -> Void
    @State private var overview = WorkspaceSQLObjectOverviewModel()
    @State private var search = ""
    @State private var kind: WorkspaceSQLObjectOverviewKind?
    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\WorkspaceSQLObjectOverviewRow.name)]
    @State private var refreshID = UUID()
    @State private var owner = UUID()
    @State private var searchFocusRequest = 0

    private var rows: [WorkspaceSQLObjectOverviewRow] {
        WorkspaceSQLObjectOverviewRow.filtered(
            overview.entries, search: search,
            schema: model.databaseType == .postgresql ? model.selectedSchema : nil, kind: kind,
            savedQueries: model.savedQueries, database: database
        ).sorted(using: sortOrder)
    }

    private var refreshActions: WorkspaceContentRefreshActions {
        WorkspaceContentRefreshActions(
            title: AppCopy.current.text("刷新表、视图与查询", "Refresh Tables, Views & Queries"),
            isStopping: false, didComplete: overview.didCompleteRefresh && model.savedQueryLoadErrorMessage == nil,
            perform: { refreshID = UUID() }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(AppCopy.current.text("表、视图与查询", "Tables, Views & Queries"))
                    .font(.headline)
                Spacer(minLength: 12)
                Picker(AppCopy.current.text("筛选", "Filter"), selection: $kind) {
                    Text(AppCopy.current.text("全部", "All")).tag(Optional<WorkspaceSQLObjectOverviewKind>.none)
                    ForEach(WorkspaceSQLObjectOverviewKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                WorkspaceGridSearchField(
                    text: $search,
                    placeholder: AppCopy.current.text("搜索名称、注释、类型…", "Search names, comments, types…"),
                    focusRequest: searchFocusRequest, submit: {}, cancel: { search = "" },
                    accessibilityIdentifier: "sqlObjectOverviewSearch"
                )
                .frame(width: 240, height: 24)
                .help(AppCopy.current.text("搜索名称、注释、类型、引擎或排序规则（⌘F）", "Search names, comments, types, engines or collations (⌘F)"))
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(AppCopy.current.text("名称", "Name"), value: \.name) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.kind.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .help(row.type)
                        Text(row.name).lineLimit(1).truncationMode(.tail)
                    }
                    .help(row.savedQuery.map { "\($0.name)\n\($0.sql)" } ?? row.name)
                }
                .width(min: 160, ideal: 230)
                TableColumn(AppCopy.current.text("注释", "Comment"), value: \.comment) { row in
                    Text(row.comment.isEmpty ? "—" : row.comment)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(row.comment)
                }
                .width(min: 120, ideal: 280)
                TableColumn(AppCopy.current.text("行数（估算）", "Rows (estimated)"), value: \.rowCount) { row in
                    Text(row.entry?.estimatedRowCount.map { $0.formatted() } ?? "—")
                        .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 100, ideal: 120, max: 160)
                TableColumn(AppCopy.current.text("占用空间", "Storage"), value: \.storageSize) { row in
                    Text(row.entry?.storageByteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                        .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 100, max: 140)
                if model.databaseType == .mysql || model.databaseType == .doris {
                    TableColumn(AppCopy.current.text("引擎", "Engine"), value: \.engine) { row in
                        Text(row.engine.isEmpty ? "—" : row.engine)
                            .lineLimit(1).truncationMode(.tail).help(row.engine)
                    }
                    .width(min: 70, ideal: 90, max: 140)
                    TableColumn(AppCopy.current.text("排序规则", "Collation"), value: \.collation) { row in
                        Text(row.collation.isEmpty ? "—" : row.collation)
                            .lineLimit(1).truncationMode(.tail).help(row.collation)
                    }
                    .width(min: 130, ideal: 180, max: 260)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button(AppCopy.current.text("打开", "Open")) { open(ids.first) }
                    .disabled(ids.isEmpty)
            } primaryAction: { ids in open(ids.first) }
            .onKeyPress(.return) {
                guard selection != nil else { return .ignored }
                open(selection)
                return .handled
            }
            .overlay {
                if overview.hasLoaded && !overview.isLoading && overview.error == nil
                    && model.savedQueryLoadErrorMessage == nil && rows.isEmpty {
                    Text(AppCopy.current.text("没有匹配的表、视图或查询", "No matching tables, views or queries"))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            WorkspaceDatabaseDataProgressBar(isActive: overview.isLoading)
                .frame(height: 3)
            Divider()
            HStack(spacing: 8) {
                if let error = overview.error ?? model.savedQueryLoadErrorMessage {
                    Text(error).foregroundStyle(.red).lineLimit(1).help(error)
                    Button(AppCopy.current.text("重试", "Retry")) { refreshID = UUID() }
                        .buttonStyle(.link)
                } else {
                    Text(overview.hasLoaded ? AppCopy.current.text("\(rows.count) 个对象", "\(rows.count) objects") : "")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(AppCopy.current.text("双击或回车打开", "Double-click or press Return to open"))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .frame(height: 30)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .focusedSceneValue(\.workspaceGridSearchActions, WorkspaceGridSearchCommandActions(
            search: { searchFocusRequest += 1 }
        ))
        .onAppear { refreshRegistry.updateOverview(refreshActions, owner: owner) }
        .onChange(of: refreshActions) { _, actions in refreshRegistry.updateOverview(actions, owner: owner) }
        .onDisappear { refreshRegistry.removeOverview(owner: owner) }
        .onChange(of: rows.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .task(id: overview.didCompleteRefresh) {
            guard overview.didCompleteRefresh else { return }
            do {
                try await Task.sleep(for: .seconds(1))
                overview.clearRefreshCompletion()
            } catch { /* A newer refresh owns its completion feedback. */ }
        }
        .task(id: "\(refreshID):\(model.connectionState == .connected)") {
            guard model.connectionState == .connected else { return }
            await overview.load(database: database) { database in
                await refreshSavedQueries()
                try Task.checkCancellation()
                return try await model.fetchSQLObjectOverview(in: database)
            }
            if let selection, !rows.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
    }

    private func open(_ id: String?) {
        guard let id, let row = rows.first(where: { $0.id == id }) else { return }
        if let query = row.savedQuery {
            openSavedQuery(query.id)
        } else if let entry = row.entry {
            openObject(WorkspaceDatabaseObjectSelection(databaseName: database, objectName: entry.object.name, kind: entry.object.kind))
        }
    }
}
