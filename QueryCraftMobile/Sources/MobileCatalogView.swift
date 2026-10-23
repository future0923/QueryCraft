import SwiftUI

struct MobileCatalogView: View {
    @Bindable var app: MobileApplicationModel
    @Bindable var browser: MobileBrowserModel
    let kind: MobileDatabaseObject.Kind
    @FocusState private var searchFocused: Bool
    private var noun: String { kind == .view ? "视图" : "表" }
    var body: some View {
        List(selection: $app.destination) {
            Section {
                Picker("数据库", selection: Binding(get: { browser.selectedDatabase ?? "" }, set: { browser.selectDatabase($0.isEmpty ? nil : $0) })) {
                    Text("选择数据库").tag("")
                    ForEach(browser.databases ?? [], id: \.self) { Text($0).tag($0) }
                }.disabled(browser.databases == nil)
            }
            Section(noun) {
                ForEach(browser.visibleObjects) { object in
                    NavigationLink(value: MobileRoute.table(object)) {
                        HStack(spacing: 10) {
                            Image(systemName: object.kind == .view ? "eye" : "tablecells").foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(object.name).font(.subheadline)
                                if !object.comment.isEmpty { Text(String(object.comment.prefix(100))).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            if browser.changesByObject[object.id]?.hasChanges == true || browser.schema?.drafts[object.id]?.hasChanges == true {
                                Spacer(minLength: 0)
                                Image(systemName: "square.and.pencil").foregroundStyle(.tint).accessibilityLabel("有待提交改动")
                            }
                        }.padding(.vertical, 2)
                    }
                    .contextMenu {
                        if object.kind == .table, let controller = app.workspace?.tableActions {
                            MobileTableActionMenu(controller: controller, object: object)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .accessibilityIdentifier("connectionCatalog")
        .searchable(text: $browser.search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索" + noun)
        .searchFocused($searchFocused)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: app.destination) { _, _ in searchFocused = false }
        .onDisappear { searchFocused = false }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).opacity(browser.isLoadingCatalog ? 1 : 0)
                Text(app.message ?? browser.catalogError ?? catalogStatus)
                    .font(.caption).foregroundStyle(app.message != nil || browser.catalogError != nil ? Color.red : .secondary).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).frame(height: 44).background(Color(uiColor: .systemBackground))
        }
    }
    private var catalogStatus: String {
        if browser.isLoadingCatalog { return "正在加载…" }
        guard let catalog = browser.catalog else { return "等待加载" }
        if browser.search.isEmpty { return "\(catalog.objects.count) 个\(noun)" }
        return "\(browser.visibleObjects.count) / \(catalog.objects.count) 个\(noun)"
    }
}
