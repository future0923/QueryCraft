import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
@Suite("Workspace Data Export Job Manager")
struct WorkspaceDataExportJobManagerTests {
    @Test("Queued cancellation never connects or prepares the table")
    func cancelsQueuedPreparation() async throws {
        let manager = WorkspaceDataExportJobManager(concurrentJobLimit: 1, presentsExportCenterOnEnqueue: false)
        let source = SuspendedExportRowSource()
        let request = request(source: source)
        let preparation = ExportPreparationProbe()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        manager.enqueue(request: request, destination: directory.appending(path: "first.csv"))
        manager.enqueue(format: .csv, destination: directory.appending(path: "queued.csv")) {
            await preparation.record()
            return request
        }
        let queued = try #require(manager.jobs.first)
        #expect(queued.status == .queued)
        manager.cancel(queued)
        manager.jobs.forEach(manager.cancel)
        for _ in 0..<200 where manager.activeJobCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await preparation.count == 0)
        #expect(queued.status == .cancelled)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "queued.csv").path) == false)
    }

    @Test("Runs at most two exports and keeps additional work queued")
    func limitsConcurrentExports() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "QueryCraftExportQueueTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = WorkspaceDataExportJobManager(
            concurrentJobLimit: 2,
            presentsExportCenterOnEnqueue: false
        )
        for index in 0..<3 {
            manager.enqueue(
                request: request(source: SuspendedExportRowSource()),
                destination: directory.appending(path: "\(index).csv")
            )
        }

        #expect(manager.jobs.count == 3)
        #expect(manager.jobs[0].status == .queued)
        #expect(manager.jobs[1].status == .exporting)
        #expect(manager.jobs[2].status == .exporting)

        manager.jobs.forEach(manager.cancel)
        for _ in 0..<200 where manager.activeJobCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.activeJobCount == 0)
        #expect(
            manager.jobs.allSatisfy { $0.status == .cancelled }
        )
    }

    private func request(
        source: any WorkspaceDataExportRowSource
    ) -> WorkspaceDataExportRequest {
        var options = WorkspaceDataExportOptions()
        options.format = .csv
        return WorkspaceDataExportRequest(
            columns: [
                WorkspaceGridCopyColumn(name: "id", dataIndex: 0)
            ],
            options: options,
            estimatedRowCount: nil,
            worksheetName: "Result",
            source: source
        )
    }
}

private actor ExportPreparationProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor SuspendedExportRowSource: WorkspaceDataExportRowSource {
    func nextBatch() async throws -> [WorkspaceDatabaseDataRow]? {
        try await Task.sleep(for: .seconds(60))
        return nil
    }
}
