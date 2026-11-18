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

    /// Legacy signed entitlement validity, not a database feature gate.
    var hasValidEntitlement: Bool {
        switch self {
        case .unrestrictedDevelopment, .trial, .paid, .offlineGrace:
            true
        case .loading, .restricted:
            false
        }
    }

    var cloudSyncGrant: CloudSyncGrant? {
        switch self {
        case let .trial(expiresAt):
            return .init(source: .trial, plan: nil, expiresAt: expiresAt)
        case let .paid(plan, expiresAt, _):
            return .init(source: .directLicense, plan: plan.cloudSyncPlan, expiresAt: expiresAt)
        case let .offlineGrace(plan, expiresAt, validUntil):
            return .init(source: plan == .trial ? .trial : .directLicense,
                         plan: plan.cloudSyncPlan, expiresAt: min(expiresAt ?? validUntil, validUntil))
        case .loading, .restricted, .unrestrictedDevelopment:
            // Disabling the legacy full-app gate is NOT proof of purchase.
            return nil
        }
    }
}

private extension LicensePlan {
    var cloudSyncPlan: CloudSyncPlan? {
        switch self {
        case .monthly: .monthly
        case .halfYear: .halfYear
        case .annual: .annual
        case .perpetual: .perpetual
        case .trial: nil
        }
    }
}
