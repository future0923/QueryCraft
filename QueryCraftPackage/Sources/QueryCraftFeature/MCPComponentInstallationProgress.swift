import Foundation

struct MCPComponentInstallationProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case checking, downloading, verifying, extracting, selfTesting, installing, finishing

        var title: String {
            switch self {
            case .checking: AppCopy.current.text("正在检查组件版本…", "Checking component version…")
            case .downloading: AppCopy.current.text("正在下载…", "Downloading…")
            case .verifying: AppCopy.current.text("正在校验组件…", "Verifying component…")
            case .extracting: AppCopy.current.text("正在解压…", "Extracting…")
            case .selfTesting: AppCopy.current.text("正在运行协议自检…", "Running MCP self-check…")
            case .installing: AppCopy.current.text("正在安装…", "Installing…")
            case .finishing: AppCopy.current.text("正在完成安装…", "Finishing installation…")
            }
        }
    }

    let phase: Phase
    var receivedBytes: Int64 = 0
    var totalBytes: Int64?
    var bytesPerSecond: Double?

    var fractionCompleted: Double? {
        guard phase == .downloading, let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }

    var detail: String? {
        guard phase == .downloading else { return nil }
        let transfer = AppCopy.current.driverDownloadDetail(
            receivedBytes: receivedBytes, totalBytes: totalBytes, bytesPerSecond: bytesPerSecond)
        guard let fractionCompleted else { return transfer }
        return "\(Int(fractionCompleted * 100))% · \(transfer)"
    }
}
