import CryptoKit
import Foundation

enum LicenseCredentialStoreError: Error {
    case invalidData
    case unavailable
}

actor FileLicenseCredentialStore: LicenseCredentialStore {
    private struct Envelope: Codable {
        let version: Int
        let ciphertext: Data
    }

    private struct StoredCredential: Codable {
        var installationID: String?
        var deviceCredential: String?
        var signedEntitlement: SignedLicenseEntitlement?
        var lastObservedTime: Date?
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encryptionKey: SymmetricKey

    init(
        fileURL: URL? = nil,
        encryptionKeyMaterial: String,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL ?? FileLicenseCredentialStore.defaultFileURL
        self.fileManager = fileManager
        let namespacedMaterial =
            "io.github.future0923.QueryCraft.licensing.file-v1\0" +
            encryptionKeyMaterial
        encryptionKey = SymmetricKey(
            data: SHA256.hash(data: Data(namespacedMaterial.utf8))
        )
    }

    func installationID() async throws -> String? {
        try read().installationID
    }

    func saveInstallationID(_ value: String) async throws {
        try update { $0.installationID = value }
    }

    func deviceCredential() async throws -> String? {
        try read().deviceCredential
    }

    func saveDeviceCredential(_ value: String) async throws {
        try update { $0.deviceCredential = value }
    }

    func signedEntitlement() async throws -> SignedLicenseEntitlement? {
        try read().signedEntitlement
    }

    func saveSignedEntitlement(_ value: SignedLicenseEntitlement) async throws {
        try update { $0.signedEntitlement = value }
    }

    func lastObservedTime() async throws -> Date? {
        try read().lastObservedTime
    }

    func saveLastObservedTime(_ value: Date) async throws {
        try update { $0.lastObservedTime = value }
    }

    func clearPaidLicense() async throws {
        try update {
            $0.deviceCredential = nil
            $0.signedEntitlement = nil
        }
    }

    private func update(
        _ changes: (inout StoredCredential) -> Void
    ) throws {
        var credential = try read()
        changes(&credential)
        try write(credential)
    }

    private func read() throws -> StoredCredential {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return StoredCredential()
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1 else {
                throw LicenseCredentialStoreError.invalidData
            }
            let sealedBox = try AES.GCM.SealedBox(combined: envelope.ciphertext)
            let cleartext = try AES.GCM.open(sealedBox, using: encryptionKey)
            return try JSONDecoder().decode(StoredCredential.self, from: cleartext)
        } catch is DecodingError {
            throw LicenseCredentialStoreError.invalidData
        } catch is CryptoKitError {
            throw LicenseCredentialStoreError.invalidData
        } catch let error as LicenseCredentialStoreError {
            throw error
        } catch {
            throw LicenseCredentialStoreError.unavailable
        }
    }

    private func write(_ credential: StoredCredential) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let cleartext = try JSONEncoder().encode(credential)
            let sealedBox = try AES.GCM.seal(cleartext, using: encryptionKey)
            guard let combined = sealedBox.combined else {
                throw LicenseCredentialStoreError.unavailable
            }
            let envelope = Envelope(version: 1, ciphertext: combined)
            try JSONEncoder().encode(envelope).write(
                to: fileURL,
                options: .atomic
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw LicenseCredentialStoreError.unavailable
        }
    }

    private static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "QueryCraft", directoryHint: .isDirectory)
            .appending(path: "Licensing", directoryHint: .isDirectory)
            .appending(path: "credential-v1.json")
    }
}
