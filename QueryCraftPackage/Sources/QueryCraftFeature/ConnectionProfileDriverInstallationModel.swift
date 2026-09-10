import Foundation
import Observation

@MainActor
@Observable
final class ConnectionProfileDriverInstallationModel {
    let profile: ConnectionProfile

    private(set) var catalogItem: DatabaseDriverCatalogItem?
    private(set) var errorMessage = ""
    private(set) var isLoading = true

    private let driverManager: DatabaseDriverManager

    init(
        profile: ConnectionProfile,
        driverManager: DatabaseDriverManager = .shared
    ) {
        self.profile = profile
        self.driverManager = driverManager
    }

    var installationState: DatabaseDriverInstallationState? {
        catalogItem?.installationState
    }

    var isBusy: Bool {
        isLoading || installationState?.isBusy == true
    }

    func prepare() async -> Bool {
        isLoading = true
        let items = await driverManager.refreshCatalog()
        guard !Task.isCancelled,
              let item = items.first(where: {
                  $0.entry.databaseType == profile.databaseType
              })
        else {
            isLoading = false
            return false
        }

        catalogItem = item
        if case .failed(let message) = item.installationState {
            errorMessage = message
        } else {
            errorMessage = item.availabilityErrorMessage ?? ""
        }
        isLoading = false

        if item.installationState.hasInstalledDriver {
            return true
        }
        if case .installing = item.installationState {
            return await install()
        }
        return false
    }

    func install() async -> Bool {
        errorMessage = ""
        do {
            try await driverManager.install(profile.databaseType) { state in
                await self.record(state)
            }
            try Task.checkCancellation()
            catalogItem = await driverManager.catalogItems().first(where: {
                $0.entry.databaseType == profile.databaseType
            })
            return catalogItem?.installationState.hasInstalledDriver == true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            record(.failed(message: error.localizedDescription))
            return false
        }
    }

    private func record(_ state: DatabaseDriverInstallationState) {
        guard let item = catalogItem else { return }
        catalogItem = DatabaseDriverCatalogItem(
            entry: item.entry,
            installationState: state,
            installedVersion: item.installedVersion,
            availableVersion: item.availableVersion,
            downloadSize: item.downloadSize,
            availabilityErrorMessage: item.availabilityErrorMessage
        )
        if case .failed(let message) = state {
            errorMessage = message
        }
    }
}
