import Foundation
import Observation

@MainActor @Observable
final class ShellScriptSettingsModel {
    let service: any ShellScriptLibraryServing
    var records: [ShellScript] = []
    var loaded = false
    var loading = false
    var busy = false
    var search = ""
    var loadError: String?
    var actionError: String?
    var error: String? { actionError ?? loadError }
    var status = ""
    private var generation = 0
    init(service: any ShellScriptLibraryServing = ShellScriptLibraryService()) { self.service = service }
    var filtered: [ShellScript] {
        records.filter { search.isEmpty || ($0.name + " " + $0.description).localizedCaseInsensitiveContains(search) }
    }
    func load(force: Bool = false) async {
        generation += 1; let request = generation
        loading = true
        defer { if generation == request { loading = false } }
        do {
            let snapshot = try await service.list(force: force)
            try Task.checkCancellation()
            guard generation == request else { return }
            records = snapshot; loaded = true; loadError = nil
        } catch is CancellationError {} catch {
            if generation == request { self.loadError = Self.message(error) }
        }
    }
    func current(_ record: ShellScript, requireRevision: Bool = false) async -> ShellScript? {
        guard !busy else { return nil }; busy = true; actionError = nil; status = ""; defer { busy = false }
        do {
            let records = try await service.list(force: true)
            try Task.checkCancellation()
            guard let current = records.first(where: { $0.id == record.id }), !requireRevision || current.revision == record.revision else {
                throw MCPFailure("Script changed or was removed.", code: .sessionBusy)
            }
            actionError = nil; return current
        } catch is CancellationError {} catch { self.actionError = Self.message(error) }
        return nil
    }
    func remove(_ record: ShellScript) async {
        guard !busy else { return }; busy = true; actionError = nil; status = ""; defer { busy = false }
        do {
            try await service.remove(record)
            await load(force: true)
            status = AppCopy.current.text("已删除脚本。", "Script deleted.")
        } catch is CancellationError {} catch {
            let message = Self.message(error)
            await load(force: true); self.actionError = message
        }
    }
    func retry() async { actionError = nil; await load(force: true) }
    static func message(_ error: any Error) -> String {
        let copy = AppCopy.current
        if let failure = error as? MCPFailure {
            switch failure.code {
            case .sessionBusy:
                return copy.text("脚本已被其他客户端修改或删除。请重新打开核对；当前草稿已保留。", "The script changed or was removed by another client. Reopen it to review; your draft was kept.")
            case .policyUnavailable:
                return copy.text("无法读取脚本库，已保留当前内容。请检查本机数据目录后重试。", "Cannot read the script library. Current content was kept. Check the local data directory and retry.")
            case .capacity:
                return copy.text("脚本库已达到数量或大小上限，请减少内容后重试。", "The script library reached its count or size limit. Reduce content and retry.")
            default:
                return copy.text("操作未完成。脚本可能已被删除，请重新核对列表和内容。", "The operation did not complete. The script may have been removed; review the list and content.")
            }
        }
        return copy.text("操作失败，请重试。", "The operation failed. Please try again.")
    }
}

@MainActor @Observable
final class ShellScriptDraft: Identifiable {
    let id: UUID
    let original: ShellScript?
    var name: String
    var description: String
    var script: String
    var busy = false
    var error: String?
    init(original: ShellScript? = nil) {
        self.original = original; id = original?.id ?? UUID()
        name = original?.name ?? ""; description = original?.description ?? ""; script = original?.script ?? ""
    }
    var hasChanges: Bool { original.map { $0.name != name || $0.description != description || $0.script != script } ?? (!name.isEmpty || !description.isEmpty || !script.isEmpty) }
    var valid: Bool {
        do {
            try ShellScript(id: id, name: name, description: description, script: script, revision: 1, createdAt: Date(), updatedAt: Date()).validate()
            return true
        } catch { return false }
    }
    func save(service: any ShellScriptLibraryServing) async -> Bool {
        guard !busy else { return false }
        guard valid else {
            error = AppCopy.current.text("请填写名称和正文，并检查长度；脚本正文最多 64 KiB。", "Enter a name and source within the limits; source is limited to 64 KiB.")
            return false
        }
        busy = true; error = nil; defer { busy = false }
        do {
            _ = try await service.save(original: original, name: name, description: description, script: script)
            return true
        } catch is CancellationError { return false }
        catch { self.error = ShellScriptSettingsModel.message(error); return false }
    }
}
