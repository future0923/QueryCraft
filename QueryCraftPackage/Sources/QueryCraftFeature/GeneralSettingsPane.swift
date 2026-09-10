import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var preferences: ApplicationPreferences
    @State private var initialLanguage: ApplicationLanguage?
    @ObservedObject private var softwareUpdateManager =
        SoftwareUpdateManager.shared

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        Form {
            Section(copy.languageSection) {
                Picker(
                    selection: $preferences.applicationLanguage
                ) {
                    ForEach(ApplicationLanguage.allCases) { language in
                        Text(copy.title(for: language))
                            .tag(language)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.settingsLanguage,
                        description: copy.settingsLanguageDescription
                    )
                }
                .pickerStyle(.menu)

                if let initialLanguage,
                   preferences.applicationLanguage != initialLanguage
                {
                    Text(copy.languageRestartNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(copy.startupSection) {
                Picker(selection: $preferences.startupBehavior) {
                    ForEach(ApplicationStartupBehavior.allCases) { behavior in
                        Text(copy.title(for: behavior))
                            .tag(behavior)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.onLaunch,
                        description: copy.onLaunchDescription
                    )
                }
                .pickerStyle(.menu)
            }

            Section(copy.softwareUpdateSection) {
                Toggle(
                    isOn: $preferences.automaticallyChecksForUpdates
                ) {
                    SettingsControlLabel(
                        title: copy.automaticallyCheckForUpdates,
                        description:
                            copy.automaticallyCheckForUpdatesDescription
                    )
                }
                .onChange(
                    of: preferences.automaticallyChecksForUpdates
                ) { _, enabled in
                    softwareUpdateManager
                        .setAutomaticallyChecksForUpdates(enabled)
                }

                HStack {
                    Spacer()

                    Button(
                        copy.checkForUpdates,
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                        action: softwareUpdateManager.checkForUpdates
                    )
                    .disabled(!softwareUpdateManager.canCheckForUpdates)
                }
            }

            Section {
                HStack {
                    Spacer()

                    Button(
                        copy.restoreGeneralDefaults,
                        systemImage: "arrow.counterclockwise",
                        action: preferences.resetGeneral
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            if initialLanguage == nil {
                initialLanguage = preferences.applicationLanguage
            }
        }
    }
}
