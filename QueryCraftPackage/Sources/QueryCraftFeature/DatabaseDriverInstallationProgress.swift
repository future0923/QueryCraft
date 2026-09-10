enum DatabaseDriverInstallationPhase: Equatable, Sendable {
    case checkingCompatibility
    case downloading
    case verifying
    case installing

    var title: String {
        switch self {
        case .checkingCompatibility:
            AppCopy.current.text("正在检查兼容性...", "Checking compatibility...")
        case .downloading:
            AppCopy.current.text("正在下载...", "Downloading...")
        case .verifying:
            AppCopy.current.text("正在校验...", "Verifying...")
        case .installing:
            AppCopy.current.text("正在安装...", "Installing...")
        }
    }
}

struct DatabaseDriverInstallationProgress: Equatable, Sendable {
    let phase: DatabaseDriverInstallationPhase
    let fractionCompleted: Double?
    let receivedBytes: Int64?
    let totalBytes: Int64?
    let bytesPerSecond: Double?

    init(
        phase: DatabaseDriverInstallationPhase,
        fractionCompleted: Double? = nil,
        receivedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        bytesPerSecond: Double? = nil
    ) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted.map {
            min(max($0, 0), 1)
        }
        self.receivedBytes = receivedBytes.map { max($0, 0) }
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
        self.bytesPerSecond = bytesPerSecond.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
    }

    var downloadDetail: String? {
        guard phase == .downloading, let receivedBytes else { return nil }
        return AppCopy.current.driverDownloadDetail(
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: bytesPerSecond
        )
    }
}
