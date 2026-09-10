import CryptoKit
import Foundation
import OSLog
import Security

actor DatabaseDriverPackageInstaller: DatabaseDriverInstaller {
    private enum BundleKey {
        static let version = "CFBundleShortVersionString"
        static let build = "CFBundleVersion"
        static let databaseType = "QCDriverDatabaseType"
        static let driverAPIVersion = "QCDriverAPIVersion"
        static let minimumAppVersion = "QCMinimumAppVersion"
    }

    private static let bundleExtension = "querycraftdriver"
    private static let downloadBufferSize = 256 * 1_024
    private static let hashBufferSize = 1024 * 1_024

    private let fileManager: FileManager
    private let session: URLSession
    private let registry: DatabaseDriverRegistry
    private let driversDirectory: URL
    private let compatibilityValidator: DatabaseDriverCompatibilityValidator
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "QueryCraft",
        category: "DatabaseDriverPackageInstaller"
    )

    private var pendingUpdatesDirectory: URL {
        driversDirectory
            .deletingLastPathComponent()
            .appending(path: "DriverUpdates", directoryHint: .isDirectory)
    }

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        registry: DatabaseDriverRegistry = .shared,
        driversDirectory: URL? = nil,
        compatibilityValidator: DatabaseDriverCompatibilityValidator = .init()
    ) {
        self.fileManager = fileManager
        self.session = session
        self.registry = registry
        self.compatibilityValidator = compatibilityValidator
        self.driversDirectory = driversDirectory
            ?? Self.defaultDriversDirectory(fileManager: fileManager)
    }

    func loadInstalledDrivers() async -> [any DatabaseDriver] {
        applyPendingUpdates()
        guard let urls = try? fileManager.contentsOfDirectory(
            at: driversDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var drivers: [any DatabaseDriver] = []
        for url in urls where url.pathExtension == Self.bundleExtension {
            do {
                try Self.verifySignature(at: url)
                let metadata = try Self.validatedInstalledDriverMetadata(
                    at: url,
                    compatibilityValidator: compatibilityValidator
                )
                let driver = try await activate(
                    bundleURL: url,
                    expectedDatabaseType: metadata.databaseType
                )
                drivers.append(driver)
            } catch {
                logger.error(
                    "Unable to load installed driver at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
        }
        return drivers
    }

    func installedRelease(
        for databaseType: DatabaseType
    ) -> DatabaseDriverReleaseIdentity? {
        metadata(for: databaseType, in: driversDirectory)?.release
    }

    func pendingUpdateRelease(
        for databaseType: DatabaseType
    ) -> DatabaseDriverReleaseIdentity? {
        metadata(for: databaseType, in: pendingUpdatesDirectory)?.release
    }

    func uninstall(_ databaseType: DatabaseType) async throws {
        do {
            for directory in [driversDirectory, pendingUpdatesDirectory] {
                let bundles = driverBundles(in: directory).filter { url in
                    (try? Self.databaseType(at: url)) == databaseType
                }
                for bundleURL in bundles {
                    try Task.checkCancellation()
                    try fileManager.removeItem(at: bundleURL)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DatabaseDriverInstallError.uninstallFailed(
                databaseType,
                detail: error.localizedDescription
            )
        }
    }

    func resolvePackages(
        for entry: DatabaseDriverCatalogEntry
    ) async throws -> [DatabaseDriverPackage] {
        guard let manifestURL = entry.manifestURL else {
            throw DatabaseDriverInstallError.downloadSourceUnavailable(
                entry.databaseType
            )
        }
        let request = Self.uncachedRequest(for: manifestURL)
        let (data, response) = try await session.data(for: request)
        try Self.validateHTTPResponse(response)
        guard let catalog = try? JSONDecoder().decode(
            DatabaseDriverPackageCatalog.self,
            from: data
        ) else {
            throw DatabaseDriverInstallError.invalidManifest
        }
        return try catalog.validatedPackages(
            for: entry.databaseType,
            architecture: .current
        )
    }

    func install(
        _ package: DatabaseDriverPackage,
        onProgress: @escaping @Sendable (
            DatabaseDriverInstallationProgress
        ) async -> Void
    ) async throws -> any DatabaseDriver {
        let prepared = try await prepareBundle(
            package,
            onProgress: onProgress
        )
        defer { try? fileManager.removeItem(at: prepared.workingDirectory) }

        await onProgress(
            DatabaseDriverInstallationProgress(phase: .installing)
        )
        try Task.checkCancellation()
        let installedURL = try installAtomically(
            prepared.bundleURL,
            into: driversDirectory
        )
        try Self.verifySignature(at: installedURL)
        return try await activate(
            bundleURL: installedURL,
            expectedDatabaseType: package.databaseType
        )
    }

    func stageUpdate(
        _ package: DatabaseDriverPackage,
        onProgress: @escaping @Sendable (
            DatabaseDriverInstallationProgress
        ) async -> Void
    ) async throws {
        let prepared = try await prepareBundle(
            package,
            onProgress: onProgress
        )
        defer { try? fileManager.removeItem(at: prepared.workingDirectory) }

        await onProgress(
            DatabaseDriverInstallationProgress(phase: .installing)
        )
        try Task.checkCancellation()
        _ = try installAtomically(
            prepared.bundleURL,
            into: pendingUpdatesDirectory
        )
    }

    private struct PreparedDriverBundle {
        let workingDirectory: URL
        let bundleURL: URL
    }

    private func prepareBundle(
        _ package: DatabaseDriverPackage,
        onProgress: @escaping @Sendable (
            DatabaseDriverInstallationProgress
        ) async -> Void
    ) async throws -> PreparedDriverBundle {
        let stagingRoot = driversDirectory
            .deletingLastPathComponent()
            .appending(path: "DriverStaging", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        let workingDirectory = stagingRoot.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        do {
            let archiveURL = workingDirectory.appending(path: "driver.zip")
            try await download(
                package.downloadURL,
                to: archiveURL,
                expectedSize: package.downloadSize,
                onProgress: onProgress
            )

            await onProgress(
                DatabaseDriverInstallationProgress(phase: .verifying)
            )
            try Task.checkCancellation()
            guard try Self.sha256(of: archiveURL)
                == package.sha256.lowercased()
            else {
                throw DatabaseDriverInstallError.checksumMismatch
            }

            try Self.extractArchive(at: archiveURL, into: workingDirectory)
            let stagedBundleURL = try Self.findDriverBundle(in: workingDirectory)
            let metadata = try Self.metadata(at: stagedBundleURL)
            guard metadata.databaseType == package.databaseType,
                  metadata.version == package.version,
                  metadata.build == package.build,
                  metadata.driverAPIVersion == package.driverAPIVersion,
                  metadata.minimumAppVersion == package.minimumAppVersion
            else {
                throw DatabaseDriverInstallError.invalidBundle(
                    AppCopy.current.text(
                        "包内元数据与下载清单不一致。",
                        "Bundle metadata does not match the download manifest."
                    )
                )
            }
            try Self.verifySignature(at: stagedBundleURL)
            return PreparedDriverBundle(
                workingDirectory: workingDirectory,
                bundleURL: stagedBundleURL
            )
        } catch {
            try? fileManager.removeItem(at: workingDirectory)
            throw error
        }
    }

    private func download(
        _ sourceURL: URL,
        to destinationURL: URL,
        expectedSize: Int64?,
        onProgress: @escaping @Sendable (
            DatabaseDriverInstallationProgress
        ) async -> Void
    ) async throws {
        let request = Self.uncachedRequest(for: sourceURL)
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validateHTTPResponse(response)
        let responseSize = response.expectedContentLength > 0
            ? response.expectedContentLength
            : nil
        let totalSize = responseSize ?? expectedSize

        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(Self.downloadBufferSize)
        var receivedBytes: Int64 = 0
        let clock = ContinuousClock()
        var sampleInstant = clock.now
        var sampleBytes: Int64 = 0
        var bytesPerSecond: Double?
        await onProgress(
            DatabaseDriverInstallationProgress(
                phase: .downloading,
                fractionCompleted: totalSize.map { _ in 0 },
                receivedBytes: 0,
                totalBytes: totalSize
            )
        )

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            guard buffer.count >= Self.downloadBufferSize else { continue }
            try handle.write(contentsOf: buffer)
            receivedBytes += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            let now = clock.now
            bytesPerSecond = Self.transferRate(
                byteCount: receivedBytes - sampleBytes,
                duration: sampleInstant.duration(to: now)
            ) ?? bytesPerSecond
            await reportDownloadProgress(
                receivedBytes: receivedBytes,
                totalSize: totalSize,
                bytesPerSecond: bytesPerSecond,
                onProgress: onProgress
            )
            sampleInstant = now
            sampleBytes = receivedBytes
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            receivedBytes += Int64(buffer.count)
            let now = clock.now
            bytesPerSecond = Self.transferRate(
                byteCount: receivedBytes - sampleBytes,
                duration: sampleInstant.duration(to: now)
            ) ?? bytesPerSecond
        }
        await reportDownloadProgress(
            receivedBytes: receivedBytes,
            totalSize: totalSize,
            bytesPerSecond: bytesPerSecond,
            onProgress: onProgress
        )
    }

    private func reportDownloadProgress(
        receivedBytes: Int64,
        totalSize: Int64?,
        bytesPerSecond: Double?,
        onProgress: @escaping @Sendable (
            DatabaseDriverInstallationProgress
        ) async -> Void
    ) async {
        let fraction = totalSize.flatMap { size in
            size > 0 ? Double(receivedBytes) / Double(size) : nil
        }
        await onProgress(
            DatabaseDriverInstallationProgress(
                phase: .downloading,
                fractionCompleted: fraction,
                receivedBytes: receivedBytes,
                totalBytes: totalSize,
                bytesPerSecond: bytesPerSecond
            )
        )
    }

    private nonisolated static func transferRate(
        byteCount: Int64,
        duration: Duration
    ) -> Double? {
        guard byteCount > 0 else { return nil }
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds > 0 else { return nil }
        return Double(byteCount) / seconds
    }

    private func installAtomically(
        _ stagedBundleURL: URL,
        into destinationDirectory: URL
    ) throws -> URL {
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = destinationDirectory.appending(
            path: stagedBundleURL.lastPathComponent,
            directoryHint: .isDirectory
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            var resultURL: NSURL?
            let backupName = "\(destinationURL.lastPathComponent).backup"
            try fileManager.replaceItem(
                at: destinationURL,
                withItemAt: stagedBundleURL,
                backupItemName: backupName,
                options: [],
                resultingItemURL: &resultURL
            )
            try? fileManager.removeItem(
                at: destinationDirectory.appending(path: backupName)
            )
            return (resultURL as URL?) ?? destinationURL
        }
        try fileManager.moveItem(at: stagedBundleURL, to: destinationURL)
        return destinationURL
    }

    private func applyPendingUpdates() {
        for pendingURL in driverBundles(in: pendingUpdatesDirectory) {
            do {
                try Task.checkCancellation()
                try Self.verifySignature(at: pendingURL)
                _ = try Self.metadata(at: pendingURL)
                _ = try installAtomically(
                    pendingURL,
                    into: driversDirectory
                )
            } catch {
                continue
            }
        }
    }

    private func driverBundles(in directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == Self.bundleExtension } ?? []
    }

    private func metadata(
        for databaseType: DatabaseType,
        in directory: URL
    ) -> DriverMetadata? {
        for url in driverBundles(in: directory) {
            guard let metadata = try? Self.metadata(at: url),
                  metadata.databaseType == databaseType
            else {
                continue
            }
            return metadata
        }
        return nil
    }

    private func activate(
        bundleURL: URL,
        expectedDatabaseType: DatabaseType
    ) async throws -> any DatabaseDriver {
        guard let bundle = Bundle(url: bundleURL) else {
            throw DatabaseDriverInstallError.invalidBundle(
                bundleURL.lastPathComponent
            )
        }
        let entry = try await MainActor.run {
            do {
                try bundle.loadAndReturnError()
            } catch {
                throw DatabaseDriverInstallError.activationFailed(
                    error.localizedDescription
                )
            }
            guard let entryType = bundle.principalClass
                as? QueryCraftDriverBundleEntry.Type
            else {
                let principalClass = bundle.object(
                    forInfoDictionaryKey: "NSPrincipalClass"
                ) as? String
                throw DatabaseDriverInstallError.activationFailed(
                    principalClass
                        ?? bundle.executableURL?.lastPathComponent
                        ?? bundleURL.lastPathComponent
                )
            }
            return entryType.init()
        }
        try await entry.activate()
        guard let driver = await registry.driver(for: expectedDatabaseType)
        else {
            throw DatabaseDriverInstallError.activationFailed(
                expectedDatabaseType.rawValue
            )
        }
        return driver
    }

    private nonisolated static func defaultDriversDirectory(
        fileManager: FileManager
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appending(path: "QueryCraft", directoryHint: .isDirectory)
            .appending(path: "Drivers", directoryHint: .isDirectory)
    }

    private nonisolated static func validateHTTPResponse(
        _ response: URLResponse
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DatabaseDriverInstallError.downloadFailed(
                "HTTP \(status)"
            )
        }
    }

    nonisolated static func uncachedRequest(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: hashBufferSize),
              !data.isEmpty
        {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func extractArchive(
        at archiveURL: URL,
        into directoryURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", archiveURL.path, directoryURL.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DatabaseDriverInstallError.invalidArchive(
                detail?.isEmpty == false
                    ? detail!
                    : "ditto \(process.terminationStatus)"
            )
        }
    }

    private nonisolated static func findDriverBundle(
        in directoryURL: URL
    ) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == bundleExtension }
        guard contents.count == 1, let bundleURL = contents.first else {
            throw DatabaseDriverInstallError.invalidArchive(
                AppCopy.current.text(
                    "压缩包必须只包含一个驱动。",
                    "The archive must contain exactly one driver."
                )
            )
        }
        return bundleURL
    }

    struct DriverMetadata {
        let databaseType: DatabaseType
        let version: String
        let build: String
        let driverAPIVersion: Int
        let minimumAppVersion: String

        var release: DatabaseDriverReleaseIdentity {
            DatabaseDriverReleaseIdentity(version: version, build: build)
        }
    }

    nonisolated static func validatedInstalledDriverMetadata(
        at bundleURL: URL,
        compatibilityValidator: DatabaseDriverCompatibilityValidator
    ) throws -> DriverMetadata {
        let metadata = try metadata(at: bundleURL)
        try compatibilityValidator.validateInstalledDriver(
            driverAPIVersion: metadata.driverAPIVersion,
            minimumAppVersion: metadata.minimumAppVersion
        )
        return metadata
    }

    private nonisolated static func metadata(at bundleURL: URL) throws
        -> DriverMetadata
    {
        let info = try infoDictionary(at: bundleURL)
        guard let rawType = info[BundleKey.databaseType] as? String,
              let databaseType = DatabaseType(rawValue: rawType),
              let version = info[BundleKey.version] as? String,
              let build = info[BundleKey.build] as? String,
              let driverAPIVersion = info[BundleKey.driverAPIVersion] as? Int,
              let minimumAppVersion = info[BundleKey.minimumAppVersion]
                as? String,
              info["NSPrincipalClass"] as? String != nil
        else {
            throw DatabaseDriverInstallError.invalidBundle(
                AppCopy.current.text(
                    "缺少必需的驱动元数据。",
                    "Required driver metadata is missing."
                )
            )
        }
        return DriverMetadata(
            databaseType: databaseType,
            version: version,
            build: build,
            driverAPIVersion: driverAPIVersion,
            minimumAppVersion: minimumAppVersion
        )
    }

    nonisolated static func releaseIdentity(
        at bundleURL: URL
    ) throws -> DatabaseDriverReleaseIdentity {
        try metadata(at: bundleURL).release
    }

    private nonisolated static func databaseType(
        at bundleURL: URL
    ) throws -> DatabaseType {
        let info = try infoDictionary(at: bundleURL)
        guard let rawType = info[BundleKey.databaseType] as? String,
              let databaseType = DatabaseType(rawValue: rawType)
        else {
            throw DatabaseDriverInstallError.invalidBundle(
                bundleURL.lastPathComponent
            )
        }
        return databaseType
    }

    private nonisolated static func infoDictionary(
        at bundleURL: URL
    ) throws -> [String: Any] {
        let infoURL = bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
        else {
            throw DatabaseDriverInstallError.invalidBundle(
                bundleURL.lastPathComponent
            )
        }
        return info
    }

    private nonisolated static func verifySignature(at bundleURL: URL) throws {
        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard creationStatus == errSecSuccess, let staticCode else {
            throw DatabaseDriverInstallError.signatureInvalid(
                describeOSStatus(creationStatus)
            )
        }

        let integrityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(
                rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
            ),
            nil
        )
        guard integrityStatus == errSecSuccess else {
            throw DatabaseDriverInstallError.signatureInvalid(
                describeOSStatus(integrityStatus)
            )
        }

        let hostTeam = hostTeamIdentifier()
        let driverTeam = teamIdentifier(for: staticCode)
        let driverIsAdHoc = isAdHocSignature(staticCode)
        #if DEBUG
        if driverIsAdHoc {
            return
        }
        #endif
        guard signatureMatchesHost(
            hostTeamIdentifier: hostTeam,
            driverTeamIdentifier: driverTeam,
            driverIsAdHoc: driverIsAdHoc
        )
        else {
            throw DatabaseDriverInstallError.signatureInvalid(
                AppCopy.current.text(
                    "驱动签名身份与当前应用不一致。",
                    "The driver signature identity does not match this app."
                )
            )
        }

        guard let hostTeam else { return }
        guard let requirement = signingRequirement(
            teamIdentifier: hostTeam
        ) else {
            throw DatabaseDriverInstallError.signatureInvalid(
                "Unable to create the Apple signing requirement."
            )
        }
        let trustStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(
                rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
            ),
            requirement
        )
        guard trustStatus == errSecSuccess else {
            throw DatabaseDriverInstallError.signatureInvalid(
                describeOSStatus(trustStatus)
            )
        }
    }

    nonisolated static func signatureMatchesHost(
        hostTeamIdentifier: String?,
        driverTeamIdentifier: String?,
        driverIsAdHoc: Bool
    ) -> Bool {
        if let hostTeamIdentifier {
            return driverTeamIdentifier == hostTeamIdentifier
        }
        return driverTeamIdentifier == nil && driverIsAdHoc
    }

    private nonisolated static func signingRequirement(
        teamIdentifier: String
    )
        -> SecRequirement?
    {
        let source = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            source as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private nonisolated static func hostTeamIdentifier() -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            Bundle.main.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        return teamIdentifier(for: staticCode)
    }

    private nonisolated static func teamIdentifier(
        for staticCode: SecStaticCode
    ) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else {
            return nil
        }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private nonisolated static func isAdHocSignature(
        _ staticCode: SecStaticCode
    ) -> Bool {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let flags = dictionary[kSecCodeInfoFlags as String] as? NSNumber
        else {
            return false
        }
        // The CodeDirectory ad-hoc flag is 0x2 (CS_ADHOC in cs_blobs.h).
        return flags.uint32Value & 0x2 != 0
    }

    private nonisolated static func describeOSStatus(
        _ status: OSStatus
    ) -> String {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "OSStatus \(status)"
    }
}
