import Foundation

enum LicenseRestrictionReason: Equatable, Sendable {
    case trialExpired
    case licenseExpired
    case licenseSuspended
    case activationMissing
    case validationRequired
    case configurationInvalid
    case serviceUnavailable
}

enum LicenseState: Equatable, Sendable {
    case loading
    case unrestrictedDevelopment
    case trial(expiresAt: Date)
    case paid(
        plan: LicensePlan,
        expiresAt: Date?,
        maximumActivations: Int
    )
    case offlineGrace(
        plan: LicensePlan,
        expiresAt: Date?,
        validUntil: Date
    )
    case restricted(LicenseRestrictionReason)

    var permitsDatabaseAccess: Bool {
        switch self {
        case .unrestrictedDevelopment, .trial, .paid, .offlineGrace:
            true
        case .loading, .restricted:
            false
        }
    }
}
