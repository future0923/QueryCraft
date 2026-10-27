import SwiftUI

struct SettingsDetailView: View {
    let tab: SettingsTab
    @Bindable var preferences: ApplicationPreferences
    let mcpModel: MCPSettingsModel
    let sshModel: SSHSettingsModel

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
            case .snippets:
                SnippetsSettingsPane()
            case .query:
                QuerySettingsPane(preferences: preferences)
            case .data:
                DataSettingsPane(preferences: preferences)
            case .mcp:
                MCPSettingsPane(model: mcpModel)
            case .plugins:
                PluginSettingsPane()
            case .ssh:
                SSHSettingsPane(model: sshModel)
            }
        }
        .navigationTitle(copy.title(for: tab))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
