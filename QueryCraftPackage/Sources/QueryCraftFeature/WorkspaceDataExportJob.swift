import Foundation
import Observation

enum WorkspaceDataExportJobStatus: Equatable {
    case queued
    case exporting
    case finalizing
    case completed
    case cancelled
    case failed(String)
}

@MainActor
@Observable
final class WorkspaceDataExportJob: Identifiable {
    let id: UUID
    let destination: URL
    let format: WorkspaceDataExportFormat
    let estimatedRowCount: Int?
    let createdAt: Date

    private(set) var completedRowCount = 0
    private(set) var status = WorkspaceDataExportJobStatus.queued

    init(
        id: UUID = UUID(),
        destination: URL,
        format: WorkspaceDataExportFormat,
        estimatedRowCount: Int?,
        createdAt: Date = .now
    ) {
        self.id = id
        self.destination = destination
        self.format = format
        self.estimatedRowCount = estimatedRowCount
        self.createdAt = createdAt
    }

    var isActive: Bool {
        switch status {
        case .queued, .exporting, .finalizing:
            true
        case .completed, .cancelled, .failed:
            false
        }
    }

    var canCancel: Bool {
        switch status {
        case .queued, .exporting, .finalizing:
            true
        case .completed, .cancelled, .failed:
            false
        }
    }

    func markExporting() {
        status = .exporting
    }

    func updateProgress(_ rowCount: Int) {
        completedRowCount = rowCount
        if let estimatedRowCount, rowCount >= estimatedRowCount {
            status = .finalizing
        }
    }

    func markCompleted(rowCount: Int) {
        completedRowCount = rowCount
        status = .completed
    }

    func markCancelled() {
        status = .cancelled
    }

    func markFailed(_ message: String) {
        status = .failed(message)
    }
}
