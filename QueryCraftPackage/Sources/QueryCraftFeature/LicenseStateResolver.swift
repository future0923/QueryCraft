import Foundation

enum LicenseStateResolver {
    static func resolve(
        payload: LicenseEntitlementPayload,
        now: Date,
        usesOfflineGrace: Bool
    ) -> LicenseState {
        let expiresAt = payload.expiresAt.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        if let expiresAt, now >= expiresAt {
            return .restricted(
                payload.kind == .trial ? .trialExpired : .licenseExpired
            )
        }

        let offlineValidUntil = Date(
            timeIntervalSince1970: TimeInterval(payload.offlineValidUntil)
        )
        guard now < offlineValidUntil else {
            return .restricted(.validationRequired)
        }
        if usesOfflineGrace {
            return .offlineGrace(
                plan: payload.plan,
                expiresAt: expiresAt,
                validUntil: offlineValidUntil
            )
        }
        switch payload.kind {
        case .trial:
            guard let expiresAt else {
                return .restricted(.configurationInvalid)
            }
            return .trial(expiresAt: expiresAt)
        case .paid:
            return .paid(
                plan: payload.plan,
                expiresAt: expiresAt,
                maximumActivations: payload.maximumActivations
            )
        }
    }
}
