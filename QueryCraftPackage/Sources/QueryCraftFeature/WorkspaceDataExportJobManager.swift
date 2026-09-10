import AppKit
import Observation

@MainActor
@Observable
final class WorkspaceDataExportJobManager {
    static let shared = WorkspaceDataExportJobManager()
    static let maximumConcurrentJobCount = 2

    private(set) var jobs: [WorkspaceDataExportJob] = []

    @ObservationIgnored private let concurrentJobLimit: Int
    @ObservationIgnored private let presentsExportCenterOnEnqueue: Bool
    @ObservationIgnored private var requests:
        [UUID: WorkspaceDataExportRequest] = [:]
    @ObservationIgnored private var runningTasks:
        [UUID: Task<Void, Never>] = [:]

    init(
        concurrentJobLimit: Int = maximumConcurrentJobCount,
        presentsExportCenterOnEnqueue: Bool = true
    ) {
        self.concurrentJobLimit = max(1, concurrentJobLimit)
        self.presentsExportCenterOnEnqueue =
            presentsExportCenterOnEnqueue
    }

    var activeJobCount: Int {
        jobs.filter(\.isActive).count
    }

    func enqueue(
        request: WorkspaceDataExportRequest,
        destination: URL
    ) {
        let job = WorkspaceDataExportJob(
            destination: destination,
            format: request.options.format,
            estimatedRowCount: request.estimatedRowCount
        )
        jobs.insert(job, at: 0)
        requests[job.id] = request
        startPendingJobs()
        if presentsExportCenterOnEnqueue {
            WorkspaceDataExportCenterWindowController.show()
        }
    }

    func cancel(_ job: WorkspaceDataExportJob) {
        guard job.canCancel else { return }
        if let task = runningTasks[job.id] {
            task.cancel()
        } else {
            requests[job.id] = nil
            job.markCancelled()
            startPendingJobs()
        }
    }

    func clearFinishedJobs() {
        jobs.removeAll { !$0.isActive }
    }

    func open(_ job: WorkspaceDataExportJob) {
        guard case .completed = job.status else { return }
        NSWorkspace.shared.open(job.destination)
    }

    func reveal(_ job: WorkspaceDataExportJob) {
        guard case .completed = job.status else { return }
        NSWorkspace.shared.activateFileViewerSelecting([job.destination])
    }

    private func startPendingJobs() {
        while runningTasks.count < concurrentJobLimit,
              let job = jobs.last(where: {
                  $0.status == .queued && requests[$0.id] != nil
              }),
              let request = requests[job.id]
        {
            job.markExporting()
            let jobID = job.id
            let destination = job.destination
            let exporter = WorkspaceDataExporter()
            let manager = self
            runningTasks[jobID] = Task(priority: .utility) {
                do {
                    let rowCount = try await exporter.export(
                        request,
                        to: destination
                    ) { completedRows in
                        await manager.updateProgress(
                            for: jobID,
                            completedRows: completedRows
                        )
                    }
                    try Task.checkCancellation()
                    manager.complete(jobID, rowCount: rowCount)
                } catch is CancellationError {
                    manager.completeCancellation(jobID)
                } catch {
                    manager.completeFailure(
                        jobID,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func updateProgress(
        for jobID: UUID,
        completedRows: Int
    ) {
        job(for: jobID)?.updateProgress(completedRows)
    }

    private func complete(_ jobID: UUID, rowCount: Int) {
        job(for: jobID)?.markCompleted(rowCount: rowCount)
        finishTask(jobID)
    }

    private func completeCancellation(_ jobID: UUID) {
        job(for: jobID)?.markCancelled()
        finishTask(jobID)
    }

    private func completeFailure(_ jobID: UUID, message: String) {
        job(for: jobID)?.markFailed(message)
        finishTask(jobID)
    }

    private func finishTask(_ jobID: UUID) {
        requests[jobID] = nil
        runningTasks[jobID] = nil
        startPendingJobs()
    }

    private func job(for id: UUID) -> WorkspaceDataExportJob? {
        jobs.first { $0.id == id }
    }
}
