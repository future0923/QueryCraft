import Testing

@testable import QueryCraftFeature

struct LicenseAccessGateTests {
    @Test
    func permitsDatabaseAccessForEveryLegacyLicenseState() async throws {
        let gate = LicenseAccessGate()
        let states: [LicenseState] = [
            .loading,
            .unrestrictedDevelopment,
            .trial(expiresAt: .distantPast),
            .paid(plan: .annual, expiresAt: .distantPast, maximumActivations: 1),
            .offlineGrace(
                plan: .trial,
                expiresAt: .distantPast,
                validUntil: .distantPast
            ),
            .restricted(.trialExpired),
            .restricted(.licenseExpired),
            .restricted(.serviceUnavailable),
        ]

        for state in states {
            await gate.update(for: state)
            try await gate.requireDatabaseAccess()
        }
    }
}
