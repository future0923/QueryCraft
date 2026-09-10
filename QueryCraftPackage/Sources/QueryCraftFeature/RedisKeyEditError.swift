import Foundation

enum RedisKeyEditError: LocalizedError, Equatable {
    case unavailable
    case unsupportedType(RedisKeyType)
    case truncatedString
    case incompleteRow
    case duplicateIdentity(String)
    case invalidScore(String)
    case invalidTTL
    case invalidHex
    case invalidKeyName
    case keyAlreadyExists(String)
    case safetyLockEnabled
    case transactionUnavailable
    case transactionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            AppCopy.current.text(
                "Redis Key 编辑上下文已失效。",
                "The Redis key editing context is no longer available."
            )
        case .unsupportedType(let type):
            AppCopy.current.text(
                "暂不支持修改 \(type.rawValue.uppercased()) Key。",
                "Editing \(type.rawValue.uppercased()) keys is not supported yet."
            )
        case .truncatedString:
            AppCopy.current.text(
                "该 String 太大，当前只读取了部分内容，不能安全地覆盖原值。",
                "This string is too large and only partially loaded, so it cannot be safely overwritten."
            )
        case .incompleteRow:
            AppCopy.current.text(
                "请先填写新增行的字段或成员。",
                "Complete the field or member in each new row."
            )
        case .duplicateIdentity(let value):
            AppCopy.current.text(
                "“\(value)”重复，请保留一个唯一的字段或成员。",
                "\"\(value)\" is duplicated. Keep each field or member unique."
            )
        case .invalidScore(let value):
            AppCopy.current.text(
                "“\(value)”不是有效的 ZSet 分数。",
                "\"\(value)\" is not a valid sorted-set score."
            )
        case .invalidTTL:
            AppCopy.current.text(
                "TTL 必须是大于 0 的毫秒整数。",
                "TTL must be a positive whole number of milliseconds."
            )
        case .invalidHex:
            AppCopy.current.text(
                "Hex 内容必须由完整的十六进制字节对组成。",
                "Hex content must contain complete hexadecimal byte pairs."
            )
        case .invalidKeyName:
            AppCopy.current.text(
                "Key 名称不能为空。",
                "The key name cannot be empty."
            )
        case .keyAlreadyExists(let name):
            AppCopy.current.text(
                "Key“\(name)”已存在，未执行重命名。",
                "The key “\(name)” already exists, so it was not renamed."
            )
        case .safetyLockEnabled:
            AppCopy.current.text(
                "安全锁已开启，无法提交 Redis 修改。",
                "Safety Lock is enabled, so Redis changes cannot be committed."
            )
        case .transactionUnavailable:
            AppCopy.current.text(
                "当前 Redis 驱动不支持原子提交修改，请更新驱动。",
                "The current Redis driver cannot commit changes atomically. Update the driver and try again."
            )
        case .transactionFailed(let message):
            AppCopy.current.text(
                "Redis 事务执行失败：\(message)",
                "The Redis transaction failed: \(message)"
            )
        }
    }
}
