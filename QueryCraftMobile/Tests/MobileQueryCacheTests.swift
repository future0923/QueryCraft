import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

struct MobileQueryCacheTests {
    @Test func largeTextWindowsAndExportBatchesStayBoundedWithoutDroppingRows() async throws {
        let cache = try MobileCachedQueryResult()
        let value = String(repeating: "雪", count: 400_000)
        try await cache.append(.init(columns: [.init(id: 0, name: "long_text")], rows: (0..<8).map { .init(id: $0, values: [.text(value)]) }))
        let first = try await cache.page(offset: 0)
        #expect(first.result.rows.count == 3)
        let next = try await cache.page(offset: first.result.rows.count)
        #expect(next.result.rows.count == 3)
        #expect(cache.store.rowCount == 8); #expect(cache.store.isDiskBacked)
        let source = cache.store.makeDataExportRowSource(rows: .range(0...7), maximumBatchBytes: 4_194_304)
        var counts: [Int] = [], ids: [Int] = []
        while let batch = try await source.nextBatch() { counts.append(batch.count); ids += batch.map(\.id) }
        await source.finish()
        #expect(counts == [3, 3, 2]); #expect(ids == Array(0..<8))
    }

    @Test func encodedCacheBudgetIsSharedAcrossStatements() async throws {
        let budget = MobileSQLCacheBudget()
        try await budget.reserve(MobileSQLCacheBudget.maximumBytes - 100)
        let first = try MobileCachedQueryResult(budget: budget), second = try MobileCachedQueryResult(budget: budget)
        await #expect(throws: MobileSQLSessionError.self) {
            try await first.append(.init(columns: [.init(id: 0, name: "value")], rows: [.init(id: 0, values: [.text(String(repeating: "x", count: 100))])]))
        }
        await #expect(throws: MobileSQLSessionError.self) {
            try await second.append(.init(columns: [.init(id: 0, name: "value")], rows: [.init(id: 0, values: [.text(String(repeating: "x", count: 100))])]))
        }
        #expect(first.store.rowCount == 0); #expect(second.store.rowCount == 0)
    }

    @Test func releasingCacheDeletesSQLiteAndItsSidecars() async throws {
        let root = WorkspaceMobileQueryCacheDirectory.current
        var store: WorkspaceQueryResultStore? = try .init(maximumResidentRowCount: 0)
        try await store?.append([.init(id: 0, values: [.text("cache cleanup")])])
        let file = try #require(store?.diskFileURL)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let created = [file.lastPathComponent, file.lastPathComponent + "-wal", file.lastPathComponent + "-shm"]
        #expect(!created.isEmpty)
        weak var reference = store
        store = nil
        let deadline = ContinuousClock.now + .seconds(5)
        while reference != nil || created.contains(where: { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reference == nil)
        #expect(!created.contains { FileManager.default.fileExists(atPath: root.appending(path: $0).path) })
    }
}
