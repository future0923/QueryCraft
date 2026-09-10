import Foundation

enum LicensePlan: String, Codable, Sendable {
    case trial
    case monthly
    case halfYear = "half_year"
    case annual
    case perpetual
}

enum LicenseEntitlementKind: String, Codable, Sendable {
    case trial
    case paid
}

struct LicenseEntitlementPayload: Codable, Equatable, Sendable {
    let version: Int
    let entitlementID: String
    let kind: LicenseEntitlementKind
    let plan: LicensePlan
    let installationID: String
    let issuedAt: Int64
    let expiresAt: Int64?
    let validationDueAt: Int64
    let offlineValidUntil: Int64
    let maximumActivations: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case entitlementID = "entitlementId"
        case kind
        case plan
        case installationID = "installationId"
        case issuedAt
        case expiresAt
        case validationDueAt
        case offlineValidUntil
        case maximumActivations
    }
}

struct SignedLicenseEntitlement: Codable, Equatable, Sendable {
    let payload: String
    let signature: String
    let deviceCredential: String?

    init(
        payload: String,
        signature: String,
        deviceCredential: String? = nil
    ) {
        self.payload = payload
        self.signature = signature
        self.deviceCredential = deviceCredential
    }
}
