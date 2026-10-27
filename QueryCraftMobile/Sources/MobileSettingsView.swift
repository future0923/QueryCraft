import SwiftUI

/// Native grouped settings, presented only from the connection library.
struct MobileSettingsView: View {
    @Bindable var preferences: MobilePreferences = .shared
    var connection: MobileSQLConfiguration? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { MobileAppearanceSettingsView(preferences: preferences) } label: { Label("外观", systemImage: "paintpalette") }
                        .accessibilityIdentifier("settings.appearanceLink")
                    NavigationLink { MobileEditorSettingsView(preferences: .shared, connection: connection, isEmbedded: true) } label: { Label("编辑器", systemImage: "text.cursor") }
                        .accessibilityIdentifier("settings.editor")
                    NavigationLink { MobileSQLSnippetsView(store: .shared, isEmbedded: true) } label: { Label("SQL 片段", systemImage: "curlybraces") }
                }
                Section {
                    NavigationLink { MobileDataSettingsView(preferences: preferences) } label: { Label("表格与记录", systemImage: "tablecells") }
                        .accessibilityIdentifier("settings.data")
                    NavigationLink { MobileExportSettingsView(preferences: preferences) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("settings.export")
                }
                Section {
                    NavigationLink {
                        Form {
                            Section {
                                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                                LabeledContent("构建", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                            }
                        }.mobileSettingsCanvas().navigationTitle("关于").navigationBarTitleDisplayMode(.inline)
                    } label: { Label("关于 QueryCraft", systemImage: "info.circle") }
                }
            }
            .listStyle(.insetGrouped)
            .mobileSettingsCanvas()
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .mobileAppearance()
        .preferredColorScheme(preferences.colorScheme)
        .accessibilityIdentifier("mobileSettings")
    }
}

struct MobileAppearanceSettingsView: View {
    @Bindable var preferences: MobilePreferences
    @State private var restoring = false
    var body: some View {
        Form {
            Section("界面") {
                Picker("外观", selection: $preferences.appearance) {
                    Text("跟随系统").tag(ApplicationAppearance.system)
                    Text("浅色").tag(ApplicationAppearance.light)
                    Text("深色").tag(ApplicationAppearance.dark)
                }.accessibilityIdentifier("settings.appearance")
            }
            Section("表格字体") {
                Picker("字体", selection: $preferences.dataGridFontFamily) {
                    Text("系统等宽字体").tag("")
                    ForEach(MobileFontCatalog.families, id: \.self) { Text($0).tag($0) }
                }
                Picker("字号", selection: $preferences.dataGridFontSize) {
                    ForEach(11...18, id: \.self) { Text("\($0) pt").tag(Double($0)) }
                }.accessibilityIdentifier("settings.gridFontSize")
            }
            Section { Button("恢复默认设置", role: .destructive) { restoring = true } }
        }
        .mobileSettingsCanvas().navigationTitle("外观").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("恢复界面外观与表格字体？", isPresented: $restoring, titleVisibility: .visible) {
            Button("恢复默认设置", role: .destructive) { preferences.resetAppearance() }
        }
    }
}

/// Existing editor and snippet screens can be pushed by Settings while their
/// other callers retain the original standalone navigation presentation.
struct MobileSettingsNavigation<Content: View>: View {
    let embedded: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }
}

private struct MobileSettingsCanvas: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let background = scheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground)
        content
            .scrollContentBackground(.hidden)
            .background(background)
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
    }
}

extension View {
    func mobileSettingsCanvas() -> some View { modifier(MobileSettingsCanvas()) }
}

struct MobileDataSettingsView: View {
    @Bindable var preferences: MobilePreferences
    @State private var restoring = false
    var body: some View {
        Form {
            Section {
                Picker("默认每页行数", selection: $preferences.tableDataPageSize) {
                    ForEach(MobilePreferences.pageSizes, id: \.self) { Text("\($0) 行").tag($0) }
                }.accessibilityIdentifier("settings.pageSize")
            } footer: { Text("用于新打开的表格和索引。已打开的页面保留原设置。") }
            Section("显示") {
                Toggle("交替行背景", isOn: $preferences.usesAlternatingTableRows)
                    .accessibilityIdentifier("settings.alternatingRows")
                Toggle("表头显示类型与注释", isOn: $preferences.showsColumnDetails)
                    .accessibilityIdentifier("settings.columnDetails")
                Toggle("记录详情显示类型与注释", isOn: $preferences.showsInspectorDetails)
                Toggle("自动识别时间戳", isOn: $preferences.formatsTimestamps)
                    .accessibilityIdentifier("settings.timestamps")
                Picker("NULL 显示", selection: $preferences.nullStyle) {
                    ForEach(TableNullDisplayStyle.allCases) { Text($0.displayText.isEmpty ? "空白" : $0.displayText).tag($0) }
                }
                Picker("空字符串显示", selection: $preferences.emptyStringStyle) {
                    ForEach(TableEmptyStringDisplayStyle.allCases) { Text($0.displayText.isEmpty ? "空白" : $0.displayText).tag($0) }
                }
            }
            Section { Text("仅改变显示方式，复制、编辑和导出保留原始值。单列设置的时间格式优先。")
                    .font(.footnote).foregroundStyle(.secondary) }
            Section { Button("恢复表格默认设置", role: .destructive) { restoring = true } }
        }
        .mobileSettingsCanvas().navigationTitle("表格与记录").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("恢复表格默认设置？", isPresented: $restoring, titleVisibility: .visible) {
            Button("恢复默认设置", role: .destructive) { preferences.resetData() }
        }
    }
}

struct MobileExportSettingsView: View {
    @Bindable var preferences: MobilePreferences
    @State private var restoring = false
    @FocusState private var focusedInput: MobileExportInput?
    var body: some View {
        Form {
            Section {
                ForEach(WorkspaceDataExportFormat.allCases) { format in
                    NavigationLink(format.menuTitle) {
                        Form {
                            Section { MobileExportOptionsFields(preferences: $preferences.dataExport, format: format, focusedInput: $focusedInput) }
                            if format == .sql {
                                Section { Toggle("包含数据库 / Schema 名", isOn: $preferences.dataExport.sqlIncludesDatabaseName) }
                            }
                            if !preferences.dataExport.isValid {
                                Section { Text("每条 INSERT 的行数须为 1～100,000。无效值不会用于导出。")
                                    .foregroundStyle(.red) }
                            }
                        }.mobileSettingsCanvas().navigationTitle(format.menuTitle).navigationBarTitleDisplayMode(.inline)
                            .scrollDismissesKeyboard(.immediately)
                            .onSubmit { focusedInput = nil }
                    }
                }
            } footer: { Text("作为新导出任务的默认值，每次导出仍可单独调整。") }
            Section { Button("恢复导出默认设置", role: .destructive) { restoring = true } }
        }
        .mobileSettingsCanvas().navigationTitle("导出默认设置").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("恢复所有导出格式的默认设置？", isPresented: $restoring, titleVisibility: .visible) {
            Button("恢复默认设置", role: .destructive) { preferences.dataExport = .init() }
        }
    }
}
