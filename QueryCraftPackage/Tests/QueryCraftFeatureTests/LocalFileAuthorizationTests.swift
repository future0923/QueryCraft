import Foundation
import Testing
@testable import QueryCraftFeature

struct LocalFileAuthorizationTests {
    @Test func writableFolderGrantCanBeReopened() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appending(path: "selected-folder")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = LocalFileAuthorization(directory: root.appending(path: "grants"))
        try store.remember(parent, readOnly: false)
        let access = try LocalFileAuthorization(directory: store.directory).access(path: parent.path, writable: true)
        try withExtendedLifetime(access) {
            try Data("fixture".utf8).write(to: parent.appending(path: "new-file"))
        }
        #expect(FileManager.default.fileExists(atPath: parent.appending(path: "new-file").path))
    }

    @Test func bookmarkSurvivesStoreRecreationAndContainsNoKeyContents() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = root.appending(path: "selected-key")
        let contents = Data("test-secret-material-not-for-bookmark".utf8)
        try contents.write(to: key)
        let directory = root.appending(path: "grants")
        try LocalFileAuthorization(directory: directory).remember(key)
        let lease = try LocalFileAuthorization(directory: directory).access(path: key.path)
        let readBack = try withExtendedLifetime(lease) { try Data(contentsOf: key) }
        #expect(readBack == contents)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let saved = try Data(contentsOf: #require(files.first))
        #expect(saved.range(of: contents) == nil)
        try FileManager.default.removeItem(at: key)
        #expect(throws: LocalFileAuthorization.AccessError.self) {
            try LocalFileAuthorization(directory: directory).access(path: key.path)
        }
    }

    @Test func unreadableAndCorruptGrantsAskForSelectionAgain() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalFileAuthorization(directory: root.appending(path: "grants"))
        #expect(throws: LocalFileAuthorization.AccessError.self) { try store.access(path: root.appending(path: "missing").path) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "config")
        try Data("Host fixture".utf8).write(to: file)
        try store.remember(file)
        let bookmark = try #require(FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).first)
        try Data("corrupt".utf8).write(to: bookmark)
        #expect(throws: LocalFileAuthorization.AccessError.self) { try store.access(path: file.path) }
    }
}
