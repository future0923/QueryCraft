import CloudKit
import Foundation

/// Platform storage behind iCloud sync (desktop SQLite, mobile JSON).
protocol CloudSyncLocalStore: Sendable {
    /// Current local value, or nil when it no longer exists locally.
    func value(for key: CloudSyncKey) async throws -> CloudSyncValue?
    /// Every syncable local item, used for the first upload.
    func allKeys() async throws -> [CloudSyncKey]
    /// Applies changes fetched from iCloud without recording them as local
    /// edits. Saved queries whose connection is missing are returned so they
    /// can be retried after the connection arrives.
    func apply(_ changes: [CloudSyncRemoteChange]) async throws -> [CloudSyncSavedQuery]
}

enum CloudSyncEngineEvent: Sendable {
    case syncing
    case synced(Date)
    case failed(String)
    case accountChanged
    case remoteChangesApplied
}

/// Drives CKSyncEngine against the private database. Conflicts resolve per
/// record by last writer (`modifiedAt`); a local edit made after a remote
/// deletion recreates the item instead of losing it.
actor CloudSyncEngine: CKSyncEngineDelegate {
    static let zoneID = CKRecordZone.ID(zoneName: CloudSyncKey.zoneName)

    private let database: CKDatabase
    private let metadata: CloudSyncMetadataStore
    private let local: any CloudSyncLocalStore
    private let report: @Sendable (CloudSyncEngineEvent) async -> Void
    private var engine: CKSyncEngine?
    /// Outbox version captured when a record was handed to CloudKit.
    private var sentVersions: [String: Int] = [:]

    init(
        database: CKDatabase,
        metadata: CloudSyncMetadataStore,
        local: any CloudSyncLocalStore,
        report: @escaping @Sendable (CloudSyncEngineEvent) async -> Void
    ) {
        self.database = database
        self.metadata = metadata
        self.local = local
        self.report = report
    }

    var isRunning: Bool { engine != nil }

    /// Starts syncing. `initialMerge` uploads every local item that iCloud
    /// does not already have newer data for.
    func start(initialMerge: Bool) async throws {
        guard engine == nil else { return }
        let serialization = try metadata.state(CloudSyncMetadataStore.engineStateKey)
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if serialization == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        if initialMerge {
            // Epoch timestamps make existing iCloud data win over the local
            // copy; real edits recorded meanwhile keep their own time.
            try metadata.enqueue(
                try await local.allKeys(),
                deleted: false,
                changedAt: Date(timeIntervalSince1970: 0),
                replaceExisting: false
            )
        }
        try await synchronize()
    }

    func stop() {
        engine = nil
        sentVersions.removeAll()
    }

    /// Fetches remote changes first, then sends pending local edits.
    func synchronize() async throws {
        guard let engine else { return }
        await report(.syncing)
        do {
            try await engine.fetchChanges()
            await queueLocalChanges()
            try await engine.sendChanges()
            await report(.synced(.now))
        } catch {
            await report(.failed(Self.describe(error)))
            throw error
        }
    }

    /// Hands the outbox to CKSyncEngine; it schedules the upload itself.
    func queueLocalChanges() async {
        guard let engine else { return }
        let entries: [CloudSyncOutboxEntry]
        do { entries = try metadata.outbox() } catch {
            await report(.failed(Self.describe(error)))
            return
        }
        let pending = Set(engine.state.pendingRecordZoneChanges)
        let changes = entries.map { entry -> CKSyncEngine.PendingRecordZoneChange in
            let id = entry.key.recordID(zoneID: Self.zoneID)
            return entry.isDeletion ? .deleteRecord(id) : .saveRecord(id)
        }.filter { !pending.contains($0) }
        if !changes.isEmpty {
            engine.state.add(pendingRecordZoneChanges: changes)
        }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case let .stateUpdate(update):
                try metadata.setState(
                    try JSONEncoder().encode(update.stateSerialization),
                    for: CloudSyncMetadataStore.engineStateKey
                )
            case let .accountChange(change):
                switch change.changeType {
                case .signIn:
                    break
                case .signOut, .switchAccounts:
                    try metadata.resetServerState()
                    engine = nil
                    await report(.accountChanged)
                @unknown default:
                    break
                }
            case let .fetchedDatabaseChanges(changes):
                if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                    // iCloud data was cleared. Keep local data and upload it again.
                    try metadata.resetServerState()
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    try metadata.enqueue(try await local.allKeys(), deleted: false, changedAt: .now, replaceExisting: false)
                    await queueLocalChanges()
                }
            case let .fetchedRecordZoneChanges(changes):
                try await applyFetched(modifications: changes.modifications.map(\.record),
                                       deletions: changes.deletions.compactMap { CloudSyncKey(recordName: $0.recordID.recordName) })
            case let .sentRecordZoneChanges(sent):
                try await handleSent(sent, syncEngine: syncEngine)
            case let .sentDatabaseChanges(sent):
                for failure in sent.failedZoneSaves {
                    await report(.failed(Self.describe(failure.error)))
                }
            case .didFetchChanges, .didSendChanges:
                await report(.synced(.now))
            case .willFetchChanges, .willSendChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
                break
            @unknown default:
                break
            }
        } catch {
            await report(.failed(Self.describe(error)))
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            await self?.outgoingRecord(for: recordID, syncEngine: syncEngine)
        }
    }

    // MARK: Sending

    private func outgoingRecord(for recordID: CKRecord.ID, syncEngine: CKSyncEngine) async -> CKRecord? {
        guard let key = CloudSyncKey(recordName: recordID.recordName) else {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        do {
            let entry = try metadata.outboxEntry(for: key)
            guard let value = try await local.value(for: key) else {
                // Deleted locally after the save was queued; the deletion
                // trigger already queued the matching delete.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            let record = try metadata.systemFieldsRecord(for: key)
                ?? CKRecord(recordType: key.entity.rawValue, recordID: recordID)
            CloudSyncRecordCoder.encode(value, modifiedAt: entry?.changedAt ?? .now, into: record)
            sentVersions[key.recordName] = entry?.version
            return record
        } catch {
            await report(.failed(Self.describe(error)))
            return nil
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) async throws {
        for record in sent.savedRecords {
            guard let key = CloudSyncKey(recordName: record.recordID.recordName) else { continue }
            try metadata.saveSystemFields(of: record)
            try metadata.completeOutbox(key, version: sentVersions.removeValue(forKey: key.recordName))
        }
        for recordID in sent.deletedRecordIDs {
            guard let key = CloudSyncKey(recordName: recordID.recordName) else { continue }
            try metadata.removeSystemFields(for: key)
            try metadata.completeOutbox(key, version: sentVersions.removeValue(forKey: key.recordName))
        }
        for (recordID, error) in sent.failedRecordDeletes {
            guard let key = CloudSyncKey(recordName: recordID.recordName) else { continue }
            if error.code == .unknownItem {
                try metadata.removeSystemFields(for: key)
                try metadata.completeOutbox(key, version: nil)
            } else if !Self.isTransient(error) {
                await report(.failed(Self.describe(error)))
            }
        }
        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            guard let key = CloudSyncKey(recordName: recordID.recordName) else { continue }
            sentVersions.removeValue(forKey: key.recordName)
            switch failure.error.code {
            case .serverRecordChanged:
                guard let serverRecord = failure.error.serverRecord else { continue }
                let localChangedAt = try metadata.outboxEntry(for: key)?.changedAt ?? .distantPast
                try metadata.saveSystemFields(of: serverRecord)
                if localChangedAt > CloudSyncRecordCoder.modifiedAt(of: serverRecord) {
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else {
                    try await applyFetched(modifications: [serverRecord], deletions: [])
                }
            case .zoneNotFound:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                try metadata.removeSystemFields(for: key)
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            case .unknownItem:
                // Deleted on another device, edited here: recreate it.
                try metadata.removeSystemFields(for: key)
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            default:
                if !Self.isTransient(failure.error) {
                    await report(.failed(Self.describe(failure.error)))
                }
            }
        }
    }

    // MARK: Receiving

    private func applyFetched(modifications: [CKRecord], deletions: [CloudSyncKey]) async throws {
        var changes: [CloudSyncRemoteChange] = []
        for record in modifications {
            guard let key = CloudSyncKey(recordName: record.recordID.recordName) else { continue }
            try metadata.saveSystemFields(of: record)
            if let pending = try metadata.outboxEntry(for: key),
               pending.changedAt > CloudSyncRecordCoder.modifiedAt(of: record) {
                continue // the newer local edit is uploaded instead
            }
            guard let value = try? CloudSyncRecordCoder.decode(record) else { continue }
            changes.append(.upsert(value))
        }
        for key in deletions {
            try metadata.removeSystemFields(for: key)
            try metadata.removeDeferred(key)
            if let pending = try metadata.outboxEntry(for: key),
               !pending.isDeletion, pending.changedAt > Date(timeIntervalSince1970: 0) {
                continue // edited here after the other device deleted it
            }
            changes.append(.delete(key))
        }
        guard !changes.isEmpty else { return }
        changes.sort { $0.key.entity.applyOrder < $1.key.entity.applyOrder }
        let deferred = try await local.apply(changes)
        for change in changes {
            try metadata.completeOutbox(change.key, version: nil)
        }
        for query in deferred {
            try metadata.deferSavedQuery(query)
        }
        try await retryDeferred()
        await report(.remoteChangesApplied)
    }

    private func retryDeferred() async throws {
        let waiting = try metadata.deferredSavedQueries()
        guard !waiting.isEmpty else { return }
        let stillWaiting = Set(try await local.apply(waiting.map { .upsert(.savedQuery($0)) }).map(\.id))
        for query in waiting where !stillWaiting.contains(query.id) {
            try metadata.removeDeferred(.init(entity: .savedQuery, id: query.id))
        }
    }

    // MARK: Errors

    private static func isTransient(_ error: CKError) -> Bool {
        switch error.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .operationCancelled, .notAuthenticated, .accountTemporarilyUnavailable:
            true
        default:
            false
        }
    }

    static func describe(_ error: any Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .notAuthenticated:
            return CloudSyncCopy.current.notSignedIn
        case .quotaExceeded:
            return CloudSyncCopy.current.quotaExceeded
        case .networkFailure, .networkUnavailable:
            return CloudSyncCopy.current.networkUnavailable
        default:
            return error.localizedDescription
        }
    }
}
