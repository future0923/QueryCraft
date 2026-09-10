import CryptoKit
import Foundation
import Testing

@testable import QueryCraftFeature

@MainActor
struct LicenseManagerTests {
    private let currentTime = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func usesSignedOfflineGraceWhenValidationServerIsUnavailable() async throws {
        let fixture = try makeFixture(serviceError: .serverUnavailable)

        await fixture.manager.prepare()

        #expect(
            fixture.manager.state == .offlineGrace(
                plan: .annual,
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                validUntil: Date(timeIntervalSince1970: 1_702_592_000)
            )
        )
    }

    @Test
    func doesNotUseCachedLicenseAfterServerSuspendsIt() async throws {
        let fixture = try makeFixture(serviceError: .licenseSuspended)

        await fixture.manager.prepare()

        #expect(fixture.manager.state == .restricted(.licenseSuspended))
    }

    @Test
    func revalidatesFreshCachedLicenseOnEveryLaunch() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try LicenseTokenVerifier(
            publicKeyData: privateKey.publicKey.rawRepresentation
        )
        let entitlement = try signedEntitlement(
            privateKey: privateKey,
            validationDueAt: 1_750_000_000
        )
        let store = InMemoryLicenseCredentialStore(
            installationID: "installation-a",
            deviceCredential: "qcd-test-credential",
            entitlement: entitlement
        )
        let service = RecordingLicenseService(entitlement: entitlement)
        let manager = LicenseManager(
            configuration: LicensingConfiguration(
                isEnabled: true,
                apiBaseURL: URL(string: "https://license.example/api/v1/"),
                publicKey: privateKey.publicKey.rawRepresentation,
                purchaseURL: nil
            ),
            service: service,
            credentialStore: store,
            installationIDProvider: FixedInstallationIDProvider(
                value: "installation-a"
            ),
            verifier: verifier,
            accessGate: LicenseAccessGate(),
            now: { currentTime },
            deviceName: "Test Mac"
        )

        await manager.prepare()

        #expect(await service.validationCount() == 1)
        #expect(
            manager.state == .paid(
                plan: .annual,
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                maximumActivations: 2
            )
        )
    }

    @Test
    func activationStoresDeviceCredentialInsteadOfLicenseKey() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try LicenseTokenVerifier(
            publicKeyData: privateKey.publicKey.rawRepresentation
        )
        let entitlement = try signedEntitlement(
            privateKey: privateKey,
            deviceCredential: "qcd-device-credential"
        )
        let store = InMemoryLicenseCredentialStore(
            installationID: "installation-a",
            deviceCredential: nil,
            entitlement: nil
        )
        let manager = LicenseManager(
            configuration: LicensingConfiguration(
                isEnabled: true,
                apiBaseURL: URL(string: "https://license.example/api/v1/"),
                publicKey: privateKey.publicKey.rawRepresentation,
                purchaseURL: nil
            ),
            service: RecordingLicenseService(entitlement: entitlement),
            credentialStore: store,
            installationIDProvider: FixedInstallationIDProvider(
                value: "installation-a"
            ),
            verifier: verifier,
            accessGate: LicenseAccessGate(),
            now: { currentTime },
            deviceName: "Test Mac"
        )

        try await manager.activate(licenseKey: "QC-ONE-TIME-KEY")

        #expect(
            try await store.deviceCredential() == "qcd-device-credential"
        )
        #expect(
            try await store.signedEntitlement()?.deviceCredential == nil
        )
        #expect(
            manager.state == .paid(
                plan: .annual,
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                maximumActivations: 2
            )
        )
    }

    @Test
    func retriesValidationHourlyDuringOfflineGrace() {
        let payload = LicenseEntitlementPayload(
            version: 1,
            entitlementID: "license-1",
            kind: .paid,
            plan: .annual,
            installationID: "installation-a",
            issuedAt: 1_699_000_000,
            expiresAt: 1_800_000_000,
            validationDueAt: 1_699_999_999,
            offlineValidUntil: 1_702_592_000,
            maximumActivations: 2
        )

        #expect(
            LicenseManager.nextRefreshDate(
                payload: payload,
                now: currentTime,
                usesOfflineGrace: true
            ) == currentTime.addingTimeInterval(60 * 60)
        )
    }

    @Test
    func replacesLegacyKeychainIdentifierWithHardwareIdentifier() async throws {
        let hardwareID = "hw1-querycraft-test-installation"
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try LicenseTokenVerifier(
            publicKeyData: privateKey.publicKey.rawRepresentation
        )
        let entitlement = try signedEntitlement(
            privateKey: privateKey,
            installationID: hardwareID,
            validationDueAt: 1_750_000_000
        )
        let store = InMemoryLicenseCredentialStore(
            installationID: "legacy-random-installation",
            deviceCredential: "qcd-test-credential",
            entitlement: entitlement
        )
        let manager = LicenseManager(
            configuration: LicensingConfiguration(
                isEnabled: true,
                apiBaseURL: URL(string: "https://license.example/api/v1/"),
                publicKey: privateKey.publicKey.rawRepresentation,
                purchaseURL: nil
            ),
            service: FailingLicenseService(error: .serverUnavailable),
            credentialStore: store,
            installationIDProvider: FixedInstallationIDProvider(
                value: hardwareID
            ),
            verifier: verifier,
            accessGate: LicenseAccessGate(),
            now: { currentTime },
            deviceName: "Test Mac"
        )

        await manager.prepare()

        #expect(try await store.installationID() == hardwareID)
        #expect(
            manager.state == .offlineGrace(
                plan: .annual,
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                validUntil: Date(timeIntervalSince1970: 1_702_592_000)
            )
        )
    }

    private func makeFixture(
        serviceError: LicenseServiceError
    ) throws -> (manager: LicenseManager, store: InMemoryLicenseCredentialStore) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try LicenseTokenVerifier(
            publicKeyData: privateKey.publicKey.rawRepresentation
        )
        let entitlement = try signedEntitlement(privateKey: privateKey)
        let store = InMemoryLicenseCredentialStore(
            installationID: "installation-a",
            deviceCredential: "qcd-test-credential",
            entitlement: entitlement
        )
        let manager = LicenseManager(
            configuration: LicensingConfiguration(
                isEnabled: true,
                apiBaseURL: URL(string: "https://license.example/api/v1/"),
                publicKey: privateKey.publicKey.rawRepresentation,
                purchaseURL: nil
            ),
            service: FailingLicenseService(error: serviceError),
            credentialStore: store,
            installationIDProvider: FixedInstallationIDProvider(
                value: "installation-a"
            ),
            verifier: verifier,
            accessGate: LicenseAccessGate(),
            now: { currentTime },
            deviceName: "Test Mac"
        )
        return (manager, store)
    }

    private func signedEntitlement(
        privateKey: Curve25519.Signing.PrivateKey,
        installationID: String = "installation-a",
        validationDueAt: Int64 = 1_699_999_999,
        deviceCredential: String? = nil
    ) throws -> SignedLicenseEntitlement {
        let payload = LicenseEntitlementPayload(
            version: 1,
            entitlementID: "license-1",
            kind: .paid,
            plan: .annual,
            installationID: installationID,
            issuedAt: 1_699_000_000,
            expiresAt: 1_800_000_000,
            validationDueAt: validationDueAt,
            offlineValidUntil: 1_702_592_000,
            maximumActivations: 2
        )
        let data = try JSONEncoder().encode(payload)
        return SignedLicenseEntitlement(
            payload: base64URL(data),
            signature: base64URL(try privateKey.signature(for: data)),
            deviceCredential: deviceCredential
        )
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct FixedInstallationIDProvider: InstallationIDProviding {
    let value: String?

    func installationID() -> String? { value }
}

private actor FailingLicenseService: LicenseServiceClient {
    let error: LicenseServiceError

    init(error: LicenseServiceError) {
        self.error = error
    }

    func startTrial(
        installationID: String,
        deviceName: String
    ) async throws -> SignedLicenseEntitlement {
        throw error
    }

    func activate(
        licenseKey: String,
        installationID: String,
        deviceName: String
    ) async throws -> SignedLicenseEntitlement {
        throw error
    }

    func validate(
        deviceCredential: String,
        installationID: String
    ) async throws -> SignedLicenseEntitlement {
        throw error
    }

    func deactivate(
        deviceCredential: String,
        installationID: String
    ) async throws {
        throw error
    }
}

private actor RecordingLicenseService: LicenseServiceClient {
    private let entitlement: SignedLicenseEntitlement
    private var validations = 0

    init(entitlement: SignedLicenseEntitlement) {
        self.entitlement = entitlement
    }

    func validationCount() -> Int { validations }

    func startTrial(
        installationID: String,
        deviceName: String
    ) async throws -> SignedLicenseEntitlement {
        entitlement
    }

    func activate(
        licenseKey: String,
        installationID: String,
        deviceName: String
    ) async throws -> SignedLicenseEntitlement {
        entitlement
    }

    func validate(
        deviceCredential: String,
        installationID: String
    ) async throws -> SignedLicenseEntitlement {
        validations += 1
        return entitlement
    }

    func deactivate(
        deviceCredential: String,
        installationID: String
    ) async throws {}
}

private actor InMemoryLicenseCredentialStore: LicenseCredentialStore {
    private var storedInstallationID: String?
    private var storedDeviceCredential: String?
    private var storedEntitlement: SignedLicenseEntitlement?
    private var storedLastObservedTime: Date?

    init(
        installationID: String?,
        deviceCredential: String?,
        entitlement: SignedLicenseEntitlement?
    ) {
        storedInstallationID = installationID
        storedDeviceCredential = deviceCredential
        storedEntitlement = entitlement
    }

    func installationID() async throws -> String? { storedInstallationID }

    func saveInstallationID(_ value: String) async throws {
        storedInstallationID = value
    }

    func deviceCredential() async throws -> String? { storedDeviceCredential }

    func saveDeviceCredential(_ value: String) async throws {
        storedDeviceCredential = value
    }

    func signedEntitlement() async throws -> SignedLicenseEntitlement? {
        storedEntitlement
    }

    func saveSignedEntitlement(
        _ value: SignedLicenseEntitlement
    ) async throws {
        storedEntitlement = value
    }

    func lastObservedTime() async throws -> Date? { storedLastObservedTime }

    func saveLastObservedTime(_ value: Date) async throws {
        storedLastObservedTime = value
    }

    func clearPaidLicense() async throws {
        storedDeviceCredential = nil
        storedEntitlement = nil
    }
}
