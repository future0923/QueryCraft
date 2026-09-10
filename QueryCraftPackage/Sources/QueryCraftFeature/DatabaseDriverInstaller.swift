import Foundation

protocol DatabaseDriverInstaller: Sendable {
    func loadInstalledDrivers() async -> [any DatabaseDriver]

    func installedRelease(
        for databaseType: DatabaseType
    ) async -> DatabaseDriverReleaseIdentity?

    func pendingUpdateRelease(
        for databaseType: DatabaseType
    ) async -> DatabaseDriverReleaseIdentity?

    func uninstall(_ databaseType: DatabaseType) async throws

    func resolvePackages(
        for entry: DatabaseDriverCatalogEntry
    ) async throws -> [DatabaseDriverPackage]

    func install(
        _ package: DatabaseDriverPackage,
        onProgress: @escaping @Sendable (
            DatabaseDriverInstallationProgress
        ) async -> Void
    ) async throws -> any DatabaseDriver

    func stageUpdate(
        _ package: DatabaseDriverPackage,
        onProgress: @escaping @Sendable (
            DatabaseDriverInstallationProgress
        ) async -> Void
    ) async throws
}

extension DatabaseDriverInstaller {
    func loadInstalledDrivers() async -> [any DatabaseDriver] { [] }
    func installedRelease(
        for databaseType: DatabaseType
    ) async -> DatabaseDriverReleaseIdentity? { nil }
    func pendingUpdateRelease(
        for databaseType: DatabaseType
    ) async -> DatabaseDriverReleaseIdentity? { nil }
}

actor DatabaseDriverManager {
    static let shared = DatabaseDriverManager(
        installer: DatabaseDriverPackageInstaller()
    )

    private struct InFlightInstallation: Sendable {
        let id: UUID
        let task: Task<Void, any Error>
    }

    private let registry: DatabaseDriverRegistry
    private let installer: (any DatabaseDriverInstaller)?
    private let compatibilityValidator: DatabaseDriverCompatibilityValidator
    private var installationStates: [
        DatabaseType: DatabaseDriverInstallationState
    ] = [:]
    private var inFlightInstallations: [
        DatabaseType: InFlightInstallation
    ] = [:]
    private var uninstallingDatabaseTypes: Set<DatabaseType> = []
    private var updatingDatabaseTypes: Set<DatabaseType> = []
    private var availablePackages: [DatabaseType: DatabaseDriverPackage] = [:]
    private var availabilityErrors: [DatabaseType: String] = [:]
    private var didLoadInstalledDrivers = false
    private var installedDriverLoadingTask: Task<Void, Never>?
    private var stateObservers: [
        DatabaseType: [
            UUID: @Sendable (DatabaseDriverInstallationState) async -> Void
        ]
    ] = [:]

    init(
        registry: DatabaseDriverRegistry = .shared,
        installer: (any DatabaseDriverInstaller)? = nil,
        compatibilityValidator: DatabaseDriverCompatibilityValidator = .init()
    ) {
        self.registry = registry
        self.installer = installer
        self.compatibilityValidator = compatibilityValidator
    }

    func isInstalled(_ databaseType: DatabaseType) async -> Bool {
        await registry.isInstalled(databaseType)
    }

    func catalogItems() async -> [DatabaseDriverCatalogItem] {
        var installedReleases: [DatabaseType: DatabaseDriverReleaseIdentity] = [:]
        var pendingReleases: [DatabaseType: DatabaseDriverReleaseIdentity] = [:]
        for entry in DatabaseDriverCatalog.entries {
            let databaseType = entry.databaseType
            installedReleases[databaseType] = await installer?.installedRelease(
                for: databaseType
            )
            pendingReleases[databaseType] = await installer?.pendingUpdateRelease(
                for: databaseType
            )
        }

        // Read the authoritative registry last so an installation that finishes
        // while metadata is loading cannot be reported as not installed.
        let installed = await registry.installedDatabaseTypes()
        return DatabaseDriverCatalog.entries.map { entry in
            let databaseType = entry.databaseType
            let installedRelease = installedReleases[databaseType]
            let pendingRelease = pendingReleases[databaseType]
            let package = availablePackages[databaseType]
            let state = resolvedState(
                for: databaseType,
                isInstalled: installed.contains(databaseType),
                installedRelease: installedRelease,
                pendingRelease: pendingRelease,
                availableRelease: package?.release
            )
            return DatabaseDriverCatalogItem(
                entry: entry,
                installationState: state,
                installedVersion: installedRelease?.version,
                availableVersion: package?.version,
                downloadSize: package?.downloadSize,
                availabilityErrorMessage: availabilityErrors[databaseType]
            )
        }
    }

    func loadInstalledDrivers() async {
        guard !didLoadInstalledDrivers else { return }
        if let installedDriverLoadingTask {
            await installedDriverLoadingTask.value
            return
        }
        guard let installer else {
            didLoadInstalledDrivers = true
            return
        }

        let registry = registry
        let task = Task {
            for driver in await installer.loadInstalledDrivers() {
                await registry.register(driver)
            }
        }
        installedDriverLoadingTask = task
        await task.value
        installedDriverLoadingTask = nil
        didLoadInstalledDrivers = true
    }

    @discardableResult
    func refreshCatalog() async -> [DatabaseDriverCatalogItem] {
        guard let installer else { return await catalogItems() }
        for entry in DatabaseDriverCatalog.entries where entry.isDownloadable {
            do {
                try Task.checkCancellation()
                let packages = try await installer.resolvePackages(for: entry)
                let package = try compatibilityValidator.latestCompatiblePackage(
                    in: packages
                )
                availablePackages[entry.databaseType] = package
                availabilityErrors[entry.databaseType] = nil
            } catch is CancellationError {
                return await catalogItems()
            } catch {
                availablePackages[entry.databaseType] = nil
                availabilityErrors[entry.databaseType] = error.localizedDescription
            }
        }
        return await catalogItems()
    }

    func install(
        _ databaseType: DatabaseType,
        onStateChange: @escaping @Sendable (
            DatabaseDriverInstallationState
        ) async -> Void = { _ in }
    ) async throws {
        guard !uninstallingDatabaseTypes.contains(databaseType),
              !updatingDatabaseTypes.contains(databaseType)
        else {
            throw DatabaseDriverInstallError.driverBusy(databaseType)
        }
        guard let entry = DatabaseDriverCatalog.entry(for: databaseType),
              entry.isDownloadable else {
            throw DatabaseDriverInstallError.downloadSourceUnavailable(
                databaseType
            )
        }
        if await registry.isInstalled(databaseType) {
            installationStates[databaseType] = .installed
            await onStateChange(.installed)
            return
        }
        guard let installer else {
            throw DatabaseDriverInstallError.downloadSourceUnavailable(
                databaseType
            )
        }

        let observerID = UUID()
        stateObservers[databaseType, default: [:]][observerID] = onStateChange

        let installation: InFlightInstallation
        if let existing = inFlightInstallations[databaseType] {
            installation = existing
            if let currentState = installationStates[databaseType] {
                await onStateChange(currentState)
            }
        } else {
            let installationID = UUID()
            let progress = DatabaseDriverInstallationProgress(
                phase: .checkingCompatibility
            )
            installationStates[databaseType] = .installing(progress)
            let task = Task { [self] in
                try await self.performInstallation(
                    entry: entry,
                    databaseType: databaseType,
                    installer: installer,
                    installationID: installationID
                )
            }
            installation = InFlightInstallation(
                id: installationID,
                task: task
            )
            inFlightInstallations[databaseType] = installation
            await notifyObservers(
                .installing(progress),
                for: databaseType
            )
        }

        do {
            try await withTaskCancellationHandler {
                try await installation.task.value
                removeObserver(observerID, for: databaseType)
                try Task.checkCancellation()
            } onCancel: {
                Task {
                    await self.removeObserver(observerID, for: databaseType)
                }
            }
        } catch {
            removeObserver(observerID, for: databaseType)
            throw error
        }
    }

    func uninstall(_ databaseType: DatabaseType) async throws {
        guard inFlightInstallations[databaseType] == nil,
              !updatingDatabaseTypes.contains(databaseType),
              !uninstallingDatabaseTypes.contains(databaseType)
        else {
            throw DatabaseDriverInstallError.driverBusy(databaseType)
        }
        guard let installer else {
            throw DatabaseDriverInstallError.uninstallFailed(
                databaseType,
                detail: AppCopy.current.text(
                    "驱动管理器不可用。",
                    "The driver manager is unavailable."
                )
            )
        }

        uninstallingDatabaseTypes.insert(databaseType)
        defer { uninstallingDatabaseTypes.remove(databaseType) }
        let wasInstalled = await registry.isInstalled(databaseType)
        await setState(.uninstalling, for: databaseType)
        do {
            try await installer.uninstall(databaseType)
            await registry.unregister(databaseType)
            await setState(.notInstalled, for: databaseType)
        } catch {
            await setState(
                wasInstalled ? .installed : .notInstalled,
                for: databaseType
            )
            throw error
        }
    }

    func update(
        _ databaseType: DatabaseType,
        onStateChange: @escaping @Sendable (
            DatabaseDriverInstallationState
        ) async -> Void = { _ in }
    ) async throws {
        guard inFlightInstallations[databaseType] == nil,
              !uninstallingDatabaseTypes.contains(databaseType),
              !updatingDatabaseTypes.contains(databaseType)
        else {
            throw DatabaseDriverInstallError.driverBusy(databaseType)
        }
        guard await registry.isInstalled(databaseType),
              let installer,
              let entry = DatabaseDriverCatalog.entry(for: databaseType)
        else {
            throw DatabaseDriverError.notInstalled(databaseType)
        }

        updatingDatabaseTypes.insert(databaseType)
        defer { updatingDatabaseTypes.remove(databaseType) }
        do {
            let package: DatabaseDriverPackage
            if let available = availablePackages[databaseType] {
                package = available
            } else {
                let packages = try await installer.resolvePackages(for: entry)
                package = try compatibilityValidator.latestCompatiblePackage(
                    in: packages
                )
                availablePackages[databaseType] = package
            }
            try compatibilityValidator.validate(package)
            guard let installedRelease = await installer.installedRelease(
                for: databaseType
            ), package.release.isNewer(than: installedRelease) else {
                await setState(.installed, for: databaseType)
                await onStateChange(.installed)
                return
            }
            let progress = DatabaseDriverInstallationProgress(
                phase: .checkingCompatibility
            )
            await setState(.updating(progress), for: databaseType)
            await onStateChange(.updating(progress))
            try await installer.stageUpdate(package) { progress in
                let state = DatabaseDriverInstallationState.updating(progress)
                await self.setState(state, for: databaseType)
                await onStateChange(state)
            }
            await setState(.updateReady, for: databaseType)
            await onStateChange(.updateReady)
        } catch is CancellationError {
            await setState(.updateAvailable, for: databaseType)
            throw CancellationError()
        } catch {
            await setState(.updateAvailable, for: databaseType)
            throw error
        }
    }

    private func performInstallation(
        entry: DatabaseDriverCatalogEntry,
        databaseType: DatabaseType,
        installer: any DatabaseDriverInstaller,
        installationID: UUID
    ) async throws {
        do {
            let packages = try await installer.resolvePackages(for: entry)
            let package = try compatibilityValidator.latestCompatiblePackage(
                in: packages
            )
            availablePackages[databaseType] = package
            try compatibilityValidator.validate(package)
            guard package.databaseType == databaseType else {
                throw DatabaseDriverError.configurationTypeMismatch(
                    expected: databaseType,
                    actual: package.databaseType
                )
            }
            let driver = try await installer.install(package) { progress in
                await self.setState(
                    .installing(progress),
                    for: databaseType
                )
            }
            guard driver.databaseType == databaseType else {
                throw DatabaseDriverError.configurationTypeMismatch(
                    expected: databaseType,
                    actual: driver.databaseType
                )
            }
            await registry.register(driver)
            clearInstallation(databaseType, id: installationID)
            await setState(.installed, for: databaseType)
        } catch is CancellationError {
            clearInstallation(databaseType, id: installationID)
            await setState(.notInstalled, for: databaseType)
            throw CancellationError()
        } catch {
            clearInstallation(databaseType, id: installationID)
            await setState(
                .failed(message: error.localizedDescription),
                for: databaseType
            )
            throw error
        }
    }

    private func clearInstallation(
        _ databaseType: DatabaseType,
        id: UUID
    ) {
        guard inFlightInstallations[databaseType]?.id == id else { return }
        inFlightInstallations[databaseType] = nil
    }

    private func setState(
        _ state: DatabaseDriverInstallationState,
        for databaseType: DatabaseType
    ) async {
        installationStates[databaseType] = state
        await notifyObservers(state, for: databaseType)
    }

    private func notifyObservers(
        _ state: DatabaseDriverInstallationState,
        for databaseType: DatabaseType
    ) async {
        guard let registeredObservers = stateObservers[databaseType] else {
            return
        }
        let observers = Array(registeredObservers.values)
        for observer in observers {
            await observer(state)
        }
    }

    private func removeObserver(
        _ observerID: UUID,
        for databaseType: DatabaseType
    ) {
        stateObservers[databaseType]?[observerID] = nil
        if stateObservers[databaseType]?.isEmpty == true {
            stateObservers[databaseType] = nil
        }
    }

    private func resolvedState(
        for databaseType: DatabaseType,
        isInstalled: Bool,
        installedRelease: DatabaseDriverReleaseIdentity?,
        pendingRelease: DatabaseDriverReleaseIdentity?,
        availableRelease: DatabaseDriverReleaseIdentity?
    ) -> DatabaseDriverInstallationState {
        if let state = installationStates[databaseType] {
            switch state {
            case .installing, .updating, .uninstalling, .failed, .updateReady:
                return state
            case .notInstalled, .installed, .updateAvailable:
                break
            }
        }
        guard isInstalled else { return .notInstalled }
        if pendingRelease != nil { return .updateReady }
        if let installedRelease,
           let availableRelease,
           availableRelease.isNewer(than: installedRelease),
           availabilityErrors[databaseType] == nil
        {
            return .updateAvailable
        }
        return .installed
    }

}
