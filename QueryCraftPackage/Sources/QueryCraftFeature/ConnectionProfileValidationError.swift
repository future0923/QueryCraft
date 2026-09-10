import Foundation

enum ConnectionProfileValidationError: LocalizedError, Equatable {
    case missingName
    case missingHost
    case invalidPort
    case missingUsername

    var errorDescription: String? {
        switch self {
        case .missingName:
            AppCopy.current.text("请输入连接名称。", "Enter a connection name.")
        case .missingHost:
            AppCopy.current.text(
                "请输入主机名或 IP 地址。",
                "Enter a host name or IP address."
            )
        case .invalidPort:
            AppCopy.current.text(
                "请输入 1 到 65535 之间的端口。",
                "Enter a port between 1 and 65535."
            )
        case .missingUsername:
            AppCopy.current.text("请输入 MySQL 用户名。", "Enter a MySQL username.")
        }
    }
}
