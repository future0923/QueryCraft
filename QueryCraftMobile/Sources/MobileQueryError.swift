import Foundation

enum MobileQueryError: LocalizedError {
    case verifiedTLSUnavailable
    case readOnlySQLRequired
    case resultTooLarge
    case invalidConnection
    case invalidServerMetadata

    var errorDescription: String? {
        switch self {
        case .verifiedTLSUnavailable:
            "此原型尚未接入 CA 证书和严格身份验证，当前可使用禁用 TLS 或要求 TLS 的连接模式。"
        case .readOnlySQLRequired:
            "当前执行范围只允许只读查询：SELECT、WITH、SHOW、DESCRIBE 和 EXPLAIN。写入、事务控制或无法可靠分类的语句不会执行。"
        case .resultTooLarge:
            "结果超过加载上限。请缩小查询范围或只选择需要的列。"
        case .invalidConnection:
            "请填写连接名称、服务器、有效端口和用户名。"
        case .invalidServerMetadata:
            "服务器返回的结构信息不完整，请刷新后重试。"
        }
    }
}
