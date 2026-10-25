#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation
import Observation

@MainActor @Observable
final class DataTransferManager {
    static let shared = DataTransferManager()
    private(set) var runs: [TransferRunRecord] = []
    private(set) var persistenceError = ""
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reservations: [UUID: Set<String>] = [:]
    @ObservationIgnored private let historyURL: URL
    @ObservationIgnored private let runner: DataTransferRunner
    @ObservationIgnored private var lastSave = Date.distantPast

    init(historyURL: URL = QueryCraftStorageLocation.applicationSupportDirectory.appending(path: "DataTransferHistory.json"),
         runner: DataTransferRunner = .init()) {
        self.historyURL = historyURL; self.runner = runner
        do {
            if FileManager.default.fileExists(atPath: historyURL.path) {
                runs = try JSONDecoder().decode([TransferRunRecord].self, from: Data(contentsOf: historyURL))
                for index in runs.indices where runs[index].status.isActive {
                    runs[index].status = .interrupted
                    runs[index].message = AppCopy.current.text("程序在上次传输完成前退出。已提交数据和结构可能保留，请核对目标后重新创建任务。", "The application exited before transfer completed. Data and structures may remain. Verify the target before starting a new run.")
                    for item in runs[index].items.indices where runs[index].items[item].status.isActive { runs[index].items[item].status = .interrupted }
                }
            }
        } catch { persistenceError = error.localizedDescription }
    }

    var hasActiveRuns: Bool { runs.contains { $0.status.isActive } }

    func cancelAllAndWait() async {
        let current = tasks
        for id in current.keys { cancel(id) }
        for task in current.values { await task.value }
    }

    func start(_ plan: DataTransferPlan, name: String, sourceLabel: String, targetLabel: String, authorize: @escaping DataTransferRunner.Authorize = {}) throws {
        guard persistenceError.isEmpty else { throw TransferFailure("传输历史无法保存，请检查存储目录：\(persistenceError)", "Transfer history cannot be saved. Check the storage directory: \(persistenceError)") }
        guard tasks[plan.id] == nil, !runs.contains(where: { $0.id == plan.id }) else { throw TransferFailure("该执行计划已启动，请重新生成预览。", "This plan already started. Generate a new preview.") }
        let endpoint = plan.target.endpoint, server = plan.target.configuration
        let base = "\(server.databaseType.rawValue):\(plan.targetServerIdentity):\(endpoint.database):\(endpoint.namespace):"
        let keys = Set(plan.items.map { base + $0.object.kind.rawValue + ":" + $0.targetName.lowercased() })
        guard reservations.values.allSatisfy({ $0.isDisjoint(with: keys) }) else {
            throw TransferFailure("相同目标对象已有传输任务运行，请等待完成。", "A transfer is already using the same target objects. Wait for it to finish.")
        }
        let record = TransferRunRecord(id: plan.id, name: name, sourceLabel: sourceLabel, targetLabel: targetLabel, createdAt: Date(), status: .running,
                                       items: plan.items.map { .init(id: $0.object.id, name: $0.object.name) })
        runs.insert(record, at: 0); reservations[plan.id] = keys; persist()
        guard persistenceError.isEmpty else {
            runs.removeAll { $0.id == plan.id }; reservations[plan.id] = nil
            throw TransferFailure("未能保存执行记录，任务尚未启动。", "Could not save the execution record. The transfer has not started.")
        }
        let runner = runner
        tasks[plan.id] = Task { [weak self] in
            let result = await runner.run(plan, authorize: authorize, progress: { [weak self] item in await self?.receive(item, id: plan.id) }, backups: { [weak self] names in await self?.receiveBackups(names, id: plan.id) })
            guard let self else { return }
            if let index = self.runs.firstIndex(where: { $0.id == plan.id }) {
                self.runs[index].status = result.0; self.runs[index].message = result.1; self.runs[index].finishedAt = Date()
            }
            self.tasks[plan.id] = nil; self.reservations[plan.id] = nil; self.persist()
            NotificationCenter.default.post(name: .dataTransferDidFinish, object: nil)
        }
    }

    func cancel(_ id: UUID) {
        guard let task = tasks[id], let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].status = .cancelling; task.cancel(); persist()
    }

    func acknowledgeOutcome(_ id: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == id }), [.uncertain, .interrupted].contains(runs[index].status) else { return }
        let previous = runs[index].verifiedAt
        runs[index].verifiedAt = .now
        persist()
        if !persistenceError.isEmpty { runs[index].verifiedAt = previous }
    }

    func clearFinished() {
        runs.removeAll { !$0.status.isActive }; persist()
    }

    private func receive(_ item: TransferItemProgress, id: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == id }), let itemIndex = runs[index].items.firstIndex(where: { $0.id == item.id }) else { return }
        runs[index].items[itemIndex] = item
        if !item.status.isActive || Date().timeIntervalSince(lastSave) >= 1 { persist() }
    }
    private func receiveBackups(_ names: [String], id: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].backupTables = names; persist()
    }
    private func persist() {
        guard persistenceError.isEmpty else { return }
        do {
            let finished = runs.filter { !$0.status.isActive }.prefix(100)
            let snapshot = runs.filter { $0.status.isActive } + finished
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: historyURL, options: .atomic); lastSave = Date()
        } catch { persistenceError = error.localizedDescription }
    }
}

extension Notification.Name {
    static let dataTransferDidFinish = Notification.Name("QueryCraftDataTransferDidFinish")
}
