import Foundation
import Observation

@MainActor
@Observable
final class NewConnectionFlowModel {
    enum Step: Equatable {
        case selectDatabase
        case configure(DatabaseProduct)
        case configureSSH
    }

    enum ConnectionChoice: Hashable { case database(DatabaseProduct), ssh }
    let allowsSSH: Bool
    var selectsSSH = false
    private(set) var catalogLoaded = false
    var selectedConnection: ConnectionChoice? {
        get { selectsSSH ? .ssh : selectedDatabaseProduct.map(ConnectionChoice.database) }
        set {
            switch newValue {
            case .ssh: selectsSSH = true
            case .database(let product): selectsSSH = false; selectedDatabaseProduct = product
            case nil: selectsSSH = false; selectedDatabaseProduct = nil
            }
        }
    }
    var matchesSSH: Bool { allowsSSH && (searchText.isEmpty || "SSH 服务器 Secure Shell".localizedCaseInsensitiveContains(searchText)) }
    func configureSSH() { step = .configureSSH }
    private(set) var step = Step.selectDatabase
    private(set) var catalogItems: [DatabaseDriverCatalogItem] = []
    private(set) var installationErrorMessage = ""
    var isShowingInstallationError = false
    var selectedDatabaseProduct: DatabaseProduct?
    var searchText = ""

    let sshPlugin: SSHPluginSettingsModel
    private let driverManager: DatabaseDriverManager

    init(driverManager: DatabaseDriverManager = .shared, allowsSSH: Bool = true, sshPlugin: SSHPluginSettingsModel = SSHPluginSettingsModel()) {
        self.sshPlugin = sshPlugin
        self.allowsSSH = allowsSSH
        self.driverManager = driverManager
    }

    var productItems: [DatabaseProductCatalogItem] {
        DatabaseProductCatalog.items(from: catalogItems)
    }

    var visibleItems: [DatabaseProductCatalogItem] {
        guard !searchText.isEmpty else { return productItems }
        return productItems.filter { item in
            item.entry.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var selectedItem: DatabaseProductCatalogItem? {
        guard !selectsSSH, let selectedDatabaseProduct else { return nil }
        return productItems.first {
            $0.entry.databaseProduct == selectedDatabaseProduct
        }
    }

    var selectedDatabaseType: DatabaseType? {
        get { selectedDatabaseProduct?.databaseType }
        set {
            selectedDatabaseProduct = newValue.map {
                DatabaseProduct.defaultProduct(for: $0)
            }
        }
    }

    var selectedPlugin: ConnectionPluginPresentation? {
        selectsSSH ? ConnectionPluginPresentation(sshPlugin) : selectedItem.map { ConnectionPluginPresentation($0.driverItem) }
    }
    var isInstalling: Bool { selectedPlugin?.installationState.isBusy == true }

    func loadCatalog() async {
        catalogItems = await driverManager.catalogItems()
        if allowsSSH { await sshPlugin.refresh() }
        catalogLoaded = true
        if selectedDatabaseProduct == nil {
            selectedDatabaseProduct = productItems.first?.entry.databaseProduct
        }
        await observeInFlightInstallations()
    }

    func continueWithSelection() async {
        if selectsSSH {
            guard allowsSSH, !sshPlugin.busy else { return }
            if sshPlugin.installed == nil { await sshPlugin.install() }
            if let error = sshPlugin.error { installationErrorMessage = error; isShowingInstallationError = true; return }
            guard !Task.isCancelled, selectsSSH, sshPlugin.installed != nil else { return }
            configureSSH(); return
        }
        guard let selectedItem else { return }
        installationErrorMessage = ""
        isShowingInstallationError = false
        switch selectedItem.installationState {
        case .installed, .updateAvailable, .updateReady, .updating:
            step = .configure(selectedItem.entry.databaseProduct)
        case .notInstalled, .failed:
            do {
                try await driverManager.install(
                    selectedItem.entry.databaseType
                ) { state in
                    await self.recordInstallationState(
                        state,
                        for: selectedItem.entry.databaseType
                    )
                }
                try Task.checkCancellation()
                await loadCatalog()
                guard !selectsSSH, selectedDatabaseProduct == selectedItem.entry.databaseProduct else { return }
                step = .configure(selectedItem.entry.databaseProduct)
            } catch is CancellationError {
                await loadCatalog()
            } catch {
                await loadCatalog()
                installationErrorMessage = error.localizedDescription
                isShowingInstallationError = true
            }
        case .installing:
            break
        case .uninstalling:
            break
        }
    }

    func uninstallSelection() async {
        if selectsSSH {
            await sshPlugin.uninstall()
            if let error = sshPlugin.error { installationErrorMessage = error; isShowingInstallationError = true }
            return
        }
        guard let selectedItem,
              selectedItem.installationState.hasInstalledDriver,
              !selectedItem.installationState.isBusy
        else {
            return
        }
        installationErrorMessage = ""
        isShowingInstallationError = false
        recordInstallationState(
            .uninstalling,
            for: selectedItem.entry.databaseType
        )
        do {
            try await driverManager.uninstall(
                selectedItem.entry.databaseType
            )
            await loadCatalog()
        } catch is CancellationError {
            await loadCatalog()
        } catch {
            await loadCatalog()
            installationErrorMessage = error.localizedDescription
            isShowingInstallationError = true
        }
    }

    func returnToDatabaseSelection() {
        installationErrorMessage = ""
        isShowingInstallationError = false
        step = .selectDatabase
    }

    private func recordInstallationState(
        _ state: DatabaseDriverInstallationState,
        for databaseType: DatabaseType
    ) {
        guard let index = catalogItems.firstIndex(where: {
            $0.entry.databaseType == databaseType
        }) else { return }
        catalogItems[index] = DatabaseDriverCatalogItem(
            entry: catalogItems[index].entry,
            installationState: state,
            installedVersion: catalogItems[index].installedVersion,
            availableVersion: catalogItems[index].availableVersion,
            downloadSize: catalogItems[index].downloadSize,
            availabilityErrorMessage:
                catalogItems[index].availabilityErrorMessage
        )
    }

    private func observeInFlightInstallations() async {
        let databaseTypes: [DatabaseType] = catalogItems.compactMap { item in
            switch item.installationState {
            case .installing:
                item.entry.databaseType
            default:
                nil
            }
        }
        guard !databaseTypes.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for databaseType in databaseTypes {
                group.addTask { [driverManager] in
                    do {
                        try await driverManager.install(databaseType) { state in
                            await self.recordInstallationState(
                                state,
                                for: databaseType
                            )
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        await self.recordInstallationFailure(
                            error,
                            for: databaseType
                        )
                    }
                }
            }
            await group.waitForAll()
        }
        guard !Task.isCancelled else { return }
        catalogItems = await driverManager.catalogItems()
    }

    private func recordInstallationFailure(
        _ error: any Error,
        for databaseType: DatabaseType
    ) {
        installationErrorMessage = error.localizedDescription
        isShowingInstallationError = true
        recordInstallationState(
            .failed(message: error.localizedDescription),
            for: databaseType
        )
    }
}
