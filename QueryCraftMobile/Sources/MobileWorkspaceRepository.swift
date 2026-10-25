import Foundation
import Observation
import QueryCraftMobileCore

/// The desktop's restoration metadata and recoverable SQL are intentionally
/// separate. Credentials, results, pending mutations and server transactions
/// never enter the restoration archive.
struct MobileDocumentRestoration: Codable, Equatable {
    let metadata: WorkspaceQueryDocumentRestorationState
    let draft: RecoverableDraft
    let schemaName: String?
    let selectionLocation: Int
    let selectionLength: Int
    var needsWriteVerification: Bool? = nil
}

struct MobileWorkspaceArchive: Codable {
    var version = 1
    let profileID: UUID
    var selectedDocumentID: UUID?
    var documents: [MobileDocumentRestoration] = []
    var savedQueries: [SavedQuery] = []
    var browser: MobileBrowserRestoration? = nil
    var navigationMode: String? = nil
    var backupFilename: String? = nil
}

@MainActor
protocol MobileWorkspacePersisting {
    func load(profileID: UUID) throws -> MobileWorkspaceArchive?
    func write(_ archive: MobileWorkspaceArchive) throws
    func remove(profileID: UUID) throws
    func backupOriginal(profileID: UUID) throws -> URL
    func backupURL(profileID: UUID, filename: String) -> URL?
}

extension MobileWorkspacePersisting {
    func backupOriginal(profileID: UUID) throws -> URL { throw CocoaError(.featureUnsupported) }
    func backupURL(profileID: UUID, filename: String) -> URL? { nil }
}

@MainActor
struct MobileWorkspaceRepository: MobileWorkspacePersisting {
    let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "QueryCraftMobile/Workspaces", directoryHint: .isDirectory)) {
        self.directory = directory
    }
    private func file(_ id: UUID) -> URL { directory.appending(path: id.uuidString + ".json") }
    func load(profileID: UUID) throws -> MobileWorkspaceArchive? {
        let url = file(profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16_777_217) ?? Data()
        guard data.count <= 16_777_216 else { throw Failure.invalidArchive }
        let archive = try JSONDecoder().decode(MobileWorkspaceArchive.self, from: data)
        try Self.validate(archive, profileID: profileID)
        return archive
    }
    func write(_ archive: MobileWorkspaceArchive) throws {
        try Self.validate(archive, profileID: archive.profileID)
        let data = try JSONEncoder().encode(archive)
        guard data.count <= 16_777_216 else { throw Failure.invalidArchive }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(archive.profileID), options: [.atomic, .completeFileProtection])
    }
    func remove(profileID: UUID) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let prefix = profileID.uuidString
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent == prefix + ".json"
            || (url.lastPathComponent.hasPrefix(prefix + ".backup-") && url.pathExtension == "json") {
            try FileManager.default.removeItem(at: url)
        }
    }
    func backupOriginal(profileID: UUID) throws -> URL {
        let backup = directory.appending(path: profileID.uuidString + ".backup-" + UUID().uuidString + ".json")
        try FileManager.default.copyItem(at: file(profileID), to: backup)
        return backup
    }
    func backupURL(profileID: UUID, filename: String) -> URL? {
        guard filename.hasPrefix(profileID.uuidString + ".backup-"), filename.hasSuffix(".json"),
              URL(fileURLWithPath: filename).lastPathComponent == filename else { return nil }
        let url = directory.appending(path: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private static func validate(_ archive: MobileWorkspaceArchive, profileID: UUID) throws {
        guard archive.version == 1, archive.profileID == profileID,
              Set(archive.documents.map { $0.metadata.id }).count == archive.documents.count,
              Set(archive.savedQueries.map(\.id)).count == archive.savedQueries.count,
              archive.documents.allSatisfy({ item in
                  item.metadata.id == item.draft.id && item.draft.connectionProfileID == profileID
                      && item.draft.sql.utf8.count <= 262_144 && item.selectionLocation >= 0 && item.selectionLength >= 0
              }), archive.savedQueries.allSatisfy({ $0.connectionProfileID == profileID && $0.sql.utf8.count <= 262_144 }) else {
            throw Failure.invalidArchive
        }
    }
    enum Failure: LocalizedError {
        case invalidArchive
        var errorDescription: String? { "工作区文件无效或超过限制。原文件已保留，请检查后重试；不会用空工作区覆盖。" }
    }
}

@MainActor @Observable
final class MobileSQLDocument: Identifiable {
    let id: UUID
    var title: String
    let query: MobileQueryModel
    var savedQueryID: UUID?
    var persistedSQL: String
    var persistedDatabase: String?
    var durableWriteFence = false
    let createdAt: Date
    init(id: UUID = UUID(), title: String, query: MobileQueryModel, saved: SavedQuery? = nil, createdAt: Date = .now) {
        self.id = id; self.title = title; self.query = query; self.createdAt = createdAt
        savedQueryID = saved?.id; persistedSQL = saved?.sql ?? ""; persistedDatabase = saved?.defaultDatabase ?? query.database
    }
    var isDirty: Bool { query.sql != persistedSQL || query.database != persistedDatabase }
    var closeSnapshot: WorkspaceQueryDocumentCloseSnapshot { .init(sql: query.sql, databaseName: query.database) }
}


struct MobileBrowserRestoration: Codable {
    let database: String?
    let schema: String?
    let kind: MobileDatabaseObject.Kind
    let object: MobileDatabaseObject?
    let section: String
    let search: String
    let pageSize: Int
    let offset: Int
    let sortColumn: String?
    let ascending: Bool
    let filter: WorkspaceDatabaseDataFilter
    var schemaWasExplicitlySelected: Bool? = nil
}
