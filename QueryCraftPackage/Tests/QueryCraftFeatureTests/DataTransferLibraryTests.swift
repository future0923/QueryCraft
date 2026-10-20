import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
struct DataTransferLibraryTests {
    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "tasks.json") }

    @Test("Task save, duplicate, move, reorder, reload and folder deletion preserve exact configuration")
    func library() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DataTransferLibraryStore(url: url), folder = TransferTaskFolder(name: "测试", parentID: nil)
        try store.update { $0.folders.append(folder) }
        var config = DataTransferConfiguration(); config.batchSize = 5000; config.tableFilters = ["a.b": "value='中文'"]
        let id = try store.save(id: nil, name: "task", folderID: folder.id, configuration: config)
        let task = try #require(store.library.tasks.first)
        let duplicate = try store.duplicate(task)
        try store.moveTask(duplicate, folderID: nil, before: id)
        let reloaded = DataTransferLibraryStore(url: url)
        #expect(reloaded.library.tasks.first?.id == duplicate)
        #expect(reloaded.library.tasks.last?.configuration == config)
        try reloaded.deleteFolder(folder.id)
        #expect(reloaded.library.tasks.count == 1)
        #expect(reloaded.library.tasks[0].id == duplicate)
    }

    @Test("Invalid cycles and duplicate names never alter persisted data")
    func validation() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DataTransferLibraryStore(url: url)
        _ = try store.save(id: nil, name: "Task", folderID: nil, configuration: .init())
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { _ = try store.save(id: nil, name: "task", folderID: nil, configuration: .init()) }
        let a = TransferTaskFolder(name: "a", parentID: nil)
        #expect(throws: (any Error).self) { try store.update { library in var cycle = a; cycle.parentID = cycle.id; library.folders.append(cycle) } }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Corrupt libraries are preserved and cannot be overwritten by a new save")
    func corruption() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("invalid original".utf8); try bytes.write(to: url)
        let store = DataTransferLibraryStore(url: url)
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) { _ = try store.save(id: nil, name: "new", folderID: nil, configuration: .init()) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Restart marks unfinished history interrupted without replaying writes")
    func interruptedHistory() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = TransferRunRecord(id: UUID(), name: "test", sourceLabel: "s", targetLabel: "t", createdAt: Date(), status: .running, items: [.init(id: "t", name: "t", status: .running, readRows: 100)])
        try JSONEncoder().encode([record]).write(to: url)
        let manager = DataTransferManager(historyURL: url)
        #expect(manager.runs.first?.status == .interrupted)
        #expect(manager.runs.first?.items.first?.status == .interrupted)
        #expect(!manager.hasActiveRuns)
    }
}
