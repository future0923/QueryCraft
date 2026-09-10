import SwiftUI

struct QuerySettingsPane: View {
    @Bindable var preferences: ApplicationPreferences

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        Form {
            Section(copy.queryExecutionSection) {
                Picker(selection: $preferences.queryTimeout) {
                    ForEach(QueryTimeoutOption.allCases) { option in
                        Text(copy.title(for: option))
                            .tag(option)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.queryTimeout,
                        description: copy.queryTimeoutDescription
                    )
                }
                .pickerStyle(.menu)

                Picker(selection: $preferences.queryResultRowLimit) {
                    ForEach(QueryResultRowLimit.allCases) { limit in
                        Text(copy.title(for: limit))
                            .tag(limit)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.queryResultRowLimit,
                        description: copy.queryResultRowLimitDescription
                    )
                }
                .pickerStyle(.menu)
            }

            Section(copy.querySafetySection) {
                Toggle(isOn: $preferences.confirmsDangerousSQL) {
                    SettingsControlLabel(
                        title: copy.confirmDangerousSQL,
                        description: copy.confirmDangerousSQLDescription
                    )
                }
            }

            Section {
                HStack {
                    Spacer()

                    Button(
                        copy.restoreQueryDefaults,
                        systemImage: "arrow.counterclockwise",
                        action: preferences.resetQuery
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
