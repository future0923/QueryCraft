import Foundation
import Observation

enum SSHActivitySelection: Hashable, Sendable {
    case task(UUID), transfer(UUID)
    var id: UUID { switch self { case .task(let id), .transfer(let id): id } }
    var isTask: Bool { if case .task = self { true } else { false } }
}

enum SSHActivityAction: String, Identifiable {
    case cancelTask, removeTask, forgetTask, cancelTransfer, cleanupTransfer
    var id: String { rawValue }
    var tool: String {
        switch self {
        case .cancelTask: "ssh_cancel_task"
        case .removeTask: "ssh_remove_task"
        case .forgetTask: "ssh_forget_task"
        case .cancelTransfer: ""
        case .cleanupTransfer: "ssh_cleanup_transfer"
        }
    }
}

struct SSHActivityConfirmation: Identifiable {
    let id = UUID()
    let action: SSHActivityAction
    let selection: SSHActivitySelection
    let inspectionToken: String?
    var transfer: SSHTransferRecord? = nil
}

@MainActor @Observable
final class SSHActivityModel {
    let profile: SSHConnection
    let service: any SSHActivityServing
    var snapshot: SSHActivitySnapshot?
    private(set) var selection: SSHActivitySelection?
    private(set) var stream = "stdout"
    var autoRefresh = true
    var refreshID = UUID()
    private(set) var listLoading = false
    private(set) var detailLoading = false
    private(set) var actionLoading = false
    var listError: String?
    var detailError: String?
    var feedback = ""
    var detail: MCPJSONValue?
    var log = ""
    var nextOffset = 0
    var logFinal = false
    var logWindowStart = 0
    private var listRequest = UUID()
    private var detailRequest = UUID()
    private var generation = UUID()
    private var logStream = "stdout"
    private var logBytes = Data()
    init(profile: SSHConnection, service: any SSHActivityServing) { self.profile = profile; self.service = service }
    var currentTransfer: SSHActivityTransfer? { snapshot?.transfers.first { $0.id == selection?.id && selection?.isTask == false } }
    var taskState: String { detail?.objectValue?["state"]?.stringValue ?? "not_polled" }
    var terminalTask: Bool { ["completed", "cancelled", "timed_out", "failed"].contains(taskState) }
    var inspectionToken: String? { detail?.objectValue?["inspection_token"]?.stringValue }
    func allows(_ tool: String) -> Bool { snapshot?.allowedTools.contains(tool) == true }
    func select(_ value: SSHActivitySelection?) {
        guard selection != value else { return }
        selection = value; generation = UUID(); detailRequest = UUID(); detailLoading = false
        detail = nil; detailError = nil; feedback = ""; resetLog()
    }
    func resetLog() { log = ""; logBytes = Data(); nextOffset = 0; logWindowStart = 0; logFinal = false; logStream = stream }
    func changeStream(_ value: String) {
        guard ["stdout", "stderr"].contains(value), stream != value else { return }
        stream = value; detailRequest = UUID(); detailLoading = false; resetLog()
    }
    func refreshList() async {
        let request = UUID(); listRequest = request; listLoading = true
        defer { if listRequest == request { listLoading = false } }
        do {
            let result = try await service.snapshot()
            try Task.checkCancellation(); guard listRequest == request else { return }
            snapshot = result; listError = nil
            if let selection {
                let exists = selection.isTask ? result.tasks.contains { $0.id == selection.id } : result.transfers.contains { $0.id == selection.id }
                if !exists { select(nil) }
            }
        } catch { if !Task.isCancelled && listRequest == request { listError = error.localizedDescription } }
    }
    func refreshDetail() async {
        guard let selected = selection, !actionLoading else { return }
        let request = UUID(), version = generation, requestedStream = stream
        detailRequest = request; detailLoading = true
        if logStream != requestedStream { resetLog() }
        defer { if detailRequest == request { detailLoading = false } }
        func current() -> Bool { !Task.isCancelled && generation == version && selection == selected && stream == requestedStream && detailRequest == request }
        do {
            let tool = selected.isTask ? "ssh_task_status" : "ssh_inspect_transfer"
            guard allows(tool) else { throw MCPFailure(AppCopy.current.text("请在 MCP 设置中启用对应工具和账号权限；写操作还要求完整访问。", "Enable the matching MCP tool and account grant; writes also require Full access."), code: .accessDenied) }
            if !selected.isTask && currentTransfer?.active == true {
                if current() { detail = nil; detailError = nil }
                return
            }
            let key = selected.isTask ? "task_id" : "transfer_id"
            let value = try await service.call(tool, arguments: [key: .string(selected.id.uuidString)])
            guard current() else { return }
            detail = value; detailError = nil
            if selected.isTask && allows("ssh_task_output") {
                let offset = nextOffset
                let output = try await service.call("ssh_task_output", arguments: ["task_id": .string(selected.id.uuidString),
                    "stream": .string(requestedStream), "offset": .int(offset), "max_bytes": 16_384])
                guard current() else { return }
                guard let object = output.objectValue,
                      let encoded = object["content_base64"]?.stringValue, let bytes = Data(base64Encoded: encoded),
                      let next = object["next_offset"]?.intValue, next == offset + bytes.count else { throw MCPFailure("Invalid task output byte window.") }
                // Render bounded binary windows without silently accumulating unbounded logs.
                logBytes.append(bytes)
                nextOffset = next; logFinal = object["final"]?.boolValue == true
                if logBytes.count > 131_072 {
                    logBytes = Data(logBytes.suffix(65_536))
                    logWindowStart = nextOffset - logBytes.count
                }
                log = String(decoding: logBytes, as: UTF8.self)
            }
        } catch { if current() { detailError = error.localizedDescription } }
    }
    func perform(_ confirmation: SSHActivityConfirmation, acknowledged: Bool) async -> Bool {
        let action = confirmation.action
        guard let selected = selection, selected == confirmation.selection, !actionLoading else { return false }
        let version = generation, token = confirmation.inspectionToken
        guard (action != .cleanupTransfer && action != .forgetTask) || acknowledged else { return false }
        if action == .cleanupTransfer && token == nil { return false }
        actionLoading = true
        defer { actionLoading = false }
        do {
            if action == .cancelTransfer { try await service.cancelTransfer(selected.id) }
            else {
                var args: [String: MCPJSONValue] = [selected.isTask ? "task_id" : "transfer_id": .string(selected.id.uuidString), "confirm_high_risk": true]
                if action == .forgetTask { args["acknowledge_task_may_be_running"] = .bool(acknowledged) }
                if action == .cleanupTransfer { args["inspection_token"] = token.map(MCPJSONValue.string); args["acknowledge_outcome_unknown"] = .bool(acknowledged) }
                _ = try await service.call(action.tool, arguments: args)
            }
            guard generation == version else { return true }
            detail = nil; detailError = nil
            feedback = AppCopy.current.text("操作已提交，请刷新核对实际结果。不会自动重试。", "Action submitted. Refresh to verify the outcome. No automatic retry.")
            return true
        } catch {
            if generation == version {
                detailError = error.localizedDescription
                if action == .cleanupTransfer { detail = nil }
            }
            return false
        }
    }
}
