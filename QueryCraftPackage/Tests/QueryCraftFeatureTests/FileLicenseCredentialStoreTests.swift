import Foundation
import Testing

@testable import QueryCraftFeature

struct FileLicenseCredentialStoreTests {
    @Test
    func encryptsCredentialAndRestrictsFilePermissions() async throws {
        let fixture = try makeFixture()
        let store = FileLicenseCredentialStore(
            fileURL: fixture.fileURL,
            encryptionKeyMaterial: "hardware-secret-a"
        )
        let entitlement = SignedLicenseEntitlement(
            payload: "signed-payload-secret",
            signature: "signed-signature-secret"
        )

        try await store.saveInstallationID("installation-secret")
        try await store.saveDeviceCredential("device-credential-secret")
        try await store.saveSignedEntitlement(entitlement)
        try await store.saveLastObservedTime(
            Date(timeIntervalSince1970: 1_700_000_000)
        )

        let fileData = try Data(contentsOf: fixture.fileURL)
        let fileText = String(decoding: fileData, as: UTF8.self)
        #expect(!fileText.contains("installation-secret"))
        #expect(!fileText.contains("device-credential-secret"))
        #expect(!fileText.contains("signed-payload-secret"))
        #expect(try permissions(of: fixture.directoryURL) == 0o700)
        #expect(try permissions(of: fixture.fileURL) == 0o600)

        #expect(try await store.installationID() == "installation-secret")
        #expect(
            try await store.deviceCredential() == "device-credential-secret"
        )
        #expect(try await store.signedEntitlement() == entitlement)
    }

    @Test
    func rejectsAnotherDeviceKeyAndTamperedCiphertext() async throws {
        let fixture = try makeFixture()
        let store = FileLicenseCredentialStore(
            fileURL: fixture.fileURL,
            encryptionKeyMaterial: "hardware-secret-a"
        )
        try await store.saveDeviceCredential("device-credential-secret")

        let otherDeviceStore = FileLicenseCredentialStore(
            fileURL: fixture.fileURL,
            encryptionKeyMaterial: "hardware-secret-b"
        )
        await #expect(throws: LicenseCredentialStoreError.self) {
            _ = try await otherDeviceStore.deviceCredential()
        }

        var data = try Data(contentsOf: fixture.fileURL)
        data[data.index(before: data.endIndex)] ^= 0x01
        try data.write(to: fixture.fileURL, options: .atomic)
        await #expect(throws: LicenseCredentialStoreError.self) {
            _ = try await store.deviceCredential()
        }
    }

    @Test
    func clearingPaidLicensePreservesInstallationIdentity() async throws {
        let fixture = try makeFixture()
        let store = FileLicenseCredentialStore(
            fileURL: fixture.fileURL,
            encryptionKeyMaterial: "hardware-secret-a"
        )
        try await store.saveInstallationID("installation-secret")
        try await store.saveDeviceCredential("device-credential-secret")
        try await store.saveSignedEntitlement(
            SignedLicenseEntitlement(payload: "payload", signature: "signature")
        )

        try await store.clearPaidLicense()

        #expect(try await store.installationID() == "installation-secret")
        #expect(try await store.deviceCredential() == nil)
        #expect(try await store.signedEntitlement() == nil)
    }

    private func makeFixture() throws -> (
        directoryURL: URL,
        fileURL: URL
    ) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "Licensing", directoryHint: .isDirectory)
        let fileURL = directoryURL.appending(path: "credential-v1.json")
        return (directoryURL, fileURL)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return attributes[.posixPermissions] as? Int ?? 0
    }
}
