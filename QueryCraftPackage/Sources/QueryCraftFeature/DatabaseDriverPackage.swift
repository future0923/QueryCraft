import Foundation

struct DatabaseDriverPackage: Codable, Equatable, Sendable {
    let databaseType: DatabaseType
    let version: String
    let build: String
    let minimumAppVersion: String
    let driverAPIVersion: Int
    let supportedArchitectures: Set<DatabaseDriverArchitecture>
    let downloadSize: Int64?
    let sha256: String
    let downloadURL: URL

    var release: DatabaseDriverReleaseIdentity {
        DatabaseDriverReleaseIdentity(version: version, build: build)
    }
}

struct DatabaseDriverPackageCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let databaseType: DatabaseType
    let architecture: DatabaseDriverArchitecture
    let releases: [DatabaseDriverPackage]

    func validatedPackages(
        for databaseType: DatabaseType,
        architecture expectedArchitecture: DatabaseDriverArchitecture
    ) throws -> [DatabaseDriverPackage] {
        guard schemaVersion == Self.currentSchemaVersion,
              self.databaseType == databaseType,
              architecture == expectedArchitecture,
              !releases.isEmpty,
              releases.allSatisfy({ package in
                  package.databaseType == databaseType
                      && package.supportedArchitectures == [architecture]
              })
        else {
            throw DatabaseDriverInstallError.invalidManifest
        }
        return releases
    }
}

struct DatabaseDriverReleaseIdentity: Equatable, Sendable {
    let version: String
    let build: String

    func isNewer(than other: Self) -> Bool {
        let versionOrder = version.compare(other.version, options: .numeric)
        if versionOrder != .orderedSame {
            return versionOrder == .orderedDescending
        }
        return build.compare(other.build, options: .numeric) == .orderedDescending
    }
}

enum DatabaseDriverArchitecture: String, Codable, Hashable, Sendable {
    case arm64
    case x86_64

    static var current: Self {
        #if arch(arm64)
        .arm64
        #else
        .x86_64
        #endif
    }
}

struct DatabaseDriverCompatibilityValidator: Sendable {
    static let currentDriverAPIVersion = 3

    let appVersion: String
    let driverAPIVersion: Int
    let architecture: DatabaseDriverArchitecture

    init(
        appVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0",
        driverAPIVersion: Int = Self.currentDriverAPIVersion,
        architecture: DatabaseDriverArchitecture = .current
    ) {
        self.appVersion = appVersion
        self.driverAPIVersion = driverAPIVersion
        self.architecture = architecture
    }

    func validate(_ package: DatabaseDriverPackage) throws {
        try validateInstalledDriver(
            driverAPIVersion: package.driverAPIVersion,
            minimumAppVersion: package.minimumAppVersion
        )
        guard package.supportedArchitectures.contains(architecture) else {
            throw DatabaseDriverInstallError.unsupportedArchitecture
        }
    }

    func validateInstalledDriver(
        driverAPIVersion installedDriverAPIVersion: Int,
        minimumAppVersion: String
    ) throws {
        guard appVersion.compare(
            minimumAppVersion,
            options: .numeric
        ) != .orderedAscending else {
            throw DatabaseDriverInstallError.appVersionTooOld(
                minimumVersion: minimumAppVersion
            )
        }
        guard installedDriverAPIVersion == driverAPIVersion else {
            throw DatabaseDriverInstallError.incompatibleDriverAPI
        }
    }

    func latestCompatiblePackage(
        in packages: [DatabaseDriverPackage]
    ) throws -> DatabaseDriverPackage {
        let matchingAPI = packages.filter {
            $0.driverAPIVersion == driverAPIVersion
        }
        guard !matchingAPI.isEmpty else {
            throw DatabaseDriverInstallError.incompatibleDriverAPI
        }

        let matchingArchitecture = matchingAPI.filter {
            $0.supportedArchitectures.contains(architecture)
        }
        guard !matchingArchitecture.isEmpty else {
            throw DatabaseDriverInstallError.unsupportedArchitecture
        }

        let compatible = matchingArchitecture.filter {
            appVersion.compare(
                $0.minimumAppVersion,
                options: .numeric
            ) != .orderedAscending
        }
        guard let latest = compatible.max(by: {
            $1.release.isNewer(than: $0.release)
        }) else {
            let minimumVersion = matchingArchitecture
                .map(\.minimumAppVersion)
                .min {
                    $0.compare($1, options: .numeric) == .orderedAscending
                } ?? "0"
            throw DatabaseDriverInstallError.appVersionTooOld(
                minimumVersion: minimumVersion
            )
        }
        return latest
    }
}

enum DatabaseDriverInstallError: LocalizedError, Equatable {
    case downloadSourceUnavailable(DatabaseType)
    case invalidManifest
    case downloadFailed(String)
    case checksumMismatch
    case invalidArchive(String)
    case invalidBundle(String)
    case signatureInvalid(String)
    case activationFailed(String)
    case appVersionTooOld(minimumVersion: String)
    case incompatibleDriverAPI
    case unsupportedArchitecture
    case driverBusy(DatabaseType)
    case uninstallFailed(DatabaseType, detail: String)

    var errorDescription: String? {
        switch self {
        case .downloadSourceUnavailable(let databaseType):
            AppCopy.current.text(
                "\(databaseType.title) 驱动下载源尚未配置。",
                "The download source for the \(databaseType.title) driver is not configured."
            )
        case .invalidManifest:
            AppCopy.current.text(
                "驱动清单格式无效。",
                "The driver manifest is invalid."
            )
        case .downloadFailed(let detail):
            AppCopy.current.text(
                "驱动下载失败：\(detail)",
                "Driver download failed: \(detail)"
            )
        case .checksumMismatch:
            AppCopy.current.text(
                "驱动文件校验失败，下载内容可能已损坏。",
                "Driver verification failed because the download may be corrupted."
            )
        case .invalidArchive(let detail):
            AppCopy.current.text(
                "驱动压缩包无效：\(detail)",
                "The driver archive is invalid: \(detail)"
            )
        case .invalidBundle(let detail):
            AppCopy.current.text(
                "驱动包无效：\(detail)",
                "The driver bundle is invalid: \(detail)"
            )
        case .signatureInvalid(let detail):
            AppCopy.current.text(
                "驱动签名校验失败：\(detail)",
                "Driver signature verification failed: \(detail)"
            )
        case .activationFailed(let detail):
            AppCopy.current.text(
                "驱动无法加载：\(detail)",
                "The driver could not be loaded: \(detail)"
            )
        case .appVersionTooOld(let minimumVersion):
            AppCopy.current.text(
                "此驱动需要 QueryCraft \(minimumVersion) 或更高版本。",
                "This driver requires QueryCraft \(minimumVersion) or later."
            )
        case .incompatibleDriverAPI:
            AppCopy.current.text(
                "此驱动与当前 QueryCraft 驱动接口不兼容。",
                "This driver is incompatible with the current QueryCraft driver API."
            )
        case .unsupportedArchitecture:
            AppCopy.current.text(
                "此驱动不支持当前 Mac 的处理器架构。",
                "This driver does not support this Mac's processor architecture."
            )
        case .driverBusy(let databaseType):
            AppCopy.current.text(
                "\(databaseType.title) 驱动正在执行其他操作，请稍后重试。",
                "The \(databaseType.title) driver is busy. Try again shortly."
            )
        case .uninstallFailed(let databaseType, let detail):
            AppCopy.current.text(
                "无法卸载 \(databaseType.title) 驱动：\(detail)",
                "Unable to uninstall the \(databaseType.title) driver: \(detail)"
            )
        }
    }
}
