import SwiftUI

struct AppearanceSettingsPane: View {
    @Bindable var preferences: ApplicationPreferences

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        Form {
            Section(copy.interfaceSection) {
                Picker(copy.appearance, selection: $preferences.appearance) {
                    ForEach(ApplicationAppearance.allCases) { appearance in
                        Text(copy.title(for: appearance))
                            .tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(copy.editorFontSection) {
                fontFamilyPicker(selection: $preferences.editorFontFamily)
                fontSizeControl(value: $preferences.editorFontSize)
            }

            Section(copy.dataGridFontSection) {
                fontFamilyPicker(selection: $preferences.dataGridFontFamily)
                fontSizeControl(value: $preferences.dataGridFontSize)
            }

            Section(copy.previewSection) {
                Text("SELECT * FROM users WHERE id = 42;")
                    .font(Font(preferences.editorFont()))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
            }

            Section {
                HStack {
                    Spacer()

                    Button(
                        copy.restoreAppearanceDefaults,
                        systemImage: "arrow.counterclockwise",
                        action: preferences.resetAppearance
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private func fontFamilyPicker(selection: Binding<String>) -> some View {
        Picker(copy.fontFamily, selection: selection) {
            Text(copy.systemMonospaced)
                .tag("")
            ForEach(EditorFontCatalog.families, id: \.self) { family in
                Text(family)
                    .tag(family)
            }
        }
        .pickerStyle(.menu)
    }

    private func fontSizeControl(value: Binding<Double>) -> some View {
        Picker(copy.fontSize, selection: value) {
            ForEach(11...18, id: \.self) { size in
                Text("\(size) pt")
                    .tag(Double(size))
            }
        }
        .pickerStyle(.menu)
    }
}
