import Foundation

public enum RedisWorkspaceError: LocalizedError, Equatable {
    case unavailable
    case invalidLogicalDatabase(String)
    case invalidCommand
    case invalidReply(String)
    case unsupportedTLS
    case unsupportedKeyType(String)
    case mutationConflict(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            AppCopy.current.text(
                "当前驱动不提供 Redis 工作区能力。",
                "The current driver does not provide Redis workspace capabilities."
            )
        case .invalidLogicalDatabase(let name):
            AppCopy.current.text(
                "Redis 逻辑数据库“\(name)”无效。",
                "The Redis logical database “\(name)” is invalid."
            )
        case .invalidCommand:
            AppCopy.current.text(
                "请输入有效的 Redis 命令。",
                "Enter a valid Redis command."
            )
        case .invalidReply(let command):
            AppCopy.current.text(
                "Redis 命令 \(command) 返回了无法识别的结果。",
                "Redis command \(command) returned an unrecognized reply."
            )
        case .unsupportedTLS:
            AppCopy.current.text(
                "此版本的 Redis 驱动暂不支持 TLS。",
                "This version of the Redis driver does not support TLS yet."
            )
        case .unsupportedKeyType(let type):
            AppCopy.current.text(
                "暂不支持读取 Redis 类型“\(type)”。",
                "Reading Redis type “\(type)” is not supported yet."
            )
        case .mutationConflict(let key):
            AppCopy.current.text(
                "Key“\(key)”已被其他操作修改。请刷新后重新编辑。",
                "The “\(key)” key changed outside this editor. Refresh and try again."
            )
        }
    }
}
