import Foundation
import Observation

@MainActor @Observable
final class WorkspaceElasticsearchIndexCreationEditor {
    var input = WorkspaceElasticsearchIndexInput()
    private(set) var prepared: WorkspacePreparedIndexCreation?
    private(set) var validationMessage: String?
    private(set) var message: String?
    private(set) var responseText = ""
    private(set) var isSubmitting = false
    private(set) var isVerifying = false
    private(set) var mustVerify = false
    private(set) var indexExists = false
    private(set) var wasCreated = false
    private(set) var lastAttempt: WorkspacePreparedIndexCreation?
    private let worker = WorkspaceIndexCreationWorker()

    var isBusy: Bool { isSubmitting || isVerifying }
    var canEdit: Bool { !isBusy && !mustVerify && !indexExists }
    var currentPrepared: WorkspacePreparedIndexCreation? { prepared?.input == input ? prepared : nil }
    var canSubmit: Bool { canEdit && currentPrepared != nil }

    func clearPreviousFeedback() {
        guard canEdit else { return }
        message = nil
        responseText = ""
    }

    func validate() async {
        let captured = input
        do {
            let value = try await worker.prepare(captured)
            guard !Task.isCancelled, captured == input else { return }
            prepared = value
            validationMessage = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, captured == input else { return }
            prepared = nil
            validationMessage = error.localizedDescription
        }
    }

    func submit(_ snapshot: WorkspacePreparedIndexCreation,
                execute: @MainActor (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult) async {
        guard canSubmit, currentPrepared == snapshot else { return }
        isSubmitting = true
        lastAttempt = snapshot
        message = nil
        responseText = ""
        defer { isSubmitting = false }
        do {
            let response = try await execute(snapshot.request)
            // A completed write response remains authoritative after cancellation.
            responseText = await worker.responseText(response)
            switch await worker.outcome(response, name: snapshot.input.name) {
            case .created(let waiting):
                wasCreated = true
                indexExists = true
                message = waiting
                    ? AppCopy.current.text("索引已创建，分片尚未全部就绪；可打开索引查看。", "Index created; shards are not all ready yet. You can open the index to inspect it.")
                    : AppCopy.current.text("索引已创建。", "Index created.")
            case .rejected:
                message = AppCopy.current.text("创建被服务器拒绝（HTTP \(response.statusCode)），输入已保留。", "Server rejected creation (HTTP \(response.statusCode)); your input is preserved.")
            case .uncertain:
                markUncertain()
            }
        } catch let error as WorkspaceElasticsearchRequestNotSentError {
            message = error.localizedDescription
        } catch let error as WorkspaceDatabaseDataCellEditError {
            message = error.localizedDescription
        } catch let error as WorkspaceSessionError {
            switch error {
            case .notConnected, .queryUnavailable:
                // These two errors are workspace preflight failures.
                message = error.localizedDescription
            default:
                markUncertain()
                message = (message ?? "") + "\n" + error.localizedDescription
            }
        } catch {
            markUncertain()
            if !(error is CancellationError) { message = (message ?? "") + "\n" + error.localizedDescription }
        }
    }

    func verify(execute: @MainActor (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult) async {
        guard mustVerify, !isBusy, let snapshot = lastAttempt else { return }
        isVerifying = true
        defer { isVerifying = false }
        do {
            let response = try await execute(snapshot.verificationRequest)
            try Task.checkCancellation()
            if response.statusCode == 200 {
                indexExists = true
                mustVerify = false
                message = AppCopy.current.text("服务器上已存在该资源，请打开核对；不会再次发送创建请求。", "The resource exists on the server. Open it to verify; creation will not be sent again.")
            } else if response.statusCode == 404 {
                mustVerify = false
                message = AppCopy.current.text("服务器上不存在该索引，可以手动重新创建。", "The index does not exist on the server. You may retry creation manually.")
            } else {
                message = AppCopy.current.text("无法核实状态（HTTP \(response.statusCode)）；请检查权限或连接后再次核实。", "Unable to verify status (HTTP \(response.statusCode)). Check permissions or connectivity, then verify again.")
            }
        } catch is CancellationError {
        } catch {
            message = error.localizedDescription
        }
    }

    private func markUncertain() {
        mustVerify = true
        message = AppCopy.current.text("创建结果未确认。请先核实服务器状态，避免重复创建。", "Creation outcome is unconfirmed. Verify server state before attempting another creation.")
    }
}
