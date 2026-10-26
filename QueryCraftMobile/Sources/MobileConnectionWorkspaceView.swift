import SwiftUI

struct MobileConnectionWorkspaceView: View {
    @Bindable var app: MobileApplicationModel
    @Bindable var workspace: MobileDatabaseWorkspace
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    MobileCatalogView(app: app, browser: workspace.browser, kind: workspace.browser.catalogKind)
                        .navigationTitle(sidebarTitle).navigationBarTitleDisplayMode(.inline)
                        .toolbarTitleMenu {
                            Picker("导航", selection: Binding(get: { app.workspaceTab }, set: { app.selectTab($0) })) {
                                Label("表", systemImage: "tablecells").tag(MobileApplicationModel.WorkspaceTab.tables)
                                Label("查询", systemImage: "terminal").tag(MobileApplicationModel.WorkspaceTab.query)
                                Label("视图", systemImage: "eye").tag(MobileApplicationModel.WorkspaceTab.views)
                            }
                        }
                        .toolbar {
                            MobileWorkspaceToolbar(app: app, workspace: workspace, includesHome: true, includesRefresh: false)
                        }
                } detail: {
                    regularDetail
                        .toolbar { MobileWorkspaceToolbar(app: app, workspace: workspace, includesHome: false) }
                }
            } else {
                compactTabs
            }
        }
        .sheet(item: Binding(get: { workspace.tableActions.request }, set: { if $0 == nil { workspace.tableActions.dismiss() } else { workspace.tableActions.request = $0 } })) { draft in
            MobileTableActionView(controller: workspace.tableActions, draft: draft)
        }
        .sheet(item: Binding(get: { workspace.newTable.request }, set: { if $0 == nil { workspace.newTable.dismiss() } else { workspace.newTable.request = $0 } })) { draft in
            MobileNewTableView(controller: workspace.newTable, draft: draft)
        }
        .sheet(item: Binding(get: { workspace.dataImport?.showing == true ? workspace.dataImport : nil }, set: { if $0 == nil { workspace.closeImport() } })) { model in
            MobileDataImportView(model: model, close: { workspace.closeImport() }, discard: { workspace.closeImport(discard: true) })
        }
        .onChange(of: workspace.browser.selectedObject) { _, selected in
            if selected == nil, case .table = app.destination { app.destination = nil }
        }
        .onChange(of: workspace.browser.selectedSchema) { _, schema in
            if app.workspaceTab != .query { app.destination = nil }
        }
        .onChange(of: workspace.browser.selectedDatabase) { _, database in
            workspace.newTable.cancel()
            if app.workspaceTab != .query { app.destination = nil }
        }

    }

    private var sidebarTitle: String {
        let section: String
        switch app.workspaceTab {
        case .tables: section = "表"
        case .query: section = "查询"
        case .views: section = "视图"
        }
        return workspace.profile.name + " · " + section
    }

    @ViewBuilder private var regularDetail: some View {
        switch app.workspaceTab {
        case .tables: MobileObjectDetail(app: app, workspace: workspace, kind: .table)
        case .views: MobileObjectDetail(app: app, workspace: workspace, kind: .view)
        case .query:
            MobileWorkspaceView(model: workspace.query, widthKey: workspace.profile.id.uuidString, browser: workspace.browser, documentWorkspace: workspace,
                history: app.library.history.filter { $0.profileID == workspace.profile.id }, restoreHistory: { app.restore($0) })
                        .id(workspace.activeDocument?.id)
        }
    }

    // Compact navigation retains the system bottom Glass tab bar. A regular
    // sidebar uses its existing title menu instead of reserving a tab-bar row.
    private var compactTabs: some View {
        TabView(selection: Binding(get: { app.workspaceTab }, set: { app.selectTab($0) })) {
            Tab("表", systemImage: "tablecells", value: MobileApplicationModel.WorkspaceTab.tables) {
                if app.workspaceTab == .tables {
                    MobileObjectNavigation(app: app, workspace: workspace, kind: .table)
                }
            }
            Tab("查询", systemImage: "terminal", value: MobileApplicationModel.WorkspaceTab.query) {
                NavigationStack {
                    MobileWorkspaceView(model: workspace.query, widthKey: workspace.profile.id.uuidString, browser: workspace.browser, documentWorkspace: workspace,
                        history: app.library.history.filter { $0.profileID == workspace.profile.id }, restoreHistory: { app.restore($0) })
                        .id(workspace.activeDocument?.id)
                        .toolbar {
                            MobileWorkspaceToolbar(app: app, workspace: workspace, includesHome: true)
                        }
                }
            }
            Tab("视图", systemImage: "eye", value: MobileApplicationModel.WorkspaceTab.views) {
                if app.workspaceTab == .views {
                    MobileObjectNavigation(app: app, workspace: workspace, kind: .view)
                }
            }
        }
    }
}

private struct MobileObjectDetail: View {
    @Bindable var app: MobileApplicationModel
    @Bindable var workspace: MobileDatabaseWorkspace
    let kind: MobileDatabaseObject.Kind
    var body: some View {
        Group {
            if case let .table(object) = app.destination, object.kind == kind {
                MobileTableView(model: workspace.browser, profileID: workspace.profile.id, schema: workspace.browser.supportsSchemaEditing ? workspace.schema : nil, tableActions: workspace.browser.supportsSchemaEditing ? workspace.tableActions : nil)
            } else {
                ContentUnavailableView(kind == .view ? "选择视图" : "选择表", systemImage: kind == .view ? "eye" : "tablecells",
                    description: Text("从侧栏选择要浏览的对象。"))
                    .navigationTitle(workspace.profile.name)
            }
        }
    }
}

private struct MobileObjectNavigation: View {
    @Bindable var app: MobileApplicationModel
    @Bindable var workspace: MobileDatabaseWorkspace
    let kind: MobileDatabaseObject.Kind
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar

    private var isActive: Bool { app.workspaceTab == (kind == .view ? .views : .tables) }
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            MobileCatalogView(app: app, browser: workspace.browser, kind: kind)
                .navigationTitle(workspace.profile.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    MobileWorkspaceToolbar(app: app, workspace: workspace, includesHome: true,
                        includesRefresh: sizeClass == .compact && preferredColumn == .sidebar)
                }
        } detail: {
            MobileObjectDetail(app: app, workspace: workspace, kind: kind)
                .toolbar { MobileWorkspaceToolbar(app: app, workspace: workspace, includesHome: false) }
        }
        .onChange(of: app.destination, initial: true) { _, destination in
            guard isActive else { return }
            if case let .table(object) = destination, object.kind == kind { preferredColumn = .detail }
            else { preferredColumn = .sidebar }
        }
        .onChange(of: preferredColumn) { _, column in
            if isActive, sizeClass == .compact, column == .sidebar { app.destination = nil }
        }
    }
}

private struct MobileWorkspaceToolbar: ToolbarContent {
    @Bindable var app: MobileApplicationModel
    @Bindable var workspace: MobileDatabaseWorkspace
    let includesHome: Bool
    var includesRefresh = true
    var body: some ToolbarContent {
        if includesHome {
            ToolbarItem(placement: .topBarLeading) {
                Button("连接", systemImage: "chevron.left", action: app.showLibrary)
                    .accessibilityIdentifier("backToConnections")
            }
        }
        if includesHome, app.workspaceTab == .tables, workspace.browser.supportsSchemaEditing,
           let database = workspace.browser.selectedDatabase {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(workspace.newTable.draft == nil ? "新建表" : "新表草稿", systemImage: "plus") { workspace.newTable.present(database: database) }
                        .disabled(workspace.newTable.isSubmitting || workspace.browser.isBackgrounded)
                        .accessibilityIdentifier("newTableButton")
                } label: { Label("操作", systemImage: "ellipsis") }
            }
        }
        if includesRefresh {
            ToolbarItemGroup(placement: .primaryAction) {
                if app.isLoading {
                    Button("取消", systemImage: "stop.circle") {
                        if app.workspaceTab == .query { workspace.query.cancel() }
                        else { workspace.browser.cancelAll(); workspace.schema.cancelRead() }
                    }
                }
                Button("刷新", systemImage: "arrow.clockwise", action: app.refresh)
                    .accessibilityIdentifier("refreshCurrentContent")
            }
        }
    }
}
