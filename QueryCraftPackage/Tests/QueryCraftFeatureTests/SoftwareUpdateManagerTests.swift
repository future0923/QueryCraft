import Testing
@testable import QueryCraftFeature

@MainActor
struct SoftwareUpdateManagerTests {
    @Test func storeHostHasNoExternalUpdaterWithoutAnAdapter() {
        let manager = SoftwareUpdateManager()
        manager.checkForUpdates()
        manager.setAutomaticallyChecksForUpdates(true)
        #expect(!manager.isAvailable)
        #expect(!manager.canCheckForUpdates)
    }

    @Test func directHostStartsOnceAndRespectsBackendAvailability() {
        let manager = SoftwareUpdateManager()
        let backend = UpdateBackend()
        manager.start(using: backend)
        manager.start(using: backend)
        #expect(backend.starts == 1)
        #expect(manager.isAvailable)
        manager.checkForUpdates()
        #expect(backend.checks == 0)
        backend.availabilityChanged?(true)
        manager.checkForUpdates()
        #expect(backend.checks == 1)
        manager.setAutomaticallyChecksForUpdates(false)
        #expect(backend.automatic == false)
        backend.availabilityChanged?(false)
        #expect(!manager.canCheckForUpdates)
    }
}

@MainActor
private final class UpdateBackend: SoftwareUpdateBackend {
    var starts = 0
    var checks = 0
    var automatic = false
    var availabilityChanged: (@MainActor (Bool) -> Void)?
    func start(automaticallyChecks: Bool, availabilityChanged: @escaping @MainActor (Bool) -> Void) {
        starts += 1
        automatic = automaticallyChecks
        self.availabilityChanged = availabilityChanged
        availabilityChanged(false)
    }
    func checkForUpdates() { checks += 1 }
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) { automatic = enabled }
}
