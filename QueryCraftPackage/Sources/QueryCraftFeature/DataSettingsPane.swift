import SwiftUI

struct DataSettingsPane: View {
    @Bindable var preferences: ApplicationPreferences

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        Form {
            Section(copy.tableDataSection) {
                Picker(
                    selection: $preferences.tableDataPageSize
                ) {
                    ForEach([50, 100, 200, 500, 1_000], id: \.self) { size in
                        Text(size, format: .number)
                            .tag(size)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.defaultPageSize,
                        description: copy.defaultPageSizeDescription
                    )
                }
                .pickerStyle(.menu)

                Toggle(
                    isOn: $preferences.usesAlternatingTableRows
                ) {
                    SettingsControlLabel(
                        title: copy.alternatingRows,
                        description: copy.alternatingRowsDescription
                    )
                }

                Picker(
                    selection: $preferences.tableNullDisplayStyle
                ) {
                    ForEach(TableNullDisplayStyle.allCases) { style in
                        Text(copy.title(for: style))
                            .tag(style)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.displayNullAs,
                        description: copy.displayNullAsDescription
                    )
                }
                .pickerStyle(.menu)

                Picker(
                    selection: $preferences.tableEmptyStringDisplayStyle
                ) {
                    ForEach(TableEmptyStringDisplayStyle.allCases) { style in
                        Text(copy.title(for: style))
                            .tag(style)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.displayEmptyStringAs,
                        description: copy.displayEmptyStringAsDescription
                    )
                }
                .pickerStyle(.menu)
            }

            Section(copy.copySection) {
                Toggle(
                    isOn: $preferences.copyIncludesColumnNames
                ) {
                    SettingsControlLabel(
                        title: copy.includeColumnNames,
                        description: copy.includeColumnNamesDescription
                    )
                }
            }

            Section(copy.redisSection) {
                Toggle(
                    isOn: $preferences
                        .automaticallyResolvesVisibleRedisKeyTypes
                ) {
                    SettingsControlLabel(
                        title: copy.automaticallyResolveRedisKeyTypes,
                        description: copy
                            .automaticallyResolveRedisKeyTypesDescription
                    )
                }

                Picker(
                    selection: $preferences.redisVisibleKeyTypeBatchSize
                ) {
                    ForEach(
                        ApplicationPreferences
                            .supportedRedisVisibleKeyTypeBatchSizes,
                        id: \.self
                    ) { size in
                        Text(size, format: .number)
                            .tag(size)
                    }
                } label: {
                    SettingsControlLabel(
                        title: copy.redisKeyTypeBatchSize,
                        description: copy.redisKeyTypeBatchSizeDescription
                    )
                }
                .pickerStyle(.menu)
                .disabled(
                    !preferences.automaticallyResolvesVisibleRedisKeyTypes
                )
            }

            Section {
                HStack {
                    Spacer()

                    Button(
                        copy.restoreDataDefaults,
                        systemImage: "arrow.counterclockwise",
                        action: preferences.resetData
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
