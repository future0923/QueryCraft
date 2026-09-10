import Foundation

struct DatabaseDriverCatalogEntry: Equatable, Identifiable, Sendable {
    enum Category: String, Sendable {
        case relational
        case keyValue
        case document
    }

    let databaseType: DatabaseType
    let category: Category
    let isDownloadable: Bool
    let manifestURL: URL?

    var id: DatabaseType { databaseType }
    var displayName: String { databaseType.title }
    var defaultPort: Int { databaseType.defaultPort }
    var defaultUsername: String { databaseType.defaultUsername }
}

enum DatabaseDriverInstallationState: Equatable, Sendable {
    case notInstalled
    case installing(DatabaseDriverInstallationProgress)
    case updating(DatabaseDriverInstallationProgress)
    case uninstalling
    case installed
    case updateAvailable
    case updateReady
    case failed(message: String)

    var hasInstalledDriver: Bool {
        switch self {
        case .installed, .updateAvailable, .updateReady, .updating:
            true
        case .notInstalled, .installing, .uninstalling, .failed:
            false
        }
    }

    var isBusy: Bool {
        switch self {
        case .installing, .updating, .uninstalling:
            true
        case .notInstalled, .installed, .updateAvailable, .updateReady, .failed:
            false
        }
    }
}

struct DatabaseDriverCatalogItem: Equatable, Identifiable, Sendable {
    let entry: DatabaseDriverCatalogEntry
    let installationState: DatabaseDriverInstallationState
    let installedVersion: String?
    let availableVersion: String?
    let downloadSize: Int64?
    let availabilityErrorMessage: String?

    init(
        entry: DatabaseDriverCatalogEntry,
        installationState: DatabaseDriverInstallationState,
        installedVersion: String? = nil,
        availableVersion: String? = nil,
        downloadSize: Int64? = nil,
        availabilityErrorMessage: String? = nil
    ) {
        self.entry = entry
        self.installationState = installationState
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.downloadSize = downloadSize
        self.availabilityErrorMessage = availabilityErrorMessage
    }

    var id: DatabaseType { entry.databaseType }
}

enum DatabaseDriverCatalog {
    static let entries: [DatabaseDriverCatalogEntry] = [
        DatabaseDriverCatalogEntry(
            databaseType: .mysql,
            category: .relational,
            isDownloadable: true,
            manifestURL: manifestURL(for: .mysql)
        ),
        DatabaseDriverCatalogEntry(
            databaseType: .postgresql,
            category: .relational,
            isDownloadable: true,
            manifestURL: manifestURL(for: .postgresql)
        ),
        DatabaseDriverCatalogEntry(
            databaseType: .doris,
            category: .relational,
            isDownloadable: true,
            manifestURL: manifestURL(for: .doris)
        ),
        DatabaseDriverCatalogEntry(
            databaseType: .redis,
            category: .keyValue,
            isDownloadable: true,
            manifestURL: manifestURL(for: .redis)
        ),
        DatabaseDriverCatalogEntry(
            databaseType: .elasticsearch,
            category: .document,
            isDownloadable: true,
            manifestURL: manifestURL(for: .elasticsearch)
        ),
    ]

    static func entry(for databaseType: DatabaseType)
        -> DatabaseDriverCatalogEntry?
    {
        entries.first { $0.databaseType == databaseType }
    }

    static func manifestURL(
        for databaseType: DatabaseType,
        architecture: DatabaseDriverArchitecture = .current
    ) -> URL? {
        let environmentBaseURL = ProcessInfo.processInfo.environment[
            "QUERYCRAFT_DRIVER_CATALOG_BASE_URL"
        ]
        let bundleBaseURL = Bundle.main.object(
            forInfoDictionaryKey: "QCDriverCatalogBaseURL"
        ) as? String
        guard let baseURLString = environmentBaseURL ?? bundleBaseURL,
              let baseURL = URL(string: baseURLString)
        else {
            return nil
        }
        return baseURL.appending(
            path: "\(databaseType.rawValue)-\(architecture.rawValue).json"
        )
    }
}

struct DatabaseProductCatalogEntry: Equatable, Identifiable, Sendable {
    let databaseProduct: DatabaseProduct

    var id: DatabaseProduct { databaseProduct }
    var databaseType: DatabaseType { databaseProduct.databaseType }
    var displayName: String { databaseProduct.title }
}

struct DatabaseProductCatalogItem: Equatable, Identifiable, Sendable {
    let entry: DatabaseProductCatalogEntry
    let driverItem: DatabaseDriverCatalogItem

    var id: DatabaseProduct { entry.id }
    var installationState: DatabaseDriverInstallationState {
        driverItem.installationState
    }
    var installedVersion: String? { driverItem.installedVersion }
    var availableVersion: String? { driverItem.availableVersion }
    var downloadSize: Int64? { driverItem.downloadSize }
    var availabilityErrorMessage: String? {
        driverItem.availabilityErrorMessage
    }
}

enum DatabaseProductCatalog {
    static let entries = DatabaseProduct.allCases.map(DatabaseProductCatalogEntry.init)

    static func items(
        from driverItems: [DatabaseDriverCatalogItem]
    ) -> [DatabaseProductCatalogItem] {
        entries.compactMap { entry in
            guard let driverItem = driverItems.first(where: {
                $0.entry.databaseType == entry.databaseType
            }) else { return nil }
            return DatabaseProductCatalogItem(
                entry: entry,
                driverItem: driverItem
            )
        }
    }
}
