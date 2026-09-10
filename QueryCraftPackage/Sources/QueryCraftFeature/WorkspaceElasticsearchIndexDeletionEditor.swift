import Foundation
import Observation

@MainActor @Observable
final class WorkspaceElasticsearchIndexDeletionEditor {
    let selection: WorkspaceDatabaseObjectSelection
    var confirmation = ""
    private(set) var prepared: WorkspacePreparedIndexDeletion?
    private(set) var message: String?
    private(set) var responseText = ""
    private(set) var isBusy = false
    private(set) var mustVerify = false
    private(set) var isAbsent = false
    private(set) var didAttemptWrite = false
    private let worker = WorkspaceIndexDeletionWorker()

    init(selection: WorkspaceDatabaseObjectSelection) { self.selection = selection }

    var canDelete: Bool {
        prepared != nil && confirmation == selection.objectName && !isBusy && !mustVerify && !isAbsent
    }

    func prepare() async {
        do {
            let value = try await worker.prepare(selection)
            try Task.checkCancellation()
            prepared = value
        } catch is CancellationError {
        } catch { message = error.localizedDescription }
    }

    func submit(execute: @MainActor (WorkspacePreparedIndexDeletion) async throws -> WorkspaceRequestExecutionResult) async {
        guard canDelete, let prepared else { return }
        isBusy = true
        message = nil
        responseText = ""
        didAttemptWrite = false
        defer { isBusy = false }
        do {
            let result = try await execute(prepared)
            didAttemptWrite = true
            // A complete response is retained even if Stop races its delivery.
            responseText = await worker.responseText(result)
            switch await worker.outcome(result) {
            case .deleted: markAbsent(deleted: true)
            case .absent: markAbsent(deleted: false)
            case .rejected:
                message = AppCopy.current.text("删除被拒绝（HTTP \(result.statusCode)），索引页面已保留。",
                                               "Deletion rejected (HTTP \(result.statusCode)); index pages are preserved.")
            case .uncertain: markUncertain()
            }
        } catch let error as WorkspaceIndexDeletionNotSentError {
            message = error.localizedDescription
            if let response = error.response { responseText = await worker.responseText(response) }
        } catch let error as WorkspaceIndexDeletionError {
            message = error.localizedDescription
        } catch let error as WorkspaceElasticsearchRequestNotSentError {
            message = error.localizedDescription
        } catch let error as WorkspaceDatabaseDataCellEditError {
            message = error.localizedDescription
        } catch {
            didAttemptWrite = true
            markUncertain()
            if !(error is CancellationError) { message = (message ?? "") + "\n" + error.localizedDescription }
        }
    }

    func verify(execute: @MainActor (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult) async {
        guard mustVerify, !isBusy, let prepared else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await execute(prepared.verificationRequest)
            try Task.checkCancellation()
            switch response.statusCode {
            case 404:
                markAbsent(deleted: false)
            case 200:
                mustVerify = false
                confirmation = ""
                message = AppCopy.current.text("索引仍存在。如需再次删除，请重新输入名称确认；不会自动重试。",
                                               "The index still exists. Enter its name again to confirm another deletion; no automatic retry will occur.")
            default:
                message = AppCopy.current.text("无法核实状态（HTTP \(response.statusCode)）。索引页面已保留，请检查连接或权限后再次核实。",
                                               "Unable to verify status (HTTP \(response.statusCode)). Index pages are preserved; check connectivity or permissions and verify again.")
            }
        } catch is CancellationError {
        } catch { message = error.localizedDescription }
    }

    private func markAbsent(deleted: Bool) {
        isAbsent = true
        mustVerify = false
        message = deleted
            ? AppCopy.current.text("索引已删除。", "Index deleted.")
            : AppCopy.current.text("已确认索引不存在。", "The index is confirmed absent.")
    }

    private func markUncertain() {
        mustVerify = true
        message = AppCopy.current.text("删除结果未确认。索引页面已保留，请先核实服务器状态；不会自动重试。",
                                       "Deletion outcome is unconfirmed. Index pages are preserved; verify server state first. No automatic retry will occur.")
    }
}
