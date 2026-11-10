import AppKit
import Foundation
import GRDB

extension Notification.Name {
    /// Posted after connections, groups or saved queries changed because of
    /// iCloud sync, so open lists reload from storage.
    static let cloudSyncDidApplyRemoteChanges = Notification.Name("QueryCraftCloudSyncDidApplyRemoteChanges")
}

/// macOS entry point for iCloud sync.
@MainActor
public enum DesktopCloudSync {
    static let controller: CloudSyncController = makeController()

    private static func makeController() -> CloudSyncController {
        let database = SQLiteApplicationDatabase.shared
        return CloudSyncController(
            containerIdentifier: CloudSyncController.bundleContainerIdentifier(),
            defaults: .standard,
            makeMetadata: { try await database.cloudSyncMetadataStore() },
            makeLocal: { metadata in
                let credentials = KeychainCredentialStore(
                    directory: QueryCraftStorageLocation.applicationSupportDirectory,
                    allowsInteraction: true
                )
                return DesktopCloudSyncStore(
                    database: database,
                    metadata: metadata,
                    credentials: credentials,
                    snippets: { SQLSnippetStore.shared }
                )
            },
            hasAccess: { true }
        )
    }

    private static var outboxObservation: AnyDatabaseCancellable?
    private static var activationObserver: NSObjectProtocol?

    public static func start() {
        guard controller.isAvailableInBuild, outboxObservation == nil else { return }
        controller.onRemoteChangesApplied = {
            NotificationCenter.default.post(name: .cloudSyncDidApplyRemoteChanges, object: nil)
        }
        SQLSnippetStore.shared.onLocalChange = { changed, deleted in
            controller.recordLocalChanges(changed.map { .init(entity: .snippet, id: $0) }, deleted: false)
            controller.recordLocalChanges(deleted.map { .init(entity: .snippet, id: $0) }, deleted: true)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { controller.applicationBecameActive() }
        }
        Task {
            if let metadata = try? await SQLiteApplicationDatabase.shared.cloudSyncMetadataStore() {
                // Writes from this process; MCP edits are picked up on the
                // next activation or periodic sync.
                outboxObservation = DatabaseRegionObservation(tracking: Table("cloudSyncOutbox"))
                    .start(in: metadata.writer, onError: { _ in }, onChange: { _ in
                        Task { @MainActor in controller.localDataChanged() }
                    })
            }
            await controller.startIfEnabled()
        }
    }
}
