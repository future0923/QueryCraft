import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor struct MobilePersistentWorkspaceTests {
    private func make(_ profile: MobileConnectionProfile, repository: any MobileWorkspacePersisting) -> MobileDatabaseWorkspace {
        .init(profile: profile, password: "never-store-this-password", service: MobileMySQLService(), workspaceRepository: repository)
    }
    @Test func multipleDocumentsSavedQueriesSelectionsAndSchemaRestoreWithoutResultsOrCredentials() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = MobileWorkspaceRepository(directory: directory), profile = MobileDriverSupportTests.profile(.mysql)
        let first = make(profile, repository: repository)
        let original = try #require(first.activeDocument)
        original.query.sql = "SELECT '雪😀', NULL"; first.renameDocument(original.id, title: "first")
        first.saveDocument(original.id)
        let second = try #require(first.newDocument())
        second.query.sql = "SELECT 9007199254740993"; second.query.database = "different"
        second.query.schemaName = "schema.with.dot"; second.query.executionInput.selection = .init(location: 7, length: 4)
        #expect(first.persistWorkspace())
        let bytes = try Data(contentsOf: directory.appending(path: profile.id.uuidString + ".json"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("never-store-this-password"))
        let restored = make(profile, repository: repository)
        #expect(restored.documents.count == 2); #expect(restored.activeDocument?.id == second.id)
        #expect(restored.query.sql == second.query.sql); #expect(restored.query.schemaName == "schema.with.dot")
        #expect(restored.query.executionInput.selection == NSRange(location: 7, length: 4))
        #expect(restored.query.result == nil); #expect(restored.query.transactionState == .disconnected)
        #expect(restored.savedQueries.first?.sql == original.query.sql)
        restored.selectDocument(original.id)
        #expect(restored.query.sql == original.query.sql); #expect(restored.activeDocument?.isDirty == false)
    }
    @Test func staleDiscardCannotLoseNewEditsAndSavedQuerySurvivesClosing() throws {
        let repository = MemoryWorkspaceRepository(), profile = MobileDriverSupportTests.profile(.mysql)
        let workspace = make(profile, repository: repository), document = try #require(workspace.activeDocument)
        document.query.sql = "SELECT 1"; let snapshot = document.closeSnapshot
        document.query.sql = "SELECT 2"
        #expect(!workspace.closeDocument(document.id, discarding: snapshot))
        #expect(workspace.documents.count == 1); #expect(workspace.query.sql == "SELECT 2")
        workspace.saveDocument(document.id)
        #expect(workspace.closeDocument(document.id)); #expect(workspace.documents.count == 1)
        let saved = try #require(workspace.savedQueries.first)
        workspace.openSavedQuery(saved)
        #expect(workspace.activeDocument?.savedQueryID == saved.id); #expect(workspace.query.sql == "SELECT 2")
    }
    @Test func failedPersistenceDoesNotCloseOrMarkSavedAndCorruptFileIsPreserved() throws {
        let repository = MemoryWorkspaceRepository(), workspace = make(MobileDriverSupportTests.profile(.mysql), repository: repository)
        let document = try #require(workspace.activeDocument); document.query.sql = "SELECT 'keep'"
        repository.failWrites = true
        workspace.saveDocument(document.id)
        #expect(document.isDirty); #expect(workspace.savedQueries.isEmpty)
        #expect(!workspace.closeDocument(document.id, discarding: document.closeSnapshot))
        #expect(workspace.activeDocument?.id == document.id)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = MobileDriverSupportTests.profile(.mysql), file = directory.appending(path: profile.id.uuidString + ".json")
        let original = Data("invalid-json".utf8); try original.write(to: file)
        let corrupted = make(profile, repository: MobileWorkspaceRepository(directory: directory))
        corrupted.query.sql = "SELECT 'must not overwrite'"
        #expect(!corrupted.persistWorkspace()); #expect(try Data(contentsOf: file) == original)
        corrupted.recoverArchiveAfterBackup()
        let backup = try #require(corrupted.recoveryBackupURL)
        #expect(try Data(contentsOf: backup) == original); #expect(!corrupted.needsArchiveRecovery)
        let recovered = make(profile, repository: MobileWorkspaceRepository(directory: directory))
        #expect(recovered.query.sql == "SELECT 'must not overwrite'")
        #expect(recovered.recoveryBackupURL == backup)
    }
    @Test func switchingConnectionsRefusesToLoseUnsavedSQLAndHistoryCreatesNewDocument() throws {
        let workspaceRepository = MemoryWorkspaceRepository()
        let app = MobileApplicationModel(repository: LifecycleLibrary(), passwords: LifecyclePasswords(), workspaceRepository: workspaceRepository)
        let first = MobileDriverSupportTests.profile(.mysql), other = MobileDriverSupportTests.profile(.mysql)
        app.open(first, suppliedPassword: "")
        let workspace = try #require(app.workspace), document = try #require(workspace.activeDocument)
        document.query.sql = "SELECT 'keep'"
        workspaceRepository.failWrites = true
        app.open(other, suppliedPassword: "")
        #expect(app.workspace === workspace); #expect(app.message != nil)
        app.showLibrary(); #expect(app.isWorkspacePresented)
        workspaceRepository.failWrites = false
        app.restore(.init(id: UUID(), profileID: first.id, database: "history_db", sql: "SELECT 'history'", date: .now, schemaName: nil))
        #expect(workspace.documents.count == 2); #expect(document.query.sql == "SELECT 'keep'")
        #expect(workspace.query.sql == "SELECT 'history'"); #expect(workspace.query.database == "history_db")
        workspace.cancelAll()
    }
    @Test func deletingWorkspaceRemovesOnlyItsOwnedArchiveAndRecoveryBackups() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = MobileWorkspaceRepository(directory: directory), profile = MobileDriverSupportTests.profile(.mysql)
        let workspace = make(profile, repository: repository)
        #expect(workspace.persistWorkspace())
        let backup = try repository.backupOriginal(profileID: profile.id)
        let other = directory.appending(path: UUID().uuidString + ".json")
        try Data("keep".utf8).write(to: other)
        try repository.remove(profileID: profile.id)
        #expect(try repository.load(profileID: profile.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(try Data(contentsOf: other) == Data("keep".utf8))
    }
    @Test func autosaveDoesNotRetainReleasedWorkspace() throws {
        let repository = MemoryWorkspaceRepository(), profile = MobileDriverSupportTests.profile(.mysql)
        var workspace: MobileDatabaseWorkspace? = make(profile, repository: repository)
        weak var reference = workspace
        workspace?.query.sql = "SELECT 'autosave'"
        workspace = nil
        #expect(reference == nil)
    }
}

@MainActor private final class MemoryWorkspaceRepository: MobileWorkspacePersisting {
    var value: MobileWorkspaceArchive?
    var failWrites = false
    func load(profileID: UUID) throws -> MobileWorkspaceArchive? { value }
    func write(_ archive: MobileWorkspaceArchive) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        value = archive
    }
    func remove(profileID: UUID) throws { value = nil }
}

@MainActor private final class LifecycleLibrary: MobileLibraryPersisting {
    func load() throws -> MobileLibraryState { .init() }
    func write(_ state: MobileLibraryState) throws {}
}
@MainActor private final class LifecyclePasswords: MobilePasswordStoring {
    func password(for id: UUID) throws -> String? { nil }
    func setPassword(_ password: String?, for id: UUID) throws {}
}
