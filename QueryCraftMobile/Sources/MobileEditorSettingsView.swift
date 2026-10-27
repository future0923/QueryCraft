import SwiftUI
import UniformTypeIdentifiers

struct MobileEditorSettingsView: View {
    @Bindable var preferences: MobileEditorPreferences
    var connection: MobileSQLConfiguration? = nil
    var isEmbedded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode = EditorColorMode.light
    @State private var choseMode = false
    @State private var importing = false
    @State private var exporting = false
    @State private var themeFile: MobileEditorThemeFile?
    @State private var message: String?
    @State private var history = EditorColorChangeHistory()
    @State private var changeKey: String?
    @State private var replaying = false
    var body: some View {
        MobileSettingsNavigation(embedded: isEmbedded) {
            Form {
                Section("字体") {
                    Picker("等宽字体", selection: $preferences.fontFamily) {
                        Text("系统等宽").tag("")
                        ForEach(fonts, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("字号：\(Int(preferences.fontSize))", value: $preferences.fontSize, in: 11...18)
                }
                Section("缩进与补全") {
                    Picker("缩进方式", selection: $preferences.indentationStyle) { Text("空格").tag(EditorIndentationStyle.spaces); Text("Tab").tag(EditorIndentationStyle.tabs) }
                    Picker("缩进宽度", selection: $preferences.indentationWidth) { ForEach(EditorPreferenceRules.indentationWidths, id: \.self) { Text("\($0)").tag($0) } }
                    Picker("接受补全", selection: $preferences.completionKey) {
                        Text("Return 或 Tab").tag(EditorCompletionKey.returnOrTab)
                        Text("Return").tag(EditorCompletionKey.returnKey); Text("Tab").tag(EditorCompletionKey.tab)
                    }
                    Picker("格式化关键字", selection: $preferences.keywordCase) {
                        Text("大写").tag(SQLKeywordCase.uppercase); Text("小写").tag(SQLKeywordCase.lowercase); Text("保持原样").tag(SQLKeywordCase.preserve)
                    }
                }
                if let connection, connection.driver == .mysql || connection.driver == .doris {
                    Section("当前连接高亮") {
                        let key = SQLHighlightContext.connectionKey(connection.sharedConfiguration)
                        Toggle("双引号按标识符高亮", isOn: Binding(get: { preferences.ansiQuoteConnections.contains(key) }, set: { if $0 { preferences.ansiQuoteConnections.insert(key) } else { preferences.ansiQuoteConnections.remove(key) } }))
                        Text("仅影响显示，不改变 SQL 执行、格式化或服务器 sql_mode。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("语法与背景配色") {
                    Picker("外观", selection: Binding(get: { mode }, set: { choseMode = true; mode = $0 })) { Text("浅色").tag(EditorColorMode.light); Text("深色").tag(EditorColorMode.dark) }.pickerStyle(.segmented)
                    Picker("主题", selection: Binding(get: { preferences.colors[mode].preset }, set: { preferences.colors[mode].apply($0) })) {
                        Text("经典").tag(EditorColorPreset.classic); Text("海洋").tag(EditorColorPreset.ocean); Text("柔和").tag(EditorColorPreset.soft)
                    }
                    Toggle("关键字加粗", isOn: $preferences.colors[mode].boldKeywords)
                    Toggle("注释斜体", isOn: $preferences.colors[mode].italicComments)
                    ForEach(EditorColorRole.allCases.filter { ![.searchMatch, .searchCurrent, .searchText].contains($0) }) { role in
                        ColorPicker(roleTitle(role), selection: Binding(get: { Color(uiColor: EditorHexColor.color(preferences.colors[mode].hex(for: role, mode: mode))) }, set: { color in
                            if let hex = EditorHexColor.hex(UIColor(color)) { changeKey = mode.rawValue + "." + role.rawValue; preferences.colors[mode].setHex(hex, for: role) }
                        }), supportsOpacity: false)
                    }
                    HStack {
                        Button("撤销配色") { if let previous = history.undo(current: preferences.colors) { replaying = true; preferences.colors = previous } }.disabled(!history.canUndo)
                        Spacer()
                        Button("重做") { if let next = history.redo(current: preferences.colors) { replaying = true; preferences.colors = next } }.disabled(!history.canRedo)
                    }
                }
                Section { Text("原生查找的匹配颜色由系统绘制；主题文件仍保留查找配色，便于与 Mac 互换。中文组合输入期间不重排或改写文本。").font(.footnote).foregroundStyle(.secondary) }
                Section("主题文件") {
                    ForEach(preferences.themes) { theme in
                        Button(theme.name) { preferences.colors = theme.settings }
                            .swipeActions { Button("删除", role: .destructive) { preferences.themes.removeAll { $0.id == theme.id } } }
                    }
                    Button("导入主题", systemImage: "square.and.arrow.down") { importing = true }
                    Button("导出当前主题", systemImage: "square.and.arrow.up") {
                        do { themeFile = .init(data: try EditorThemeArchive(name: "QueryCraft", settings: preferences.colors).data()); exporting = true }
                        catch { message = error.localizedDescription }
                    }
                }
                Section { Button("恢复编辑器默认设置", role: .destructive) { preferences.reset() } }
                if let message { Section { Text(message).foregroundStyle(.red) } }
            }
            .mobileSettingsCanvas()
            .navigationTitle("编辑器设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { if !isEmbedded { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } }
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in if !choseMode { mode = scheme == .dark ? .dark : .light } }
        .onChange(of: preferences.colors) { old, next in
            if replaying { replaying = false }
            else { history.record(from: old, to: next, key: changeKey) }
            changeKey = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                try preferences.importTheme(file.read(upToCount: 262_145) ?? Data())
            } catch { if (error as? CocoaError)?.code != .userCancelled { message = error.localizedDescription } }
        }
        .fileExporter(isPresented: $exporting, document: themeFile, contentType: .json, defaultFilename: "QueryCraft-theme.json") { result in
            if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled { message = error.localizedDescription }
        }
    }
    private var fonts: [String] { MobileFontCatalog.families }
    private func roleTitle(_ role: EditorColorRole) -> String {
        switch role {
        case .text: "正文"; case .keyword: "关键字"; case .object: "对象"; case .property: "字段"; case .function: "函数"; case .type: "类型"
        case .string: "字符串"; case .number: "数字"; case .boolean: "布尔值"; case .variable: "变量"; case .parameter: "参数"; case .attribute: "属性"
        case .operator: "运算符"; case .punctuation: "标点"; case .comment: "注释"; case .background: "背景"; case .currentLine: "当前行"; case .selection: "选区"
        case .cursor: "光标"; case .lineNumber: "行号"; case .currentLineNumber: "当前行号"; case .searchMatch: "查找匹配"; case .searchCurrent: "当前匹配"; case .searchText: "匹配文本"
        }
    }
}

struct MobileEditorThemeFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        _ = try EditorThemeArchive.read(data)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
