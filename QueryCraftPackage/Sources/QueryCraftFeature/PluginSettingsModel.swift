import Foundation
import Observation

@MainActor
@Observable
final class PluginSettingsModel {
    private(set) var items: [DatabaseDriverCatalogItem] = []
    private(set) var isRefreshing = false
    private(set) var errorMessage = ""
    var isShowingError = false
    var searchText = ""

    private let driverManager: DatabaseDriverManager

    init(driverManager: DatabaseDriverManager = .shared) {
        self.driverManager = driverManager
    }

    var visibleItems: [DatabaseDriverCatalogItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { item in
            item.entry.displayName.localizedCaseInsensitiveContains(searchText)
                || item.entry.databaseType.tagline
                    .localizedCaseInsensitiveContains(searchText)
        }
    }

    func load() async {
        await driverManager.loadInstalledDrivers()
        items = await driverManager.catalogItems()
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        items = await driverManager.refreshCatalog()
    }

    func install(_ databaseType: DatabaseType) async {
        await perform {
            try await driverManager.install(databaseType) { state in
                await self.record(state, for: databaseType)
            }
        }
    }

    func update(_ databaseType: DatabaseType) async {
        await perform {
            try await driverManager.update(databaseType) { state in
                await self.record(state, for: databaseType)
            }
        }
    }

    func uninstall(_ databaseType: DatabaseType) async {
        await perform {
            try await driverManager.uninstall(databaseType)
        }
    }

    private func perform(
        _ operation: () async throws -> Void
    ) async {
        errorMessage = ""
        isShowingError = false
        do {
            try await operation()
            items = await driverManager.catalogItems()
        } catch is CancellationError {
            items = await driverManager.catalogItems()
        } catch {
            items = await driverManager.catalogItems()
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }

    private func record(
        _ state: DatabaseDriverInstallationState,
        for databaseType: DatabaseType
    ) {
        guard let index = items.firstIndex(where: {
            $0.entry.databaseType == databaseType
        }) else { return }
        let item = items[index]
        items[index] = DatabaseDriverCatalogItem(
            entry: item.entry,
            installationState: state,
            installedVersion: item.installedVersion,
            availableVersion: item.availableVersion,
            downloadSize: item.downloadSize,
            availabilityErrorMessage: item.availabilityErrorMessage
        )
    }
}
