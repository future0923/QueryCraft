import CloudKit
import Foundation
import Observation
#if os(macOS)
import Security
#endif

/// Owns the sync on/off setting, status and scheduling for one app. The
/// platform supplies its local store; everything else is shared by macOS,
/// iPhone and iPad.
@MainActor
@Observable
final class CloudSyncController {
    enum Status: Equatable {
        case off
        case unavailable(String)
        case syncing
        case synced(Date)
        case failed(String)
    }

    /// Info.plist key naming the iCloud container. Builds without the iCloud
    /// entitlement omit it, and sync stays unavailable instead of crashing.
    nonisolated static let containerInfoKey = "QCCloudSyncContainer"
    private static let enabledKey = "cloudSync.enabled"
    private static let lastSyncedKey = "cloudSync.lastSyncedAt"

    private(set) var isEnabled: Bool
    private(set) var status: Status
    private(set) var lastSyncedAt: Date?
    let containerIdentifier: String?

    @ObservationIgnored var onRemoteChangesApplied: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeMetadata: @Sendable () async throws -> CloudSyncMetadataStore
    @ObservationIgnored private let makeLocal: @MainActor (CloudSyncMetadataStore) -> any CloudSyncLocalStore
    @ObservationIgnored private let hasAccess: @MainActor () async -> Bool
    @ObservationIgnored private var engine: CloudSyncEngine?
    @ObservationIgnored private var metadata: CloudSyncMetadataStore?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?

    /// The configured container, or nil when this build cannot use it.
    /// Creating a CKContainer without the matching entitlement terminates
    /// the app, so macOS also checks the running signature (local Dev and
    /// ad-hoc builds are not entitled).
    nonisolated static func bundleContainerIdentifier() -> String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: containerInfoKey) as? String,
              !identifier.isEmpty
        else { return nil }
        #if os(macOS)
        guard entitledContainers().contains(identifier) else { return nil }
        #endif
        return identifier
    }

    #if os(macOS)
    private nonisolated static func entitledContainers() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return [] }
        return value as? [String] ?? []
    }
    #endif

    init(
        containerIdentifier: String?,
        defaults: UserDefaults,
        makeMetadata: @escaping @Sendable () async throws -> CloudSyncMetadataStore,
        makeLocal: @escaping @MainActor (CloudSyncMetadataStore) -> any CloudSyncLocalStore,
        hasAccess: @escaping @MainActor () async -> Bool
    ) {
        self.containerIdentifier = containerIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        self.defaults = defaults
        self.makeMetadata = makeMetadata
        self.makeLocal = makeLocal
        self.hasAccess = hasAccess
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        lastSyncedAt = defaults.object(forKey: Self.lastSyncedKey) as? Date
        status = .off
        if self.containerIdentifier == nil {
            status = .unavailable(CloudSyncCopy.current.unavailableInBuild)
        }
    }

    var isAvailableInBuild: Bool { containerIdentifier != nil }

    /// Call once at launch.
    func startIfEnabled() async {
        guard isEnabled else { return }
        await start()
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        if enabled {
            guard isAvailableInBuild else { return }
            guard await hasAccess() else {
                status = .unavailable(CloudSyncCopy.current.requiresPurchase)
                return
            }
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
            await start()
        } else {
            await turnOff(message: nil)
        }
    }

    func syncNow() async {
        guard isEnabled, let engine else {
            await startIfEnabled()
            return
        }
        try? await engine.synchronize()
    }

    /// Records local edits that are not tracked by database triggers.
    func recordLocalChanges(_ keys: [CloudSyncKey], deleted: Bool) {
        guard !keys.isEmpty else { return }
        Task {
            do {
                let metadata = try await resolvedMetadata()
                try metadata.enqueue(keys, deleted: deleted)
                localDataChanged()
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Debounces uploads after local edits.
    func localDataChanged() {
        guard isEnabled, let engine else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await engine.queueLocalChanges()
            try? await engine.synchronize()
        }
    }

    func applicationBecameActive() {
        guard isEnabled, let engine else { return }
        Task { try? await engine.synchronize() }
    }

    // MARK: Private

    private func resolvedMetadata() async throws -> CloudSyncMetadataStore {
        if let metadata { return metadata }
        let created = try await makeMetadata()
        metadata = created
        return created
    }

    private func start() async {
        guard engine == nil, let containerIdentifier else { return }
        guard await hasAccess() else {
            await turnOff(message: CloudSyncCopy.current.requiresPurchase)
            return
        }
        status = .syncing
        let container = CKContainer(identifier: containerIdentifier)
        do {
            guard try await container.accountStatus() == .available else {
                status = .unavailable(CloudSyncCopy.current.notSignedIn)
                return
            }
            let metadata = try await resolvedMetadata()
            let isFirstSync = try metadata.state(CloudSyncMetadataStore.engineStateKey) == nil
            let engine = CloudSyncEngine(
                database: container.privateCloudDatabase,
                metadata: metadata,
                local: makeLocal(metadata),
                report: { [weak self] event in await self?.handle(event) }
            )
            self.engine = engine
            schedulePeriodicSync()
            try await engine.start(initialMerge: isFirstSync)
        } catch {
            status = .failed(CloudSyncEngine.describe(error))
        }
    }

    private func turnOff(message: String?) async {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        pushTask?.cancel()
        periodicTask?.cancel()
        await engine?.stop()
        engine = nil
        // The next start merges with iCloud from scratch; local data stays.
        try? await resolvedMetadata().resetServerState()
        status = message.map(Status.unavailable) ?? .off
    }

    private func schedulePeriodicSync() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard let self, !Task.isCancelled else { return }
                if !(await self.hasAccess()) {
                    await self.turnOff(message: CloudSyncCopy.current.requiresPurchase)
                    return
                }
                await self.syncNow()
            }
        }
    }

    private func handle(_ event: CloudSyncEngineEvent) async {
        switch event {
        case .syncing:
            if case .synced = status {} else { status = .syncing }
        case let .synced(date):
            lastSyncedAt = date
            defaults.set(date, forKey: Self.lastSyncedKey)
            status = .synced(date)
        case let .failed(message):
            status = .failed(message)
        case .accountChanged:
            await turnOff(message: CloudSyncCopy.current.accountChanged)
        case .remoteChangesApplied:
            onRemoteChangesApplied?()
        }
    }
}
