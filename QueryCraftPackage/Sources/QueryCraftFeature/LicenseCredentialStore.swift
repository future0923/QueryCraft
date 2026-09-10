import Foundation

protocol LicenseCredentialStore: Sendable {
    func installationID() async throws -> String?
    func saveInstallationID(_ value: String) async throws
    func deviceCredential() async throws -> String?
    func saveDeviceCredential(_ value: String) async throws
    func signedEntitlement() async throws -> SignedLicenseEntitlement?
    func saveSignedEntitlement(_ value: SignedLicenseEntitlement) async throws
    func lastObservedTime() async throws -> Date?
    func saveLastObservedTime(_ value: Date) async throws
    func clearPaidLicense() async throws
}

actor UnavailableLicenseCredentialStore: LicenseCredentialStore {
    func installationID() async throws -> String? { throw unavailable() }
    func saveInstallationID(_ value: String) async throws { throw unavailable() }
    func deviceCredential() async throws -> String? { throw unavailable() }
    func saveDeviceCredential(_ value: String) async throws { throw unavailable() }
    func signedEntitlement() async throws -> SignedLicenseEntitlement? {
        throw unavailable()
    }
    func saveSignedEntitlement(_ value: SignedLicenseEntitlement) async throws {
        throw unavailable()
    }
    func lastObservedTime() async throws -> Date? { throw unavailable() }
    func saveLastObservedTime(_ value: Date) async throws { throw unavailable() }
    func clearPaidLicense() async throws { throw unavailable() }

    private func unavailable() -> LicenseCredentialStoreError {
        .unavailable
    }
}
