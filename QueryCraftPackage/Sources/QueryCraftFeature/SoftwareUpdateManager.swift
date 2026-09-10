import AppKit
import Combine
import Sparkle

@MainActor
public final class SoftwareUpdateManager: NSObject, ObservableObject {
    public static let shared = SoftwareUpdateManager()

    private let controller: SPUStandardUpdaterController

    @Published public private(set) var canCheckForUpdates = false

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        controller.updater.automaticallyChecksForUpdates =
            ApplicationPreferences.shared.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    public func start() {
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    public func checkForUpdates() {
        #if !DEBUG
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        #endif
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
