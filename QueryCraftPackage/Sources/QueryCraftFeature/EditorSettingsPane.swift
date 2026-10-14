import SwiftUI

struct EditorSettingsPane: View {
    @Bindable var preferences: ApplicationPreferences
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsColors = false

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        Form {
            Section(AppCopy.current.text("语法配色", "Syntax Colors")) {
                HStack {
                    SettingsControlLabel(
                        title: AppCopy.current.text("浅色与深色独立配色", "Separate Light and Dark Colors"),
                        description: AppCopy.current.text(
                            "内置经典、海洋、柔和主题，可自定义语法及背景颜色。",
                            "Classic, Ocean and Soft presets with customizable syntax and background colors."
                        )
                    )
                    Spacer()
                    Button(AppCopy.current.text("自定义配色…", "Customize Colors…")) {
                        showsColors = true
                    }
                    .accessibilityIdentifier("customizeEditorColors")
                }
            }

            Section(copy.indentationSection) {
                Picker(
                    selection: $preferences.editorIndentationStyle
                ) {
                    ForEach(EditorIndentationStyle.allCases) { style in
                        Text(copy.title(for: style))
                            .tag(style)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.indentWith,
                        description: copy.indentWithDescription
                    )
                }
                .pickerStyle(.segmented)

                Picker(
                    selection: $preferences.editorIndentationWidth
                ) {
                    ForEach([2, 4, 6, 8], id: \.self) { width in
                        Text(copy.indentationWidthTitle(width))
                            .tag(width)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.indentWidth,
                        description: copy.indentWidthDescription
                    )
                }
                .pickerStyle(.menu)
            }

            Section(copy.completionSection) {
                Picker(
                    selection: $preferences.editorCompletionKey
                ) {
                    ForEach(EditorCompletionKey.allCases) { key in
                        Text(copy.title(for: key))
                            .tag(key)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.acceptSuggestionWith,
                        description: copy.acceptSuggestionWithDescription
                    )
                }
                .pickerStyle(.menu)
            }

            Section(copy.formattingSection) {
                Picker(
                    selection: $preferences.sqlKeywordCase
                ) {
                    ForEach(SQLKeywordCase.allCases) { keywordCase in
                        Text(copy.title(for: keywordCase))
                            .tag(keywordCase)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.sqlKeywordCase,
                        description: copy.sqlKeywordCaseDescription
                    )
                }
                .pickerStyle(.segmented)
            }

            Section {
                HStack {
                    Spacer()

                    Button(
                        copy.restoreEditorDefaults,
                        systemImage: "arrow.counterclockwise",
                        action: preferences.resetEditor
                    )
                }
            }
        }
        .sheet(isPresented: $showsColors) {
            EditorColorsSettingsView(preferences: preferences, mode: colorScheme == .dark ? .dark : .light)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
