import Foundation
import Testing

@testable import QueryCraftFeature

struct LicenseStateResolverTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func resolvesActiveTrial() {
        let state = LicenseStateResolver.resolve(
            payload: payload(
                kind: .trial,
                plan: .trial,
                expiresAt: 1_700_086_400
            ),
            now: now,
            usesOfflineGrace: false
        )

        #expect(
            state == .trial(
                expiresAt: Date(timeIntervalSince1970: 1_700_086_400)
            )
        )
    }

    @Test
    func resolvesPaidAndPerpetualLicenses() {
        let expiring = LicenseStateResolver.resolve(
            payload: payload(
                kind: .paid,
                plan: .annual,
                expiresAt: 1_800_000_000
            ),
            now: now,
            usesOfflineGrace: false
        )
        let perpetual = LicenseStateResolver.resolve(
            payload: payload(
                kind: .paid,
                plan: .perpetual,
                expiresAt: nil
            ),
            now: now,
            usesOfflineGrace: false
        )

        #expect(
            expiring == .paid(
                plan: .annual,
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                maximumActivations: 2
            )
        )
        #expect(
            perpetual == .paid(
                plan: .perpetual,
                expiresAt: nil,
                maximumActivations: 2
            )
        )
    }

    @Test
    func resolvesOfflineGraceBeforeItsBoundary() {
        let state = LicenseStateResolver.resolve(
            payload: payload(
                kind: .paid,
                plan: .monthly,
                expiresAt: 1_800_000_000
            ),
            now: now,
            usesOfflineGrace: true
        )

        #expect(
            state == .offlineGrace(
                plan: .monthly,
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                validUntil: Date(timeIntervalSince1970: 1_702_592_000)
            )
        )
    }

    @Test
    func restrictsExpiredAndStaleEntitlements() {
        let expiredTrial = LicenseStateResolver.resolve(
            payload: payload(
                kind: .trial,
                plan: .trial,
                expiresAt: 1_699_999_999
            ),
            now: now,
            usesOfflineGrace: false
        )
        let staleLicense = LicenseStateResolver.resolve(
            payload: payload(
                kind: .paid,
                plan: .annual,
                expiresAt: 1_800_000_000,
                offlineValidUntil: 1_700_000_000
            ),
            now: now,
            usesOfflineGrace: true
        )

        #expect(expiredTrial == .restricted(.trialExpired))
        #expect(staleLicense == .restricted(.validationRequired))
    }

    private func payload(
        kind: LicenseEntitlementKind,
        plan: LicensePlan,
        expiresAt: Int64?,
        offlineValidUntil: Int64 = 1_702_592_000
    ) -> LicenseEntitlementPayload {
        LicenseEntitlementPayload(
            version: 1,
            entitlementID: "entitlement-1",
            kind: kind,
            plan: plan,
            installationID: "installation-a",
            issuedAt: 1_699_000_000,
            expiresAt: expiresAt,
            validationDueAt: 1_700_604_800,
            offlineValidUntil: offlineValidUntil,
            maximumActivations: 2
        )
    }
}
