import SwiftUI

struct SettingsDetailView: View {
    let tab: SettingsTab
    @Bindable var preferences: ApplicationPreferences

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        Group {
            switch tab {
            case .general:
                GeneralSettingsPane(preferences: preferences)
            case .license:
                LicenseSettingsPane(preferences: preferences)
            case .appearance:
                AppearanceSettingsPane(preferences: preferences)
            case .editor:
                EditorSettingsPane(preferences: preferences)
            case .query:
                QuerySettingsPane(preferences: preferences)
            case .data:
                DataSettingsPane(preferences: preferences)
            case .plugins:
                PluginSettingsPane()
            }
        }
        .navigationTitle(copy.title(for: tab))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
