import Foundation
import Testing
@testable import QueryCraftFeature

struct DatabaseDriverRegistryTests {
    @Test func legacySessionsKeepDefaultCapabilitiesWithoutABIRequirement() {
        let session: any WorkspaceSession = InMemoryWorkspaceSession(databases: [])

        #expect(session.resolvedCapabilities == .standard)
    }

    @Test func driverDownloadsBypassURLCache() throws {
        let url = try #require(URL(string: "https://example.com/driver.zip"))

        let request = DatabaseDriverPackageInstaller.uncachedRequest(for: url)

        #expect(request.url == url)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    }

    @Test func adHocReleaseAcceptsOnlyAdHocDriverIdentity() {
        #expect(
            DatabaseDriverPackageInstaller.signatureMatchesHost(
                hostTeamIdentifier: nil,
                driverTeamIdentifier: nil,
                driverIsAdHoc: true
            )
        )
        #expect(
            !DatabaseDriverPackageInstaller.signatureMatchesHost(
                hostTeamIdentifier: nil,
                driverTeamIdentifier: "EXAMPLETEAM",
                driverIsAdHoc: false
            )
        )
        #expect(
            !DatabaseDriverPackageInstaller.signatureMatchesHost(
                hostTeamIdentifier: nil,
                driverTeamIdentifier: nil,
                driverIsAdHoc: false
            )
        )
    }

    @Test func teamSignedReleaseAcceptsOnlyMatchingDriverTeam() {
        #expect(
            DatabaseDriverPackageInstaller.signatureMatchesHost(
                hostTeamIdentifier: "EXAMPLETEAM",
                driverTeamIdentifier: "EXAMPLETEAM",
                driverIsAdHoc: false
            )
        )
        #expect(
            !DatabaseDriverPackageInstaller.signatureMatchesHost(
                hostTeamIdentifier: "EXAMPLETEAM",
                driverTeamIdentifier: "OTHERTEAM",
                driverIsAdHoc: false
            )
        )
        #expect(
            !DatabaseDriverPackageInstaller.signatureMatchesHost(
                hostTeamIdentifier: "EXAMPLETEAM",
                driverTeamIdentifier: nil,
                driverIsAdHoc: true
            )
        )
    }

    @Test func downloadProgressCarriesSizeAndTransferRate() {
        let progress = DatabaseDriverInstallationProgress(
            phase: .downloading,
            fractionCompleted: 0.5,
            receivedBytes: 512_000,
            totalBytes: 1_024_000,
            bytesPerSecond: 256_000
        )

        #expect(progress.receivedBytes == 512_000)
        #expect(progress.totalBytes == 1_024_000)
        #expect(progress.bytesPerSecond == 256_000)
        #expect(progress.downloadDetail?.contains("/") == true)
        #expect(progress.downloadDetail?.contains("/s") == true)
    }

    @Test func downloadProgressRejectsInvalidTransferValues() {
        let progress = DatabaseDriverInstallationProgress(
            phase: .downloading,
            receivedBytes: -1,
            totalBytes: 0,
            bytesPerSecond: .infinity
        )

        #expect(progress.receivedBytes == 0)
        #expect(progress.totalBytes == nil)
        #expect(progress.bytesPerSecond == nil)
    }

    @Test func installsAndActivatesRealDownloadedMySQLDriver() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[
            "QUERYCRAFT_RUN_DRIVER_INSTALLATION_TEST"
        ] == "1" else {
            return
        }
        guard let password = environment["QUERYCRAFT_MYSQL56_PASSWORD"],
              !password.isEmpty
        else {
            return
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            // Downloaded driver bundles link against QueryCraftFeature.framework
            // from the app bundle. SwiftPM tests load QueryCraftFeature through
            // the package test host instead, which creates a different protocol
            // type identity for bundle activation. Run this activation path from
            // the signed QueryCraft.app host; SwiftPM covers catalog/download
            // management separately.
            return
        }
        let registry = DatabaseDriverRegistry.shared
        await registry.unregister(.mysql)
        let installDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: "QueryCraftDriverInstallTest-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: installDirectory) }

        let installer = DatabaseDriverPackageInstaller(
            registry: registry,
            driversDirectory: installDirectory
        )
        let entry = try #require(
            DatabaseDriverCatalog.entry(for: .mysql)
        )
        let packages = try await installer.resolvePackages(for: entry)
        let package = try DatabaseDriverCompatibilityValidator()
            .latestCompatiblePackage(in: packages)
        let driver = try await installer.install(package) { _ in }

        #expect(driver.databaseType == .mysql)
        #expect(await registry.isInstalled(.mysql))
        let session = try await driver.makeSession(
            configuration: DatabaseConnectionConfiguration(
                databaseType: .mysql,
                host: environment["QUERYCRAFT_MYSQL56_HOST"] ?? "127.0.0.1",
                port: Int(environment["QUERYCRAFT_MYSQL56_PORT"] ?? "3356")
                    ?? 3_356,
                username: environment["QUERYCRAFT_MYSQL56_USER"] ?? "root",
                password: password,
                database: environment["QUERYCRAFT_MYSQL56_DATABASE"]
                    ?? "querycraft_driver_test",
                tlsMode: .disabled
            )
        )
        try await session.connect()
        #expect(await session.isConnected())
        #expect(
            try await session.fetchDatabases()
                .contains(
                    environment["QUERYCRAFT_MYSQL56_DATABASE"]
                        ?? "querycraft_driver_test"
                )
        )
        await session.close()

        await registry.unregister(.mysql)
        let restoredDrivers = await installer.loadInstalledDrivers()
        #expect(restoredDrivers.map(\.databaseType) == [.mysql])
        #expect(await registry.isInstalled(.mysql))
        await registry.unregister(.mysql)
    }

    @Test func packageInstallerRemovesInstalledDriverBundle() async throws {
        let driversDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: "QueryCraftDriverUninstallTest-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let bundleURL = driversDirectory.appending(
            path: "MySQL.querycraftdriver",
            directoryHint: .isDirectory
        )
        let contentsURL = bundleURL.appending(
            path: "Contents",
            directoryHint: .isDirectory
        )
        let executableURL = contentsURL
            .appending(path: "MacOS", directoryHint: .isDirectory)
            .appending(path: "TestDriver")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executableURL)
        let info: [String: Any] = [
            "CFBundleIdentifier": "io.github.future0923.QueryCraft.Driver.UninstallTest",
            "CFBundleExecutable": "TestDriver",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "MySQL Driver Uninstall Test",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "QCDriverDatabaseType": "mysql",
            "QCDriverAPIVersion": 2,
            "QCMinimumAppVersion": "0.1.1",
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contentsURL.appending(path: "Info.plist"))
        defer { try? FileManager.default.removeItem(at: driversDirectory) }

        let installer = DatabaseDriverPackageInstaller(
            driversDirectory: driversDirectory
        )
        try await installer.uninstall(.mysql)

        #expect(!FileManager.default.fileExists(atPath: bundleURL.path))
    }

    @Test func packageInstallerReadsReplacedDriverMetadataFromDisk() async throws {
        let driversDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: "QueryCraftDriverMetadataTest-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let bundleURL = driversDirectory.appending(
            path: "MySQL.querycraftdriver",
            directoryHint: .isDirectory
        )
        let contentsURL = bundleURL.appending(
            path: "Contents",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: driversDirectory) }

        func writeMetadata(build: String) throws {
            let info: [String: Any] = [
                "CFBundleIdentifier": "io.github.future0923.QueryCraft.Driver.MetadataTest",
                "CFBundleShortVersionString": "1.0.2",
                "CFBundleVersion": build,
                "NSPrincipalClass": "TestDriverEntry",
                "QCDriverDatabaseType": "mysql",
                "QCDriverAPIVersion": 2,
                "QCMinimumAppVersion": "0.1.2",
            ]
            let plist = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try plist.write(
                to: contentsURL.appending(path: "Info.plist"),
                options: .atomic
            )
        }

        try writeMetadata(build: "3")
        #expect(
            try DatabaseDriverPackageInstaller.releaseIdentity(at: bundleURL)
                .build == "3"
        )

        try writeMetadata(build: "2")
        #expect(
            try DatabaseDriverPackageInstaller.releaseIdentity(at: bundleURL)
                .build == "2"
        )
    }

    @Test func packageInstallerRejectsIncompatibleInstalledDriverBeforeActivation() throws {
        let driversDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: "QueryCraftIncompatibleDriverTest-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let bundleURL = driversDirectory.appending(
            path: "PostgreSQL.querycraftdriver",
            directoryHint: .isDirectory
        )
        let contentsURL = bundleURL.appending(
            path: "Contents",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: driversDirectory) }

        let info: [String: Any] = [
            "CFBundleIdentifier": "io.github.future0923.QueryCraft.Driver.PostgreSQL",
            "CFBundleShortVersionString": "1.0.1",
            "CFBundleVersion": "2",
            "NSPrincipalClass": "QueryCraftPostgreSQLDriverEntry",
            "QCDriverDatabaseType": "postgresql",
            "QCDriverAPIVersion": 1,
            "QCMinimumAppVersion": "0.1.1",
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contentsURL.appending(path: "Info.plist"))
        let validator = DatabaseDriverCompatibilityValidator(
            appVersion: "0.1.4",
            driverAPIVersion: 2,
            architecture: .arm64
        )

        #expect(throws: DatabaseDriverInstallError.incompatibleDriverAPI) {
            _ = try DatabaseDriverPackageInstaller.validatedInstalledDriverMetadata(
                at: bundleURL,
                compatibilityValidator: validator
            )
        }
    }

    @Test func routesConfigurationToMatchingDriver() async throws {
        let mysql = RecordingDatabaseDriver(databaseType: .mysql)
        let postgresql = RecordingDatabaseDriver(databaseType: .postgresql)
        let registry = DatabaseDriverRegistry(drivers: [mysql, postgresql])
        let configuration = DatabaseConnectionConfiguration(
            databaseType: .postgresql,
            host: "localhost",
            port: 5_432,
            username: "postgres",
            password: nil,
            database: "querycraft",
            tlsMode: .verifyIdentity
        )

        let session = try await registry.makeSession(
            configuration: configuration
        )
        try await session.connect()

        #expect(await mysql.receivedConfigurations().isEmpty)
        #expect(await postgresql.receivedConfigurations() == [configuration])
    }

    @Test func reportsUninstalledDriverWithoutFallingBackToMySQL() async {
        let mysql = RecordingDatabaseDriver(databaseType: .mysql)
        let registry = DatabaseDriverRegistry(drivers: [mysql])
        let configuration = DatabaseConnectionConfiguration(
            databaseType: .postgresql,
            host: "localhost",
            port: 5_432,
            username: "postgres",
            password: nil,
            database: nil,
            tlsMode: .verifyIdentity
        )

        await #expect(throws: DatabaseDriverError.notInstalled(.postgresql)) {
            _ = try await registry.makeSession(configuration: configuration)
        }
        #expect(await mysql.receivedConfigurations().isEmpty)
    }

    @Test func catalogListsEveryDownloadableDriverFamily() {
        #expect(
            DatabaseDriverCatalog.entries.map(\.databaseType)
                == [.mysql, .postgresql, .doris, .redis, .elasticsearch]
        )
        #expect(
            DatabaseDriverCatalog.entries.allSatisfy { entry in
                entry.isDownloadable
            }
        )
        #expect(
            DatabaseDriverCatalog.entry(for: .elasticsearch)?.category
                == .document
        )
    }

    @Test func catalogUsesEnvironmentBaseURLWhenProvided() async throws {
        guard ProcessInfo.processInfo.environment[
            "QUERYCRAFT_DRIVER_CATALOG_BASE_URL"
        ] != nil else {
            return
        }
        let entry = try #require(DatabaseDriverCatalog.entry(for: .mysql))
        #expect(
            entry.manifestURL?.absoluteString.hasSuffix(
                "/mysql-\(DatabaseDriverArchitecture.current.rawValue).json"
            ) == true
        )
        #expect(
            DatabaseDriverCatalog.manifestURL(
                for: .mysql,
                architecture: .x86_64
            )?.absoluteString.hasSuffix("/mysql-x86_64.json") == true
        )
        #expect(
            DatabaseDriverCatalog.manifestURL(
                for: .postgresql,
                architecture: .arm64
            )?.absoluteString.hasSuffix("/postgresql-arm64.json") == true
        )

        let installer = DatabaseDriverPackageInstaller()
        let packages = try await installer.resolvePackages(for: entry)
        let package = try DatabaseDriverCompatibilityValidator()
            .latestCompatiblePackage(in: packages)

        #expect(package.databaseType == .mysql)
        #expect(package.downloadURL.absoluteString.contains("/drivers/"))
    }

    @Test func managerReportsInstalledAndUninstalledCatalogItems() async {
        let registry = DatabaseDriverRegistry(
            drivers: [RecordingDatabaseDriver(databaseType: .mysql)]
        )
        let manager = DatabaseDriverManager(registry: registry)

        let states = Dictionary(
            uniqueKeysWithValues: await manager.catalogItems().map {
                ($0.entry.databaseType, $0.installationState)
            }
        )

        #expect(states[.mysql] == .installed)
        #expect(states[.postgresql] == .notInstalled)
        #expect(await manager.isInstalled(.mysql))
        #expect(!(await manager.isInstalled(.postgresql)))
    }

    @MainActor
    @Test func savedProfileDriverFlowContinuesForInstalledDriver() async {
        let manager = DatabaseDriverManager(
            registry: DatabaseDriverRegistry(
                drivers: [RecordingDatabaseDriver(databaseType: .postgresql)]
            )
        )
        let model = ConnectionProfileDriverInstallationModel(
            profile: savedProfile(databaseType: .postgresql),
            driverManager: manager
        )

        #expect(await model.prepare())
        #expect(model.installationState == .installed)
        #expect(model.errorMessage.isEmpty)
    }

    @MainActor
    @Test func savedProfileDriverFlowInstallsBeforeContinuing() async {
        let installer = ControlledDatabaseDriverInstaller()
        let manager = DatabaseDriverManager(
            registry: DatabaseDriverRegistry(),
            installer: installer,
            compatibilityValidator: DatabaseDriverCompatibilityValidator(
                appVersion: "1.0.0"
            )
        )
        let model = ConnectionProfileDriverInstallationModel(
            profile: savedProfile(databaseType: .postgresql),
            driverManager: manager
        )

        #expect(!(await model.prepare()))
        #expect(model.installationState == .notInstalled)

        let installation = Task { @MainActor in
            await model.install()
        }
        await installer.waitUntilStarted()
        #expect(model.installationState?.isBusy == true)
        await installer.finishInstallation()

        #expect(await installation.value)
        #expect(model.installationState == .installed)
        #expect(await manager.isInstalled(.postgresql))
    }

    @MainActor
    @Test func savedProfileDriverFlowKeepsFailureVisible() async {
        let installer = ControlledDatabaseDriverInstaller(
            minimumAppVersion: "99.0.0"
        )
        let model = ConnectionProfileDriverInstallationModel(
            profile: savedProfile(databaseType: .postgresql),
            driverManager: DatabaseDriverManager(
                registry: DatabaseDriverRegistry(),
                installer: installer,
                compatibilityValidator: DatabaseDriverCompatibilityValidator(
                    appVersion: "1.0.0"
                )
            )
        )

        #expect(!(await model.prepare()))
        #expect(!(await model.install()))
        #expect(!model.errorMessage.isEmpty)
        guard case .failed = model.installationState else {
            Issue.record("Expected the failed installation state")
            return
        }
    }

    @Test func managerDetectsAndStagesCompatibleDriverUpdate() async throws {
        let registry = DatabaseDriverRegistry(
            drivers: [RecordingDatabaseDriver(databaseType: .mysql)]
        )
        let installer = ControlledDatabaseDriverInstaller(
            packageVersion: "1.1.0",
            installedVersions: [.mysql: "1.0.0"]
        )
        let manager = DatabaseDriverManager(
            registry: registry,
            installer: installer,
            compatibilityValidator: DatabaseDriverCompatibilityValidator(
                appVersion: "1.0.0"
            )
        )

        let refreshed = await manager.refreshCatalog()
        #expect(
            refreshed.first { $0.entry.databaseType == .mysql }?
                .installationState == .updateAvailable
        )

        try await manager.update(.mysql)

        #expect(await installer.stagedDatabaseTypes() == [.mysql])
        let updated = await manager.catalogItems().first {
            $0.entry.databaseType == .mysql
        }
        #expect(updated?.installationState == .updateReady)
        #expect(updated?.installedVersion == "1.0.0")
        #expect(updated?.availableVersion == "1.1.0")
    }

    @Test func managerDetectsHigherBuildOfSameDriverVersion() async throws {
        let installer = ControlledDatabaseDriverInstaller(
            packageVersion: "1.0.2",
            packageBuild: "3",
            installedVersions: [.mysql: "1.0.2"],
            installedBuilds: [.mysql: "2"]
        )
        let manager = DatabaseDriverManager(
            registry: DatabaseDriverRegistry(
                drivers: [RecordingDatabaseDriver(databaseType: .mysql)]
            ),
            installer: installer,
            compatibilityValidator: DatabaseDriverCompatibilityValidator(
                appVersion: "1.0.0"
            )
        )

        let refreshed = await manager.refreshCatalog()

        #expect(
            refreshed.first { $0.entry.databaseType == .mysql }?
                .installationState == .updateAvailable
        )
    }

    @Test func managerUninstallsDriverAndUnregistersIt() async throws {
        let registry = DatabaseDriverRegistry(
            drivers: [RecordingDatabaseDriver(databaseType: .mysql)]
        )
        let installer = ControlledDatabaseDriverInstaller()
        let manager = DatabaseDriverManager(
            registry: registry,
            installer: installer
        )

        try await manager.uninstall(.mysql)

        #expect(await installer.uninstalledDatabaseTypes() == [.mysql])
        #expect(!(await registry.isInstalled(.mysql)))
        let state = await manager.catalogItems().first {
            $0.entry.databaseType == .mysql
        }?.installationState
        #expect(state == .notInstalled)
    }

    @Test func managerCoalescesConcurrentInstallRequests() async throws {
        let registry = DatabaseDriverRegistry()
        let installer = ControlledDatabaseDriverInstaller()
        let firstStates = DatabaseDriverStateRecorder()
        let secondStates = DatabaseDriverStateRecorder()
        let manager = DatabaseDriverManager(
            registry: registry,
            installer: installer,
            compatibilityValidator: DatabaseDriverCompatibilityValidator(
                appVersion: "1.0.0"
            )
        )

        let first = Task {
            try await manager.install(.postgresql) { state in
                await firstStates.record(state)
            }
        }
        await installer.waitUntilStarted()
        let second = Task {
            try await manager.install(.postgresql) { state in
                await secondStates.record(state)
            }
        }
        await installer.finishInstallation()

        _ = try await (first.value, second.value)
        #expect(await installer.installCount() == 1)
        #expect(await registry.isInstalled(.postgresql))
        #expect(await firstStates.lastState() == .installed)
        #expect(await secondStates.lastState() == .installed)
    }

    @MainActor
    @Test func reopenedFlowObservesExistingInstallationUntilCompletion() async throws {
        let registry = DatabaseDriverRegistry()
        let installer = ControlledDatabaseDriverInstaller()
        let manager = DatabaseDriverManager(
            registry: registry,
            installer: installer,
            compatibilityValidator: DatabaseDriverCompatibilityValidator(
                appVersion: "1.0.0"
            )
        )
        let installation = Task {
            try await manager.install(.postgresql)
        }
        await installer.waitUntilStarted()

        let model = NewConnectionFlowModel(driverManager: manager)
        let loading = Task { @MainActor in
            await model.loadCatalog()
        }
        await installer.finishInstallation()

        try await installation.value
        await loading.value
        let postgresqlState = model.catalogItems.first {
            $0.entry.databaseType == .postgresql
        }?.installationState
        #expect(postgresqlState == .installed)
    }

    @Test func cancellingWaiterDoesNotCancelSharedInstallation() async throws {
        let registry = DatabaseDriverRegistry()
        let installer = ControlledDatabaseDriverInstaller()
        let manager = DatabaseDriverManager(
            registry: registry,
            installer: installer,
            compatibilityValidator: DatabaseDriverCompatibilityValidator(
                appVersion: "1.0.0"
            )
        )
        let waiter = Task {
            try await manager.install(.postgresql)
        }

        await installer.waitUntilStarted()
        waiter.cancel()
        await installer.finishInstallation()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(await installer.installCount() == 1)
        #expect(await registry.isInstalled(.postgresql))
        let postgresqlState = await manager.catalogItems().first {
            $0.entry.databaseType == .postgresql
        }?.installationState
        #expect(postgresqlState == .installed)
    }

    @Test func rejectsNewerDriverBeforeDownloadStarts() async {
        let installer = ControlledDatabaseDriverInstaller(
            minimumAppVersion: "99.0.0"
        )
        let manager = DatabaseDriverManager(
            registry: DatabaseDriverRegistry(),
            installer: installer,
            compatibilityValidator: DatabaseDriverCompatibilityValidator(
                appVersion: "1.0.0"
            )
        )

        await #expect(
            throws: DatabaseDriverInstallError.appVersionTooOld(
                minimumVersion: "99.0.0"
            )
        ) {
            try await manager.install(.postgresql)
        }
        #expect(await installer.installCount() == 0)
    }

    @Test func validatorRejectsIncompatibleDriverAPI() {
        let validator = DatabaseDriverCompatibilityValidator(
            appVersion: "1.0.0",
            driverAPIVersion: 1,
            architecture: .arm64
        )
        let package = DatabaseDriverPackage.fixture(
            driverAPIVersion: 2
        )

        #expect(throws: DatabaseDriverInstallError.incompatibleDriverAPI) {
            try validator.validate(package)
        }
    }

    @Test func validatorSelectsLatestCompatibleVersionAndBuild() throws {
        let validator = DatabaseDriverCompatibilityValidator(
            appVersion: "0.1.2",
            driverAPIVersion: 2,
            architecture: .arm64
        )
        let packages = [
            DatabaseDriverPackage.fixture(
                version: "1.0.2",
                build: "2",
                driverAPIVersion: 2,
                supportedArchitectures: [.arm64]
            ),
            DatabaseDriverPackage.fixture(
                version: "2.0.0",
                build: "1",
                minimumAppVersion: "0.2.0",
                driverAPIVersion: 2,
                supportedArchitectures: [.arm64]
            ),
            DatabaseDriverPackage.fixture(
                version: "9.0.0",
                build: "1",
                driverAPIVersion: 1,
                supportedArchitectures: [.arm64]
            ),
            DatabaseDriverPackage.fixture(
                version: "1.0.2",
                build: "10",
                driverAPIVersion: 2,
                supportedArchitectures: [.arm64]
            ),
        ]

        let selected = try validator.latestCompatiblePackage(in: packages)

        #expect(selected.version == "1.0.2")
        #expect(selected.build == "10")
    }

    @Test func validatorReportsCatalogCompatibilityFailures() {
        let validator = DatabaseDriverCompatibilityValidator(
            appVersion: "0.1.2",
            driverAPIVersion: 2,
            architecture: .arm64
        )
        #expect(throws: DatabaseDriverInstallError.incompatibleDriverAPI) {
            _ = try validator.latestCompatiblePackage(in: [
                .fixture(driverAPIVersion: 1)
            ])
        }
        #expect(
            throws: DatabaseDriverInstallError.appVersionTooOld(
                minimumVersion: "0.2.0"
            )
        ) {
            _ = try validator.latestCompatiblePackage(in: [
                .fixture(
                    minimumAppVersion: "0.3.0",
                    driverAPIVersion: 2,
                    supportedArchitectures: [.arm64]
                ),
                .fixture(
                    minimumAppVersion: "0.2.0",
                    driverAPIVersion: 2,
                    supportedArchitectures: [.arm64]
                ),
            ])
        }
    }

    @Test func catalogRejectsInvalidSchemaAndReleaseIdentity() {
        let package = DatabaseDriverPackage.fixture(
            databaseType: .mysql,
            supportedArchitectures: [.arm64]
        )
        let invalidSchema = DatabaseDriverPackageCatalog(
            schemaVersion: 1,
            databaseType: .mysql,
            architecture: .arm64,
            releases: [package]
        )
        #expect(throws: DatabaseDriverInstallError.invalidManifest) {
            _ = try invalidSchema.validatedPackages(
                for: .mysql,
                architecture: .arm64
            )
        }

        let mismatchedRelease = DatabaseDriverPackageCatalog(
            schemaVersion: DatabaseDriverPackageCatalog.currentSchemaVersion,
            databaseType: .postgresql,
            architecture: .arm64,
            releases: [package]
        )
        #expect(throws: DatabaseDriverInstallError.invalidManifest) {
            _ = try mismatchedRelease.validatedPackages(
                for: .postgresql,
                architecture: .arm64
            )
        }
    }

    @MainActor
    @Test func flowContinuesImmediatelyForInstalledDriver() async {
        let manager = DatabaseDriverManager(
            registry: DatabaseDriverRegistry(
                drivers: [RecordingDatabaseDriver(databaseType: .mysql)]
            )
        )
        let model = NewConnectionFlowModel(driverManager: manager)

        await model.loadCatalog()
        model.selectedDatabaseType = .mysql
        await model.continueWithSelection()

        #expect(model.step == .configure(.mysql))
    }

    @MainActor
    @Test func dorisProductsShareOneDriverInstallationState() async {
        let manager = DatabaseDriverManager(
            registry: DatabaseDriverRegistry(
                drivers: [RecordingDatabaseDriver(databaseType: .doris)]
            )
        )
        let model = NewConnectionFlowModel(driverManager: manager)

        await model.loadCatalog()
        let products = model.productItems.filter {
            $0.entry.databaseType == .doris
        }

        #expect(products.map(\.entry.databaseProduct) == [.apacheDoris, .selectDB])
        #expect(products.allSatisfy {
            $0.installationState == .installed
        })
    }

    @MainActor
    @Test func flowContinuesAfterInstallingSelectedDriver() async {
        let installer = ControlledDatabaseDriverInstaller()
        let model = NewConnectionFlowModel(
            driverManager: DatabaseDriverManager(
                registry: DatabaseDriverRegistry(),
                installer: installer,
                compatibilityValidator: DatabaseDriverCompatibilityValidator(
                    appVersion: "1.0.0"
                )
            )
        )
        await model.loadCatalog()
        model.selectedDatabaseType = .postgresql

        let task = Task { @MainActor in
            await model.continueWithSelection()
        }
        await installer.waitUntilStarted()
        await installer.finishInstallation()
        await task.value

        #expect(model.step == .configure(.postgresql))
        #expect(model.installationErrorMessage.isEmpty)
    }

    @MainActor
    @Test func flowKeepsSelectionVisibleWhenVersionIsTooOld() async {
        let installer = ControlledDatabaseDriverInstaller(
            minimumAppVersion: "99.0.0"
        )
        let model = NewConnectionFlowModel(
            driverManager: DatabaseDriverManager(
                registry: DatabaseDriverRegistry(),
                installer: installer,
                compatibilityValidator: DatabaseDriverCompatibilityValidator(
                    appVersion: "1.0.0"
                )
            )
        )
        await model.loadCatalog()
        model.selectedDatabaseType = .postgresql

        await model.continueWithSelection()

        #expect(model.step == .selectDatabase)
        #expect(!model.installationErrorMessage.isEmpty)
        #expect(model.isShowingInstallationError)
        #expect(await installer.installCount() == 0)
    }

    private func savedProfile(
        databaseType: DatabaseType
    ) -> ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: databaseType == .postgresql ? "pg" : "mysql",
            groupID: nil,
            databaseType: databaseType,
            host: "127.0.0.1",
            port: databaseType.defaultPort,
            username: databaseType.defaultUsername,
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: .now
        )
    }
}

@MainActor
struct InstalledMySQL56DatabaseDiscoveryTests {
    @Test func installedDriverPopulatesWorkspaceDatabases() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QUERYCRAFT_INSTALLED_DRIVER_TEST"] == "1" else {
            return
        }
        let driversDirectory = try #require(
            environment["QUERYCRAFT_INSTALLED_DRIVERS_DIRECTORY"]
        )
        let port = try #require(
            environment["QUERYCRAFT_MYSQL56_PORT"].flatMap(Int.init)
        )
        let expectedDatabase = environment["QUERYCRAFT_MYSQL56_DATABASE"]
            ?? "querycraft_driver_test"
        let registry = DatabaseDriverRegistry.shared
        await registry.unregister(.mysql)
        defer {
            Task { await registry.unregister(.mysql) }
        }
        let installer = DatabaseDriverPackageInstaller(
            registry: registry,
            driversDirectory: URL(fileURLWithPath: driversDirectory)
        )

        let drivers = await installer.loadInstalledDrivers()
        _ = try #require(
            drivers.first(where: { $0.databaseType == .mysql })
        )
        let profile = ConnectionProfile(
            id: UUID(),
            name: "MySQL 5.6",
            groupID: nil,
            databaseType: .mysql,
            host: environment["QUERYCRAFT_MYSQL56_HOST"] ?? "127.0.0.1",
            port: port,
            username: environment["QUERYCRAFT_MYSQL56_USERNAME"] ?? "root",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: true,
            createdAt: .now
        )
        let password = environment["QUERYCRAFT_MYSQL56_PASSWORD"]
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(
                passwords: [profile.id: password ?? ""]
            ),
            sessionFactory: DefaultWorkspaceSessionFactory(registry: registry)
        )

        let session = await model.connect()

        #expect(session != nil)
        #expect(model.connectionState == .connected)
        #expect(model.availableDatabaseNames.contains(expectedDatabase))
        await model.disconnect()
    }
}

@MainActor
struct InstalledPostgreSQLDatabaseObjectDiscoveryTests {
    @Test func installedDriverLoadsWorkspaceObjects() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QUERYCRAFT_INSTALLED_POSTGRESQL_DRIVER_TEST"] == "1"
        else { return }
        let driversDirectory = try #require(
            environment["QUERYCRAFT_INSTALLED_DRIVERS_DIRECTORY"]
        )
        let port = Int(environment["QUERYCRAFT_POSTGRESQL_PORT"] ?? "5437")
            ?? 5_437
        let database = environment["QUERYCRAFT_POSTGRESQL_DATABASE"]
            ?? "querycraft_driver_test"
        let username = environment["QUERYCRAFT_POSTGRESQL_USERNAME"]
            ?? "postgres"
        let password = environment["QUERYCRAFT_POSTGRESQL_PASSWORD"]
        let registry = DatabaseDriverRegistry.shared
        await registry.unregister(.postgresql)
        defer {
            Task { await registry.unregister(.postgresql) }
        }
        let driverURLs = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: driversDirectory),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let bundleURL = try #require(driverURLs.first { url in
            guard url.pathExtension == "querycraftdriver",
                  let bundle = Bundle(url: url)
            else { return false }
            return bundle.object(forInfoDictionaryKey: "QCDriverDatabaseType")
                as? String == DatabaseType.postgresql.rawValue
        })
        let bundle = try #require(Bundle(url: bundleURL))
        try bundle.loadAndReturnError()
        let entryType = try #require(
            bundle.principalClass as? QueryCraftDriverBundleEntry.Type
        )
        let entry = entryType.init()
        try await entry.activate()
        await LicenseAccessGate.shared.update(for: .unrestrictedDevelopment)
        let profile = ConnectionProfile(
            id: UUID(),
            name: "PostgreSQL 17",
            groupID: nil,
            databaseType: .postgresql,
            host: environment["QUERYCRAFT_POSTGRESQL_HOST"] ?? "127.0.0.1",
            port: port,
            username: username,
            defaultDatabase: database,
            tlsMode: .disabled,
            storesCredential: password != nil,
            createdAt: .now
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            databaseContextName: database,
            credentialStore: InMemoryCredentialStore(
                passwords: password.map { [profile.id: $0] } ?? [:]
            ),
            sessionFactory: DefaultWorkspaceSessionFactory(registry: registry)
        )

        let session = await model.connect()
        #expect(session != nil)
        #expect(model.connectionState == .connected)
        await model.loadObjects(in: database)

        let workspaceDatabase = try #require(
            model.databases.first(where: { $0.name == database })
        )
        guard case let .loaded(objects) = workspaceDatabase.objectsState else {
            Issue.record(
                "Installed PostgreSQL driver failed to load objects: \(workspaceDatabase.objectsState)"
            )
            await model.disconnect()
            return
        }
        #expect(objects.contains { $0.name == "public.driver_probe" })
        await model.disconnect()
    }
}

private actor RecordingDatabaseDriver: DatabaseDriver {
    nonisolated let databaseType: DatabaseType
    private var configurations: [DatabaseConnectionConfiguration] = []

    init(databaseType: DatabaseType) {
        self.databaseType = databaseType
    }

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> any WorkspaceSession {
        configurations.append(configuration)
        return InMemoryWorkspaceSession(databases: [])
    }

    func testConnection(
        configuration: DatabaseConnectionConfiguration
    ) async throws {
        configurations.append(configuration)
    }

    func receivedConfigurations() -> [DatabaseConnectionConfiguration] {
        configurations
    }
}

private actor DatabaseDriverStateRecorder {
    private var states: [DatabaseDriverInstallationState] = []

    func record(_ state: DatabaseDriverInstallationState) {
        states.append(state)
    }

    func lastState() -> DatabaseDriverInstallationState? {
        states.last
    }
}

private actor ControlledDatabaseDriverInstaller: DatabaseDriverInstaller {
    private var count = 0
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldFinish = false
    private let minimumAppVersion: String
    private let packageVersion: String
    private let packageBuild: String
    private var installedReleases: [DatabaseType: DatabaseDriverReleaseIdentity]
    private var uninstalledTypes: [DatabaseType] = []
    private var stagedTypes: [DatabaseType] = []
    private var pendingReleases: [DatabaseType: DatabaseDriverReleaseIdentity] = [:]

    init(
        minimumAppVersion: String = "0.1.0",
        packageVersion: String = "1.0.0",
        packageBuild: String = "1",
        installedVersions: [DatabaseType: String] = [:],
        installedBuilds: [DatabaseType: String] = [:]
    ) {
        self.minimumAppVersion = minimumAppVersion
        self.packageVersion = packageVersion
        self.packageBuild = packageBuild
        self.installedReleases = Dictionary(
            uniqueKeysWithValues: installedVersions.map { databaseType, version in
                (
                    databaseType,
                    DatabaseDriverReleaseIdentity(
                        version: version,
                        build: installedBuilds[databaseType] ?? "1"
                    )
                )
            }
        )
    }

    func installedRelease(
        for databaseType: DatabaseType
    ) -> DatabaseDriverReleaseIdentity? {
        installedReleases[databaseType]
    }

    func pendingUpdateRelease(
        for databaseType: DatabaseType
    ) -> DatabaseDriverReleaseIdentity? {
        pendingReleases[databaseType]
    }

    func resolvePackages(
        for entry: DatabaseDriverCatalogEntry
    ) async throws -> [DatabaseDriverPackage] {
        [DatabaseDriverPackage.fixture(
            databaseType: entry.databaseType,
            version: packageVersion,
            build: packageBuild,
            minimumAppVersion: minimumAppVersion
        )]
    }

    func uninstall(_ databaseType: DatabaseType) {
        uninstalledTypes.append(databaseType)
        installedReleases[databaseType] = nil
        pendingReleases[databaseType] = nil
    }

    func install(
        _ package: DatabaseDriverPackage,
        onProgress: @escaping @Sendable (
            DatabaseDriverInstallationProgress
        ) async -> Void
    ) async throws -> any DatabaseDriver {
        count += 1
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await onProgress(
            DatabaseDriverInstallationProgress(
                phase: .downloading,
                fractionCompleted: 0.5
            )
        )
        if !shouldFinish {
            await withCheckedContinuation { continuation in
                finishWaiters.append(continuation)
            }
        }
        await onProgress(
            DatabaseDriverInstallationProgress(phase: .verifying)
        )
        await onProgress(
            DatabaseDriverInstallationProgress(phase: .installing)
        )
        installedReleases[package.databaseType] = package.release
        return RecordingDatabaseDriver(databaseType: package.databaseType)
    }

    func stageUpdate(
        _ package: DatabaseDriverPackage,
        onProgress: @escaping @Sendable (
            DatabaseDriverInstallationProgress
        ) async -> Void
    ) async {
        stagedTypes.append(package.databaseType)
        await onProgress(
            DatabaseDriverInstallationProgress(
                phase: .downloading,
                fractionCompleted: 1,
                receivedBytes: package.downloadSize,
                totalBytes: package.downloadSize
            )
        )
        await onProgress(
            DatabaseDriverInstallationProgress(phase: .verifying)
        )
        pendingReleases[package.databaseType] = package.release
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishInstallation() {
        shouldFinish = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func installCount() -> Int {
        count
    }

    func uninstalledDatabaseTypes() -> [DatabaseType] {
        uninstalledTypes
    }

    func stagedDatabaseTypes() -> [DatabaseType] {
        stagedTypes
    }
}

private extension DatabaseDriverPackage {
    static func fixture(
        databaseType: DatabaseType = .postgresql,
        version: String = "1.0.0",
        build: String = "1",
        minimumAppVersion: String = "0.1.0",
        driverAPIVersion: Int = DatabaseDriverCompatibilityValidator.currentDriverAPIVersion,
        supportedArchitectures: Set<DatabaseDriverArchitecture> = [.arm64, .x86_64]
    ) -> Self {
        Self(
            databaseType: databaseType,
            version: version,
            build: build,
            minimumAppVersion: minimumAppVersion,
            driverAPIVersion: driverAPIVersion,
            supportedArchitectures: supportedArchitectures,
            downloadSize: 1_024,
            sha256: String(repeating: "0", count: 64),
            downloadURL: URL(string: "https://example.com/driver.zip")!
        )
    }
}
