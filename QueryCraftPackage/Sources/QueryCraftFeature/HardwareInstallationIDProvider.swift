import CryptoKit
import Foundation
import IOKit

protocol InstallationIDProviding: Sendable {
    func installationID() -> String?
}

protocol LicenseEncryptionKeyMaterialProviding: Sendable {
    func encryptionKeyMaterial() -> String?
}

struct HardwareInstallationIDProvider: InstallationIDProviding {
    private static let namespace =
        "io.github.future0923.QueryCraft.licensing.hardware-v1"

    private let platformUUID: @Sendable () -> String?

    init() {
        platformUUID = Self.readPlatformUUID
    }

    init(platformUUID: @escaping @Sendable () -> String?) {
        self.platformUUID = platformUUID
    }

    func installationID() -> String? {
        guard let platformUUID = platformUUID() else { return nil }
        return Self.makeInstallationID(platformUUID: platformUUID)
    }

    static func makeInstallationID(platformUUID: String) -> String? {
        let normalizedUUID = platformUUID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedUUID.isEmpty else { return nil }

        let namespacedValue = "\(namespace)\u{0}\(normalizedUUID)"
        let digest = SHA256.hash(data: Data(namespacedValue.utf8))
        return "hw1-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func readPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        return IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }
}

struct HardwareLicenseEncryptionKeyMaterialProvider:
    LicenseEncryptionKeyMaterialProviding
{
    private static let namespace =
        "io.github.future0923.QueryCraft.licensing.file-encryption-v1"

    private let platformUUID: @Sendable () -> String?

    init() {
        platformUUID = HardwareInstallationIDProvider.readPlatformUUID
    }

    init(platformUUID: @escaping @Sendable () -> String?) {
        self.platformUUID = platformUUID
    }

    func encryptionKeyMaterial() -> String? {
        guard let platformUUID = platformUUID() else { return nil }
        let normalizedUUID = platformUUID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedUUID.isEmpty else { return nil }
        let value = "\(Self.namespace)\u{0}\(normalizedUUID)"
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
