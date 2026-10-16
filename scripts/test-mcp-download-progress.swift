import CryptoKit
import Foundation
@testable import QueryCraftFeature

private actor DownloadProgressRecords {
    private(set) var values: [MCPComponentInstallationProgress] = []
    private var partialWaiter: CheckedContinuation<Void, Never>?

    func record(_ progress: MCPComponentInstallationProgress) {
        values.append(progress)
        if progress.phase == .downloading, progress.receivedBytes > 0,
           progress.receivedBytes < (progress.totalBytes ?? 0) {
            partialWaiter?.resume(); partialWaiter = nil
        }
    }
    func waitForPartial() async {
        if values.contains(where: { $0.receivedBytes > 0 && $0.receivedBytes < ($0.totalBytes ?? 0) }) { return }
        await withCheckedContinuation { partialWaiter = $0 }
    }
}

enum MCPDownloadProgressCheck {
    static func run(catalog: MCPComponentCatalog, root: URL, baseURL: URL) async throws {
        let payload = Data(repeating: 0x71, count: 524_288)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        @Sendable func release(_ path: String, kind: MCPComponentKind = .mcp, corrupt: Bool = false, size: Int64? = nil) -> MCPComponentRelease {
            .init(component: kind, version: "0.1.0", build: "1", architectures: [DatabaseDriverArchitecture.current.rawValue],
                  minimumAppVersion: "0.1.9", maximumAppVersionExclusive: nil, driverAPI: 5, storageAPI: 1, credentialAPI: 1, desktopAPI: 1,
                  minimumMCPVersion: nil, maximumMCPVersionExclusive: nil,
                  sha256: corrupt ? String(repeating: "0", count: 64) : digest, size: size ?? Int64(payload.count), url: baseURL.appending(path: path))
        }
        for kind in [MCPComponentKind.mcp, .skill] {
            for path in ["progress-slow", "progress-unknown-size"] {
                let records = DownloadProgressRecords()
                let destination = root.appending(path: UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: destination) }
                try await catalog.download(release(path, kind: kind), to: destination) { await records.record($0) }
                let values = await records.values
                try check(try Data(contentsOf: destination) == payload, "downloaded contents differ")
                try check(values.first?.receivedBytes == 0 && values.first?.fractionCompleted == 0, "download must start at zero")
                let partial = values.filter { $0.receivedBytes > 0 && $0.receivedBytes < Int64(payload.count) }
                try check(!partial.isEmpty, "slow transfer never reported intermediate progress")
                try check(partial.allSatisfy { $0.totalBytes == Int64(payload.count) && ($0.bytesPerSecond ?? 0) > 0 && $0.detail != nil }, "missing size, speed or percentage")
                try check(values.last?.phase == .verifying, "download callbacks arrived after verification")
                let bytes = values.filter { $0.phase == .downloading }.map(\.receivedBytes)
                try check(bytes == bytes.sorted(), "progress moved backwards")
            }
        }
        print("PASS real throttled MCP/Skill downloads report intermediate bytes, percentage and speed, including missing Content-Length")

        let destination = root.appending(path: "failed-download")
        for (path, corrupt, size) in [("progress-error", false, Int64(payload.count)), ("progress-slow", true, Int64(payload.count)), ("progress-slow", false, Int64(1024)), ("progress-slow", false, Int64(payload.count + 1))] {
            do {
                try await catalog.download(release(path, corrupt: corrupt, size: size), to: destination)
                throw CheckFailure(message: "failed download was accepted")
            } catch is MCPFailure {} catch is URLError {}
            try check(!FileManager.default.fileExists(atPath: destination.path), "failed transfer published a file")
        }
        let records = DownloadProgressRecords()
        let cancelled = Task {
            try await catalog.download(release("progress-slow"), to: destination) { await records.record($0) }
        }
        await records.waitForPartial()
        cancelled.cancel()
        do {
            try await cancelled.value
            throw CheckFailure(message: "cancelled download completed")
        } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {}
        try check(!FileManager.default.fileExists(atPath: destination.path), "cancelled transfer published a file")
        try await catalog.download(release("progress-slow"), to: destination)
        try check(try Data(contentsOf: destination) == payload, "retry failed")
        try FileManager.default.removeItem(at: destination)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try check(!leftovers.contains(where: { $0.hasPrefix(".download-") }), "partial download files leaked")
        print("PASS HTTP/checksum failures and cancellation preserve destination; retry completes without hanging")
    }
}
