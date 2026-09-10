import SwiftUI

struct PluginSettingsPane: View {
    @State private var model = PluginSettingsModel()
    @State private var requestedAction: PluginSettingsAction?
    @State private var actionRequestID: UUID?
    @State private var uninstallCandidate: DatabaseDriverCatalogItem?
    @State private var isShowingUninstallConfirmation = false

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    SettingsControlLabel(
                        title: copy.checkPluginUpdates,
                        description: model.isRefreshing
                            ? copy.checkingPluginUpdates
                            : copy.pluginUpdatesChecked
                    )
                    Spacer()
                    Button(
                        copy.checkPluginUpdates,
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    ) {
                        requestedAction = nil
                        actionRequestID = UUID()
                    }
                    .labelStyle(.iconOnly)
                    .help(copy.checkPluginUpdates)
                    .disabled(model.isRefreshing)
                }
            }

            Section(copy.databaseDriverPluginsSection) {
                ForEach(model.visibleItems) { item in
                    PluginSettingsRow(
                        item: item,
                        install: { request(.install(item.entry.databaseType)) },
                        update: { request(.update(item.entry.databaseType)) },
                        uninstall: {
                            uninstallCandidate = item
                            isShowingUninstallConfirmation = true
                        }
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .searchable(
            text: $model.searchText,
            prompt: copy.pluginSearchPlaceholder
        )
        .task {
            await model.load()
        }
        .task(id: actionRequestID) {
            guard actionRequestID != nil else { return }
            if let requestedAction {
                switch requestedAction {
                case .install(let databaseType):
                    await model.install(databaseType)
                case .update(let databaseType):
                    await model.update(databaseType)
                case .uninstall(let databaseType):
                    await model.uninstall(databaseType)
                }
            } else {
                await model.refresh()
            }
            actionRequestID = nil
        }
        .confirmationDialog(
            copy.uninstallPluginTitle,
            isPresented: $isShowingUninstallConfirmation,
            presenting: uninstallCandidate
        ) { item in
            Button(copy.uninstallPlugin, role: .destructive) {
                uninstallCandidate = nil
                request(.uninstall(item.entry.databaseType))
            }
            Button(copy.cancel, role: .cancel) {
                uninstallCandidate = nil
            }
        } message: { item in
            Text(copy.uninstallPluginMessage(item.entry.displayName))
        }
        .alert(
            copy.pluginOperationFailed,
            isPresented: $model.isShowingError
        ) {
            Button(copy.ok, role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
    }

    private func request(_ action: PluginSettingsAction) {
        requestedAction = action
        actionRequestID = UUID()
    }
}
