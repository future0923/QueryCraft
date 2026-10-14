import AppKit
import CodeEditSourceEditor
import SwiftUI
import UniformTypeIdentifiers

struct EditorColorsSettingsView: View {
    @Bindable var preferences: ApplicationPreferences
    @Environment(\.dismiss) private var dismiss
    @State var mode: EditorColorMode
    @State private var session: EditorColorEditingSession
    @State private var previewKind = EditorColorPreviewKind.mysql
    @State private var selectedRole: EditorColorRole?
    @State private var themeName = ""
    @State private var namingTheme = false
    @State private var errorMessage: String?
    @State private var showsReadability = false
    private let language: ApplicationLanguage
    private var copy: AppCopy { AppCopy(language: language) }

    init(preferences: ApplicationPreferences, mode: EditorColorMode, language: ApplicationLanguage = .activeInterfaceLanguage) {
        self.language = language
        self.preferences = preferences
        _mode = State(initialValue: mode)
        _session = State(initialValue: EditorColorEditingSession(settings: preferences.editorColors))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                preview.frame(width: 420)
                Divider()
                colors
            }
        }
        .frame(minWidth: 960, idealWidth: 960, maxWidth: .infinity,
               minHeight: 700, idealHeight: 700, maxHeight: .infinity)
        .accessibilityIdentifier("editorColorsSettings")
        .onChange(of: mode) { _, _ in session.finishContinuousChange() }
        .alert(copy.text("保存个人主题", "Save Personal Theme"), isPresented: $namingTheme) {
            TextField(copy.text("名称", "Name"), text: $themeName)
            Button(copy.text("取消", "Cancel"), role: .cancel) {}
            Button(copy.text("保存", "Save")) {
                let name = themeName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { EditorThemeFiles.append(.init(name: name, settings: preferences.editorColors), to: preferences) }
            }
            .disabled(themeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(copy.text("主题文件", "Theme File"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button(copy.text("好", "OK")) { errorMessage = nil } }
          message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(copy.text("编辑器配色", "Editor Colors")).font(.headline)
            Spacer()
            Button(copy.text("撤销调色", "Undo Colors"), systemImage: "arrow.uturn.backward") { session.undo(preferences) }
                .labelStyle(.iconOnly).disabled(!session.canUndo)
                .help(copy.text("撤销调色", "Undo Colors"))
            Button(copy.text("重做调色", "Redo Colors"), systemImage: "arrow.uturn.forward") { session.redo(preferences) }
                .labelStyle(.iconOnly).disabled(!session.canRedo)
                .help(copy.text("重做调色", "Redo Colors"))
            Menu(copy.text("主题", "Themes")) {
                Button(copy.text("保存当前配色…", "Save Current Colors…")) { themeName = ""; namingTheme = true }
                if !preferences.editorThemes.isEmpty {
                    Menu(copy.text("应用个人主题（浅色与深色）", "Apply Personal Theme (Light & Dark)")) {
                        ForEach(preferences.editorThemes) { theme in
                            Button(theme.name) { session.change(preferences) { $0 = theme.settings } }
                        }
                    }
                    Menu(copy.text("删除个人主题", "Delete Personal Theme")) {
                        ForEach(preferences.editorThemes) { theme in
                            Button(theme.name) { preferences.editorThemes.removeAll { $0.id == theme.id } }
                        }
                    }
                }
                Divider()
                Button(copy.text("导入主题…", "Import Theme…"), action: importTheme)
                Button(copy.text("导出当前主题…", "Export Current Theme…"), action: exportTheme)
                Divider()
                Button(copy.text("恢复本次打开前的配色", "Restore Colors from Before Opening")) { session.restore(preferences) }
                    .disabled(preferences.editorColors == session.original)
            }
            Button(copy.text("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(12)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(copy.text("编辑配色", "Edit Appearance"), selection: $mode) {
                Text(copy.text("浅色", "Light")).tag(EditorColorMode.light)
                Text(copy.text("深色", "Dark")).tag(EditorColorMode.dark)
            }.pickerStyle(.segmented).accessibilityIdentifier("editorColorMode")
            HStack {
                Picker(copy.text("预设", "Preset"), selection: presetBinding) {
                    ForEach(EditorColorPreset.allCases) { Text($0.title(language: language)).tag($0) }
                }.accessibilityIdentifier("editorColorPreset")
                Picker(copy.text("示例", "Sample"), selection: $previewKind) {
                    ForEach(EditorColorPreviewKind.allCases) { Text($0.title).tag($0) }
                }
            }
            EditorColorPreview(settings: preferences.editorColors, mode: mode, kind: previewKind, language: language) { selectedRole = $0 }
                .id(previewKind)
                .environment(\.colorScheme, mode == .dark ? .dark : .light)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            Text(copy.text("点击示例文字定位颜色项。示例可编辑；更改配色立即保存，支持撤销。", "Click sample text to locate its color. Samples are editable. Colors save immediately and can be undone."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12)
    }

    private var colors: some View {
        ScrollViewReader { reader in
            Form {
                Section(copy.text("文字样式", "Text Style")) {
                    Toggle(copy.text("关键字加粗", "Bold Keywords"), isOn: styleBinding(\.boldKeywords))
                    Toggle(copy.text("注释斜体", "Italic Comments"), isOn: styleBinding(\.italicComments))
                }
                Section(copy.text("语法颜色", "Syntax Colors")) {
                    ForEach(EditorColorRole.syntax) { colorRow($0).id($0) }
                }
                Section(copy.text("编辑区域", "Editor Surface")) {
                    ForEach(EditorColorRole.surface) { colorRow($0).id($0) }
                }
                Section(copy.text("可读性", "Readability")) {
                    readability
                }
                Section {
                    Button(copy.text("恢复当前外观默认配色", "Reset This Appearance"), systemImage: "arrow.counterclockwise") {
                        session.change(preferences) { $0[mode] = EditorColorPalette() }
                    }
                    .disabled(preferences.editorColors[mode] == EditorColorPalette())
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
            .onChange(of: selectedRole) { _, role in if let role { reader.scrollTo(role, anchor: .center) } }
        }
    }

    private var readability: some View {
        let failures = EditorColorReadability.checks(settings: preferences.editorColors, mode: mode).filter { $0.ratio < $0.minimum }
        let selectionOnly = !failures.isEmpty && failures.allSatisfy { $0.background == .selection }
        return VStack(alignment: .leading, spacing: 8) {
            if failures.isEmpty {
                Label(copy.text("对比度良好", "Good Contrast"), systemImage: "checkmark.circle")
                Text(copy.text("文字和光标在已检查的背景上均清晰可辨。", "Text and cursor meet the contrast targets on checked backgrounds."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(selectionOnly
                      ? copy.text("选中文字时，部分颜色可能不够清晰", "Some Colors May Be Hard to Read When Selected")
                      : copy.text("部分颜色可能不够清晰", "Some Colors May Be Hard to Read"),
                      systemImage: "exclamationmark.triangle")
                Text(selectionOnly
                     ? copy.text("这些提醒只针对选区背景，不代表普通编辑状态有问题。可调整文字颜色或选区底色。", "These suggestions concern the selection background. You can adjust the text colors or selection color.")
                     : copy.text("文字与底色过于接近时会影响辨认。展开查看具体颜色，点击即可定位设置项。", "Text can be harder to read when its color is close to the background. Expand the details and click a color to adjust it."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(copy.text("查看 \(failures.count) 项建议", "Show \(failures.count) Suggestions"), isExpanded: $showsReadability) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(failures) { issue in
                            Button {
                                selectedRole = issue.role
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(copy.text("\(issue.role.title(language: language)) · \(issue.background.title(language: language))背景",
                                                       "\(issue.role.title(language: language)) on \(issue.background.title(language: language))"))
                                        Text(copy.text("当前 \(issue.ratio.formatted(.number.precision(.fractionLength(1)))):1，建议至少 \(issue.minimum.formatted()):1",
                                                       "Current \(issue.ratio.formatted(.number.precision(.fractionLength(1)))):1; suggested minimum \(issue.minimum.formatted()):1"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.top, 8)
                }
                Text(copy.text("仅供参考，配色由你决定。", "Suggestions only; you choose your colors."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presetBinding: Binding<EditorColorPreset> {
        let target = mode
        return Binding(get: { preferences.editorColors[target].preset }, set: { value in
            session.change(preferences) { $0[target].apply(value) }
        })
    }
    private func styleBinding(_ keyPath: WritableKeyPath<EditorColorPalette, Bool>) -> Binding<Bool> {
        let target = mode
        return Binding(get: { preferences.editorColors[target][keyPath: keyPath] }, set: { value in
            session.change(preferences) { $0[target][keyPath: keyPath] = value }
        })
    }
    private func colorRow(_ role: EditorColorRole) -> some View {
        let target = mode
        let palette = preferences.editorColors[target]
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.title(language: language))
                Text(role.example).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            EditorColorWell(color: EditorHexColor.color(palette.hex(for: role, mode: target)), label: role.title(language: language),
                            beginChange: { session.finishContinuousChange() }) { color in
                if let hex = EditorHexColor.hex(color) {
                    session.change(preferences, key: target.rawValue + role.rawValue) { $0[target].setHex(hex, for: role) }
                }
            }
            .frame(width: 28, height: 24).id(target.rawValue + role.rawValue)
            .accessibilityIdentifier("editorColor.\(role.rawValue)")
            EditorHexField(value: palette.hex(for: role, mode: target), label: role.title(language: language)) { hex in
                session.change(preferences) { $0[target].setHex(hex, for: role) }
            }.id("hex" + target.rawValue + role.rawValue)
            Button(copy.text("恢复", "Reset") + " " + role.title(language: language), systemImage: "arrow.counterclockwise") {
                session.change(preferences) { $0[target].reset(role) }
            }.labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(palette.overrides[role.rawValue] == nil)
                .help(copy.text("恢复此项预设颜色", "Restore Preset Color"))
        }
        .padding(.vertical, 2)
        .listRowBackground(selectedRole == role ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            do {
                guard let theme = try EditorThemeFiles.read(response: response, url: panel.url) else { return }
                EditorThemeFiles.append(theme, to: preferences)
                session.change(preferences) { $0 = theme.settings }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func exportTheme() {
        let settings = preferences.editorColors
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "QueryCraft-theme.json"
        panel.begin { response in
            do {
                try EditorThemeFiles.write(response: response, url: panel.url, settings: settings)
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
extension EditorColorPreset {
    var title: String { title(language: .activeInterfaceLanguage) }
    func title(language: ApplicationLanguage) -> String {
        let copy = AppCopy(language: language)
        return switch self {
        case .classic: copy.text("经典", "Classic")
        case .ocean: copy.text("海洋", "Ocean")
        case .soft: copy.text("柔和", "Soft")
        }
    }
}

extension EditorColorRole {
    var title: String { title(language: .activeInterfaceLanguage) }
    func title(language: ApplicationLanguage) -> String {
        let copy = AppCopy(language: language)
        switch self {
        case .text: return copy.text("普通文字", "Plain Text")
        case .keyword: return copy.text("关键字", "Keywords")
        case .object: return copy.text("对象名称 / 请求路径", "Objects / Request Paths")
        case .property: return copy.text("字段 / JSON 键", "Columns / JSON Keys")
        case .function: return copy.text("函数", "Functions")
        case .type: return copy.text("数据类型", "Data Types")
        case .string: return copy.text("字符串", "Strings")
        case .number: return copy.text("数字", "Numbers")
        case .boolean: return copy.text("布尔值 / 空值", "Booleans / Null")
        case .variable: return copy.text("变量 / 别名", "Variables / Aliases")
        case .parameter: return copy.text("参数", "Parameters")
        case .attribute: return copy.text("修饰符 / 转义", "Modifiers / Escapes")
        case .operator: return copy.text("运算符", "Operators")
        case .punctuation: return copy.text("标点", "Punctuation")
        case .comment: return copy.text("注释", "Comments")
        case .background: return copy.text("背景", "Background")
        case .currentLine: return copy.text("当前行", "Current Line")
        case .selection: return copy.text("选区", "Selection")
        case .cursor: return copy.text("光标", "Cursor")
        case .lineNumber: return copy.text("行号", "Line Numbers")
        case .currentLineNumber: return copy.text("当前行号", "Current Line Number")
        case .searchMatch: return copy.text("其他搜索匹配", "Other Search Matches")
        case .searchCurrent: return copy.text("当前搜索匹配", "Current Search Match")
        case .searchText: return copy.text("当前匹配文字", "Current Match Text")
        }
    }

    var example: String {
        switch self {
        case .text: "QueryCraft"
        case .keyword: "SELECT · WHERE · GET"
        case .object: "users · idx_active · /_search"
        case .property: "id · name · \"enabled\""
        case .function: "COUNT() · NOW()"
        case .type: "INT · VARCHAR · BOOLEAN"
        case .string: "'Hello' · \"active\""
        case .number: "42 · 3.14"
        case .boolean: "TRUE · FALSE · NULL"
        case .variable: "AS total · AS u"
        case .parameter: "? · $1"
        case .attribute: "DEFAULT · DESC · \\n"
        case .operator: "+ · = · >= · <>"
        case .punctuation: "( ) , ; { }"
        case .comment: "-- comment · /* comment */"
        case .background: AppCopy.current.text("编辑区域底色", "Editor background")
        case .currentLine: AppCopy.current.text("光标所在行底色", "Active line background")
        case .selection: AppCopy.current.text("以固定透明度叠加", "Blended at a fixed opacity")
        case .cursor: AppCopy.current.text("插入位置指示", "Insertion point")
        case .lineNumber: "1 · 2 · 3"
        case .currentLineNumber: AppCopy.current.text("光标所在行的行号", "Number of active line")
        case .searchMatch: AppCopy.current.text("搜索结果底色", "Search result background")
        case .searchCurrent: AppCopy.current.text("正在查看的匹配底色", "Active match background")
        case .searchText: AppCopy.current.text("正在查看的匹配文字", "Active match foreground")
        }
    }
}
