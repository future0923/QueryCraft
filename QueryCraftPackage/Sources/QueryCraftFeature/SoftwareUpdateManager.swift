import Combine

/// Supplied only by the directly distributed app. The shared feature framework
/// and Mac App Store app have no dependency on Sparkle or its installer.
@MainActor
public protocol SoftwareUpdateBackend: AnyObject {
    func start(automaticallyChecks: Bool, availabilityChanged: @escaping @MainActor (Bool) -> Void)
    func checkForUpdates()
    func setAutomaticallyChecksForUpdates(_ enabled: Bool)
}

@MainActor
public final class SoftwareUpdateManager: ObservableObject {
    public static let shared = SoftwareUpdateManager()
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var isAvailable = false
    private var backend: (any SoftwareUpdateBackend)?

    init() {}

    public func start(using backend: any SoftwareUpdateBackend) {
        guard self.backend == nil else { return }
        self.backend = backend
        isAvailable = true
        backend.start(automaticallyChecks: ApplicationPreferences.shared.automaticallyChecksForUpdates) { [weak self] available in
            self?.canCheckForUpdates = available
        }
    }

    public func checkForUpdates() {
        guard canCheckForUpdates else { return }
        backend?.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        backend?.setAutomaticallyChecksForUpdates(enabled)
    }
}
