import Foundation

enum WorkspaceError: LocalizedError {
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            AppCopy.current.text(
                "连接配置已不存在。",
                "The connection profile no longer exists."
            )
        }
    }
}
