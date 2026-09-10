import CryptoKit
import Foundation

enum LicenseTokenVerificationError: Error, Equatable {
    case invalidEncoding
    case invalidPublicKey
    case invalidSignature
    case unsupportedVersion
    case installationMismatch
}

struct LicenseTokenVerifier: Sendable {
    private let publicKey: Curve25519.Signing.PublicKey

    init(publicKeyData: Data) throws {
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
            )
        } catch {
            throw LicenseTokenVerificationError.invalidPublicKey
        }
    }

    func verify(
        _ entitlement: SignedLicenseEntitlement,
        installationID: String
    ) throws -> LicenseEntitlementPayload {
        guard
            let payloadData = Data(base64URLEncoded: entitlement.payload),
            let signatureData = Data(base64URLEncoded: entitlement.signature)
        else {
            throw LicenseTokenVerificationError.invalidEncoding
        }
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw LicenseTokenVerificationError.invalidSignature
        }
        let payload: LicenseEntitlementPayload
        do {
            payload = try JSONDecoder().decode(
                LicenseEntitlementPayload.self,
                from: payloadData
            )
        } catch {
            throw LicenseTokenVerificationError.invalidEncoding
        }
        guard payload.version == 1 else {
            throw LicenseTokenVerificationError.unsupportedVersion
        }
        guard payload.installationID == installationID else {
            throw LicenseTokenVerificationError.installationMismatch
        }
        return payload
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }
}
