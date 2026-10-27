import SwiftUI
import UniformTypeIdentifiers

struct PluginSettingsPane: View {
    @State private var model = PluginSettingsModel()
    @State private var sshModel = SSHPluginSettingsModel()
    @State private var requestedAction: PluginSettingsAction?
    @State private var actionRequestID: UUID?
    @State private var uninstallCandidate: DatabaseDriverCatalogItem?
    @State private var isShowingUninstallConfirmation = false
    @State private var removingSSH = false
    @State private var importingSSH = false

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

            Section(AppCopy.current.text("连接插件", "Connection plugins")) {
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
                if model.searchText.isEmpty || "SSH libssh2 服务器".localizedCaseInsensitiveContains(model.searchText) {
                    PluginSettingsRow(item: ConnectionPluginPresentation(sshModel),
                        install: { Task { await sshModel.install() } },
                        update: { Task { await sshModel.install() } },
                        uninstall: { removingSSH = true })
                    .contextMenu {
                        Button(AppCopy.current.text("选择本地安装包…", "Choose local package…")) { importingSSH = true }
                            .disabled(sshModel.busy)
                    }
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
        .task { await sshModel.refresh() }
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
                await sshModel.refresh()
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
        .fileImporter(isPresented: $importingSSH, allowedContentTypes: [.zip, .bundle, .directory]) { result in
            switch result {
            case .success(let source): Task { await sshModel.install(source: source) }
            case .failure(let error): sshModel.error = error.localizedDescription
            }
        }
        .confirmationDialog(copy.uninstallPluginTitle, isPresented: $removingSSH) {
            Button(copy.uninstallPlugin, role: .destructive) { Task { await sshModel.uninstall() } }
        } message: { Text(copy.uninstallPluginMessage("SSH")) }
    }

    private func request(_ action: PluginSettingsAction) {
        requestedAction = action
        actionRequestID = UUID()
    }
}
