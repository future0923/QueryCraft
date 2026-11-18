#if !QUERYCRAFT_APP_STORE
import AppKit
import Combine
import QueryCraftFeature
import Sparkle

@MainActor
final class SparkleSoftwareUpdateBackend: SoftwareUpdateBackend {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var availability: AnyCancellable?

    func start(automaticallyChecks: Bool, availabilityChanged: @escaping @MainActor (Bool) -> Void) {
        controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        availability = controller.updater.publisher(for: \.canCheckForUpdates).sink { available in
            MainActor.assumeIsolated { availabilityChanged(available) }
        }
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        #if !DEBUG
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        #endif
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
#endif
