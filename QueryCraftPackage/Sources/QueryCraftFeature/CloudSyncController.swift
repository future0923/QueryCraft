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
    @ObservationIgnored private let hasAccess: @MainActor @Sendable () async -> Bool
    @ObservationIgnored private var engine: (any CloudSyncEngineRunning)?
    @ObservationIgnored private var metadata: CloudSyncMetadataStore?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var activationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let accountAvailable: @Sendable (String) async throws -> Bool
    @ObservationIgnored private let makeEngine: @Sendable (CloudSyncEngineDependencies) -> any CloudSyncEngineRunning

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
        hasAccess: @escaping @MainActor @Sendable () async -> Bool,
        accountAvailable: @escaping @Sendable (String) async throws -> Bool = {
            try await CKContainer(identifier: $0).accountStatus() == .available
        },
        makeEngine: @escaping @Sendable (CloudSyncEngineDependencies) -> any CloudSyncEngineRunning = { input in
            CloudSyncEngine(database: CKContainer(identifier: input.containerIdentifier).privateCloudDatabase,
                            metadata: input.metadata, local: input.local,
                            report: input.report, hasAccess: input.hasAccess,
                            automaticallySync: CloudSyncBillingMode.configured() == .preview)
        }
    ) {
        self.containerIdentifier = containerIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        self.defaults = defaults
        self.makeMetadata = makeMetadata
        self.makeLocal = makeLocal
        self.hasAccess = hasAccess
        self.accountAvailable = accountAvailable
        self.makeEngine = makeEngine
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        lastSyncedAt = defaults.object(forKey: Self.lastSyncedKey) as? Date
        status = .off
        if self.containerIdentifier == nil {
            status = .unavailable(CloudSyncCopy.current.unavailableInBuild)
        }
    }

    isolated deinit {
        pushTask?.cancel()
        periodicTask?.cancel()
        startTask?.cancel()
        activationTask?.cancel()
    }

    var isAvailableInBuild: Bool { containerIdentifier != nil }

    /// Call once at launch.
    func startIfEnabled() async {
        guard isEnabled else { return }
        schedulePeriodicSyncIfNeeded()
        await start()
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        if enabled {
            guard isAvailableInBuild else { return }
            generation += 1
            let current = generation
            guard await hasAccess() else {
                if current == generation { status = .unavailable(CloudSyncCopy.current.requiresPurchase) }
                return
            }
            guard current == generation, !Task.isCancelled else { return }
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
            await startIfEnabled()
        } else {
            await turnOff(message: nil)
        }
    }

    func syncNow() async {
        guard isEnabled else { return }
        let current = generation
        let allowed = await hasAccess()
        guard current == generation, isEnabled, !Task.isCancelled else { return }
        guard allowed else { await suspendForAccess(); return }
        guard let engine else { await startIfEnabled(); return }
        do { try await engine.synchronize() }
        catch is CancellationError { return }
        catch {
            if current == generation { status = .failed(CloudSyncEngine.describe(error)) }
        }
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

    /// Debounces uploads after local edits, including edits queued while
    /// access is paused. Every entry point uses the same authorization check.
    func localDataChanged() {
        guard isEnabled else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            await self?.syncNow()
        }
    }

    func applicationBecameActive() {
        guard isEnabled, activationTask == nil else { return }
        activationTask = Task { [weak self] in
            await self?.syncNow()
            self?.activationTask = nil
        }
    }

    // MARK: Private

    private func resolvedMetadata() async throws -> CloudSyncMetadataStore {
        if let metadata { return metadata }
        let created = try await makeMetadata()
        metadata = created
        return created
    }

    private func start() async {
        guard engine == nil, let containerIdentifier, isEnabled else { return }
        if let startTask { await startTask.value; return }
        let current = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStart(containerIdentifier: containerIdentifier, generation: current)
        }
        startTask = task
        await task.value
        if generation == current { startTask = nil }
    }

    private func performStart(containerIdentifier: String, generation current: Int) async {
        do {
            let allowed = await hasAccess()
            guard current == generation, isEnabled, !Task.isCancelled else { return }
            guard allowed else {
                status = .unavailable(CloudSyncCopy.current.requiresPurchase)
                return
            }
            let available = try await accountAvailable(containerIdentifier)
            guard current == generation, isEnabled, !Task.isCancelled else { return }
            guard available else {
                status = .unavailable(CloudSyncCopy.current.notSignedIn)
                return
            }
            let metadata = try await resolvedMetadata()
            guard current == generation, isEnabled, !Task.isCancelled else { return }
            let isFirstSync = try metadata.state(CloudSyncMetadataStore.engineStateKey) == nil
            let engine = makeEngine(.init(
                containerIdentifier: containerIdentifier, metadata: metadata, local: makeLocal(metadata),
                report: { [weak self] event in await self?.handle(event, generation: current) },
                hasAccess: hasAccess
            ))
            self.engine = engine
            status = .syncing
            try await engine.start(initialMerge: isFirstSync)
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            let previous = engine
            engine = nil
            await previous?.stop()
            if current == generation { status = .failed(CloudSyncEngine.describe(error)) }
        }
    }

    private func suspendForAccess() async {
        generation += 1
        let current = generation
        startTask?.cancel()
        startTask = nil
        let previous = engine
        engine = nil
        status = .unavailable(CloudSyncCopy.current.requiresPurchase)
        await previous?.stop()
        guard current == generation else { return }
        // Keep the user's setting, outbox, server cursor and local data. A
        // later purchase/renewal can resume without losing offline edits.
    }

    private func turnOff(message: String?) async {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        generation += 1
        pushTask?.cancel()
        periodicTask?.cancel()
        periodicTask = nil
        startTask?.cancel()
        startTask = nil
        activationTask?.cancel()
        activationTask = nil
        let previous = engine
        engine = nil
        status = message.map(Status.unavailable) ?? .off
        await previous?.stop()
        // Preserve pending writes/deletions and server history. Disabling
        // sync must never discard changes made offline.
    }

    private func schedulePeriodicSyncIfNeeded() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(600)) }
                catch { return }
                guard let self, self.isEnabled else { return }
                await self.syncNow()
            }
        }
    }

    private func handle(_ event: CloudSyncEngineEvent, generation current: Int) async {
        guard current == generation, isEnabled else { return }
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

struct CloudSyncEngineDependencies: Sendable {
    let containerIdentifier: String
    let metadata: CloudSyncMetadataStore
    let local: any CloudSyncLocalStore
    let report: @Sendable (CloudSyncEngineEvent) async -> Void
    let hasAccess: @Sendable () async -> Bool
}
