import Foundation
import QueryCraftMobileCore
import SwiftUI
import UIKit

/// iPhone and iPad storage for iCloud sync. Connections and saved queries
/// are read and written through the application model so open screens and
/// files stay consistent; snippets use the shared snippet store.
@MainActor
final class MobileCloudSyncStore: CloudSyncLocalStore {
    private weak var model: MobileApplicationModel?
    private let metadata: CloudSyncMetadataStore

    init(model: MobileApplicationModel, metadata: CloudSyncMetadataStore) {
        self.model = model
        self.metadata = metadata
    }

    func value(for key: CloudSyncKey) async throws -> CloudSyncValue? {
        guard let model else { return nil }
        switch key.entity {
        case .connectionGroup:
            return model.library.connectionGroups.first(where: { $0.id == key.id }).map(CloudSyncValue.connectionGroup)
        case .connection:
            guard let profile = model.library.profiles.first(where: { $0.id == key.id }) else { return nil }
            return .connection(Self.connection(from: profile, secret: secret(for: profile, in: model)))
        case .savedQuery:
            for profile in model.library.profiles {
                if let query = model.cloudSavedQueries(profileID: profile.id).first(where: { $0.id == key.id }) {
                    return .savedQuery(.init(id: query.id, connectionID: query.connectionProfileID,
                                             defaultDatabase: query.defaultDatabase, name: query.name, sql: query.sql,
                                             createdAt: query.createdAt, updatedAt: query.updatedAt))
                }
            }
            return nil
        case .snippet:
            return SQLSnippetStore.shared.cloudSyncValue(id: key.id).map(CloudSyncValue.snippet)
        }
    }

    func allKeys() async throws -> [CloudSyncKey] {
        guard let model else { return [] }
        let profiles = model.library.profiles
        let connections = profiles.map { CloudSyncKey(entity: .connection, id: $0.id) }
        let queries = profiles.flatMap { model.cloudSavedQueries(profileID: $0.id) }
            .map { CloudSyncKey(entity: .savedQuery, id: $0.id) }
        let snippets = SQLSnippetStore.shared.snippets.map { CloudSyncKey(entity: .snippet, id: $0.id) }
        return connections + queries + snippets
    }

    func apply(_ changes: [CloudSyncRemoteChange]) async throws -> [CloudSyncSavedQuery] {
        guard let model else { return [] }
        var connections: [CloudSyncConnection] = []
        var groups: [CloudSyncConnectionGroup] = []
        var deletedGroups = Set<UUID>()
        var deletedConnections = Set<UUID>()
        var queries: [SavedQuery] = []
        var deletedQueries = Set<UUID>()
        var snippets: [CloudSyncSnippet] = []
        var deletedSnippets: [UUID] = []
        for change in changes {
            switch change {
            case let .upsert(.connection(value)): connections.append(value)
            case let .upsert(.savedQuery(value)):
                queries.append(SavedQuery(id: value.id, connectionProfileID: value.connectionID,
                                          defaultDatabase: value.defaultDatabase, name: value.name, sql: value.sql,
                                          createdAt: value.createdAt, updatedAt: value.updatedAt))
            case let .upsert(.snippet(value)): snippets.append(value)
            case let .upsert(.connectionGroup(value)): groups.append(value)
            case let .delete(key):
                switch key.entity {
                case .connection: deletedConnections.insert(key.id)
                case .savedQuery: deletedQueries.insert(key.id)
                case .snippet: deletedSnippets.append(key.id)
                case .connectionGroup: deletedGroups.insert(key.id)
                }
            }
        }
        try model.applyCloudConnectionGroups(groups, deletions: deletedGroups)
        try model.applyCloudConnections(connections, deletions: deletedConnections)
        let waiting = try model.applyCloudSavedQueries(queries, deletions: deletedQueries)
        if !snippets.isEmpty || !deletedSnippets.isEmpty {
            let followUp = SQLSnippetStore.shared.applyRemoteChanges(upserts: snippets, deletions: deletedSnippets)
            try metadata.enqueue(followUp.changed.map { .init(entity: .snippet, id: $0) }, deleted: false)
            try metadata.enqueue(followUp.deleted.map { .init(entity: .snippet, id: $0) }, deleted: true)
        }
        return waiting.map {
            .init(id: $0.id, connectionID: $0.connectionProfileID, defaultDatabase: $0.defaultDatabase,
                  name: $0.name, sql: $0.sql, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
    }

    static func connection(from profile: MobileConnectionProfile, secret: CloudSyncSecret) -> CloudSyncConnection {
        let stores = profile.remembersPassword && profile.authentication != .none
        return CloudSyncConnection(
            id: profile.id, name: profile.name, databaseType: profile.driver.rawValue,
            host: profile.host, port: profile.port, username: profile.username,
            authenticationMethod: profile.authentication.rawValue,
            defaultDatabase: profile.database.isEmpty ? nil : profile.database,
            tlsMode: profile.tlsMode.rawValue, storesCredential: stores,
            secret: stores ? secret : .none,
            desktop: nil,
            mobile: .init(schemaName: profile.schemaName)
        )
    }

    private func secret(for profile: MobileConnectionProfile, in model: MobileApplicationModel) -> CloudSyncSecret {
        guard profile.remembersPassword, profile.authentication != .none else { return .none }
        do {
            guard let password = try model.passwords.password(for: profile.id), !password.isEmpty else { return .none }
            return .value(password)
        } catch {
            return .unavailable
        }
    }
}

/// iPhone and iPad entry point for iCloud sync.
@MainActor
enum MobileCloudSync {
    private(set) static var controller: CloudSyncController?
    private static var activationObserver: NSObjectProtocol?

    static func start(model: MobileApplicationModel) {
        guard controller == nil else { return }
        let metadataURL = URL.applicationSupportDirectory
            .appending(path: "QueryCraftMobile", directoryHint: .isDirectory)
            .appending(path: "CloudSync.sqlite")
        let created = CloudSyncController(
            containerIdentifier: CloudSyncController.bundleContainerIdentifier(),
            defaults: .standard,
            makeMetadata: {
                let metadata = try CloudSyncMetadataStore.standalone(at: metadataURL)
                try prepareConnectionGroups(in: metadata)
                return metadata
            },
            makeLocal: { [weak model] metadata in
                guard let model else { return EmptyCloudSyncStore() }
                return MobileCloudSyncStore(model: model, metadata: metadata)
            },
            hasAccess: { await CloudSyncBilling.shared.checkAccess() }
        )
        controller = created
        guard created.isAvailableInBuild else { return }
        model.localChangesDidOccur = { keys, deleted in
            created.recordLocalChanges(keys, deleted: deleted)
        }
        SQLSnippetStore.shared.onLocalChange = { changed, deleted in
            created.recordLocalChanges(changed.map { .init(entity: .snippet, id: $0) }, deleted: false)
            created.recordLocalChanges(deleted.map { .init(entity: .snippet, id: $0) }, deleted: true)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { created.applicationBecameActive() }
        }
        // CKSyncEngine reacts to CloudKit pushes on its own once registered.
        UIApplication.shared.registerForRemoteNotifications()
        Task { await created.startIfEnabled() }
    }

    /// Earlier mobile builds consumed group records without storing them.
    /// Re-fetch once after upgrading, preserving local data and pending edits.
    nonisolated static func prepareConnectionGroups(in metadata: CloudSyncMetadataStore) throws {
        let migrationKey = "mobileConnectionGroups.v1"
        guard try metadata.state(migrationKey) == nil else { return }
        try metadata.setState(nil, for: CloudSyncMetadataStore.engineStateKey)
        try metadata.setState(Data([1]), for: migrationKey)
    }
}

private struct EmptyCloudSyncStore: CloudSyncLocalStore {
    func value(for key: CloudSyncKey) async throws -> CloudSyncValue? { nil }
    func allKeys() async throws -> [CloudSyncKey] { [] }
    func apply(_ changes: [CloudSyncRemoteChange]) async throws -> [CloudSyncSavedQuery] {
        throw CancellationError()
    }
}

/// Settings screen for iCloud sync on iPhone and iPad.
struct MobileCloudSyncSettingsView: View {
    let controller: CloudSyncController
    @State private var isChanging = false
    private var copy: CloudSyncCopy { .current }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { controller.isEnabled },
                    set: { enabled in
                        isChanging = true
                        Task { await controller.setEnabled(enabled); isChanging = false }
                    }
                )) {
                    Label(copy.toggle, systemImage: "icloud")
                }
                .tint(.green)
                .disabled(!controller.isAvailableInBuild || isChanging)
                if showsStatus {
                    LabeledContent("状态") { status.fixedSize(horizontal: false, vertical: true) }
                }
            } footer: {
                Text(controller.isEnabled ? "\(copy.syncOverview)\n\(copy.localDataKept)" : copy.syncOverview)
            }
            CloudSyncPurchaseSection(billing: .shared, onAccessChanged: { controller.applicationBecameActive() })
        }
        .mobileSettingsCanvas()
        .navigationTitle(copy.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(copy.syncNow, systemImage: "arrow.triangle.2.circlepath") {
                    Task { await controller.syncNow() }
                }
                .disabled(!controller.isEnabled || controller.status == .syncing || isChanging)
            }
        }
    }

    /// The switch already says "off"; only show a status row when it adds information.
    private var showsStatus: Bool {
        if controller.isEnabled { return true }
        if case .off = controller.status { return false }
        return true
    }

    @ViewBuilder
    private var status: some View {
        switch controller.status {
        case .off:
            Text(controller.isEnabled ? copy.waiting : copy.off).foregroundStyle(.secondary)
        case let .unavailable(message):
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        case .syncing:
            HStack(spacing: 6) { ProgressView(); Text(copy.syncing) }
        case let .synced(date):
            Text(copy.lastSynced(date)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        case let .failed(message):
            Text(message).foregroundStyle(.orange).multilineTextAlignment(.trailing)
        }
    }
}
