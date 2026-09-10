import CryptoKit
import Foundation
import Testing

@testable import QueryCraftFeature

struct LicenseTokenVerifierTests {
    @Test
    func verifiesAuthenticEntitlementForInstallation() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try LicenseTokenVerifier(
            publicKeyData: privateKey.publicKey.rawRepresentation
        )
        let entitlement = try signedEntitlement(
            privateKey: privateKey,
            installationID: "installation-a"
        )

        let payload = try verifier.verify(
            entitlement,
            installationID: "installation-a"
        )

        #expect(payload.plan == .annual)
        #expect(payload.entitlementID == "license-1")
    }

    @Test
    func rejectsEntitlementSignedByAnotherKey() throws {
        let trustedKey = Curve25519.Signing.PrivateKey()
        let untrustedKey = Curve25519.Signing.PrivateKey()
        let verifier = try LicenseTokenVerifier(
            publicKeyData: trustedKey.publicKey.rawRepresentation
        )
        let entitlement = try signedEntitlement(
            privateKey: untrustedKey,
            installationID: "installation-a"
        )

        #expect(throws: LicenseTokenVerificationError.invalidSignature) {
            try verifier.verify(
                entitlement,
                installationID: "installation-a"
            )
        }
    }

    @Test
    func rejectsEntitlementCopiedToAnotherInstallation() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try LicenseTokenVerifier(
            publicKeyData: privateKey.publicKey.rawRepresentation
        )
        let entitlement = try signedEntitlement(
            privateKey: privateKey,
            installationID: "installation-a"
        )

        #expect(throws: LicenseTokenVerificationError.installationMismatch) {
            try verifier.verify(
                entitlement,
                installationID: "installation-b"
            )
        }
    }

    private func signedEntitlement(
        privateKey: Curve25519.Signing.PrivateKey,
        installationID: String
    ) throws -> SignedLicenseEntitlement {
        let payload = LicenseEntitlementPayload(
            version: 1,
            entitlementID: "license-1",
            kind: .paid,
            plan: .annual,
            installationID: installationID,
            issuedAt: 1_700_000_000,
            expiresAt: 1_800_000_000,
            validationDueAt: 1_700_604_800,
            offlineValidUntil: 1_702_592_000,
            maximumActivations: 2
        )
        let payloadData = try JSONEncoder().encode(payload)
        let signature = try privateKey.signature(for: payloadData)
        return SignedLicenseEntitlement(
            payload: payloadData.base64URLEncodedString(),
            signature: signature.base64URLEncodedString()
        )
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
