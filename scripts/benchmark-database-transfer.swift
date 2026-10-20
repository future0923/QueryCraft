import AppKit
import Foundation
@testable import QueryCraftFeature

private struct BenchmarkFailure: Error, CustomStringConvertible { let description: String }

@main struct DatabaseTransferBenchmark {
    static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }

    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() }
        catch { emit(["event": "error", "message": String(describing: error)]); exit(1) }
    }

    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let architecture = ProcessInfo.processInfo.machineArchitecture
        @MainActor func loadDriver(_ name: String) async throws {
            guard let bundle = Bundle(path: env["BENCH_DRIVER_ROOT"]! + "/\(name)-\(architecture).querycraftdriver") else {
                throw BenchmarkFailure(description: "Missing installed driver: \(name)")
            }
            try bundle.loadAndReturnError()
            guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else {
                throw BenchmarkFailure(description: "Missing driver entry")
            }
            try await entry.init().activate()
        }
        if env["BENCH_LOAD_ONLY"] == "1" {
            let names = env["BENCH_DRIVER_ORDER"]?.components(separatedBy: ",") ?? ["MySQL", "PostgreSQL", "Doris", "Redis", "Elasticsearch", "Kafka"]
            for name in names {
                try await loadDriver(name)
                emit(["event": "driver_loaded", "driver": name])
            }
            return
        }
        let sourceType = DatabaseType(rawValue: env["BENCH_SOURCE_TYPE"]!)!
        let targetType = DatabaseType(rawValue: env["BENCH_TARGET_TYPE"]!)!
        for type in Set([sourceType, targetType]) { try await loadDriver(type == .mysql ? "MySQL" : "PostgreSQL") }
        func connection(_ side: String, type: DatabaseType) -> TransferConnection {
            let database = env["BENCH_\(side)_DATABASE"]!
            return .init(endpoint: .init(profileID: UUID(), database: database, schema: env["BENCH_\(side)_SCHEMA"] ?? ""),
                         configuration: .init(databaseType: type, host: "127.0.0.1", port: Int(env["BENCH_\(side)_PORT"]!)!,
                                              username: type == .postgresql ? "postgres" : "root", password: env["BENCH_\(side)_PASSWORD"],
                                              database: database, tlsMode: .disabled))
        }
        let source = connection("SOURCE", type: sourceType), target = connection("TARGET", type: targetType)
        let catalog = DataTransferCatalog()
        let objects = try await catalog.objects(source)
        guard let table = objects.first(where: { $0.kind == .table && $0.name == "large_rows" }) else {
            throw BenchmarkFailure(description: "Missing isolated source fixture")
        }
        var config = DataTransferConfiguration()
        config.source = source.endpoint; config.target = target.endpoint; config.objects = [table]
        config.batchSize = Int(env["BENCH_BATCH"] ?? "1000")!
        config.strategy = TransferStrategy(rawValue: env["BENCH_STRATEGY"] ?? "append")!
        config.content = config.strategy == .overwrite ? .dataOnly : .structureAndData
        if let filter = env["BENCH_FILTER"], !filter.isEmpty { config.tableFilters[table.name] = filter }
        let prepareStart = Date()
        let plan = try await DataTransferPlanner(catalog: catalog).prepare(configuration: config, source: source, target: target, ownership: .skip)
        let history = URL(fileURLWithPath: env["BENCH_HISTORY"]!)
        let manager = DataTransferManager(historyURL: history)
        let start = Date()
        try manager.start(plan, name: "Large Docker transfer", sourceLabel: sourceType.rawValue, targetLabel: targetType.rawValue)
        // Exercise exactly the workbench's close path while the manager owns the run.
        var workbench: DataTransferWorkbenchModel? = .init(library: .init(url: history.deletingLastPathComponent().appending(path: "isolated-library.json")), manager: manager)
        workbench?.close(); workbench = nil
        emit(["event": "started", "pid": ProcessInfo.processInfo.processIdentifier, "batch": config.batchSize,
              "prepare_seconds": start.timeIntervalSince(prepareStart), "workbench_closed": true])
        let cancelAfter = Int(env["BENCH_CANCEL_AFTER"] ?? "0")!
        let cancelFile = env["BENCH_CANCEL_FILE"] ?? ""
        var cancellationAt: Date?, lastTick = Date(), maxTickGap = 0.0, lastPrinted = 0, channel = ""
        while manager.hasActiveRuns {
            try await Task.sleep(for: .milliseconds(100))
            let now = Date(); maxTickGap = max(maxTickGap, now.timeIntervalSince(lastTick)); lastTick = now
            let rows = manager.runs.first?.items.first?.readRows ?? 0
            let message = manager.runs.first?.items.first?.message ?? ""
            if message.contains("COPY") || message.contains("LOAD DATA") { channel = message }
            if rows >= lastPrinted + 100_000 {
                lastPrinted = rows
                emit(["event": "progress", "rows": rows, "seconds": now.timeIntervalSince(start)])
            }
            let phaseReady = env["BENCH_CANCEL_PHASE"] != "merge" || message.contains("merging") || message.contains("合并")
            if cancellationAt == nil && (cancelAfter > 0 && rows >= cancelAfter && phaseReady || !cancelFile.isEmpty && FileManager.default.fileExists(atPath: cancelFile)) {
                cancellationAt = now; manager.cancel(plan.id)
                emit(["event": "cancel_requested", "rows": rows])
            }
        }
        guard let result = manager.runs.first else { throw BenchmarkFailure(description: "Missing run") }
        let elapsed = Date().timeIntervalSince(start)
        let snapshot = try JSONDecoder().decode([TransferRunRecord].self, from: Data(contentsOf: history))
        guard snapshot.first?.status == result.status, snapshot.first?.committedRows == result.committedRows,
              manager.persistenceError.isEmpty else { throw BenchmarkFailure(description: "History did not persist the final result") }
        var metrics: [String: Any] = ["event": "finished", "status": result.status.rawValue,
                                      "read_rows": result.items.first?.readRows ?? 0, "committed_rows": result.committedRows,
                                      "seconds": elapsed, "rows_per_second": Double(result.committedRows) / max(elapsed, 0.001),
                                      "max_main_actor_tick_gap_seconds": maxTickGap, "message": result.message,
                                      "channel": channel.isEmpty ? result.items.first?.message ?? "" : channel]
        if let cancellationAt { metrics["cancel_seconds"] = Date().timeIntervalSince(cancellationAt) }
        emit(metrics)
        if env["BENCH_REQUIRE_NATIVE"] == "1" {
            let channel = metrics["channel"] as? String ?? ""
            guard channel.contains("COPY") || channel.contains("LOAD DATA") else {
                throw BenchmarkFailure(description: "Expected a native channel, got: \(channel)")
            }
        }
        let expected = cancelAfter > 0 ? TransferRunStatus.cancelled : .completed
        guard result.status == expected else {
            throw BenchmarkFailure(description: "Unexpected status \(result.status): \(result.message) / \(result.items.map(\.message))")
        }
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
