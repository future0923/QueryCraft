import Foundation

public enum WorkspaceSessionError: LocalizedError {
    case notConnected
    case connectionUnavailable(host: String, port: Int)
    case metadataUnavailable(object: String)
    case invalidPageRequest
    case invalidDataFilter
    case queryUnavailable
    case invalidConnectionID
    case transactionStateUnavailable
    case licenseRequired

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            AppCopy.current.text(
                "数据库会话尚未连接。",
                "The database session is not connected."
            )
        case let .connectionUnavailable(host, port):
            AppCopy.current.text(
                "无法连接到 \(host):\(port)。请确认服务器可用，并已允许本地网络访问。",
                "Could not reach \(host):\(port). Check that the server is available and Local Network access is allowed."
            )
        case let .metadataUnavailable(object):
            AppCopy.current.text(
                "服务器未返回 \(object) 的元数据。",
                "The server did not return metadata for \(object)."
            )
        case .invalidPageRequest:
            AppCopy.current.text(
                "请求的数据页无效。",
                "The requested data page is invalid."
            )
        case .invalidDataFilter:
            AppCopy.current.text(
                "表数据筛选条件无效。",
                "The table data filter is invalid."
            )
        case .queryUnavailable:
            AppCopy.current.text(
                "此数据库会话不支持执行查询。",
                "This database session does not support query execution."
            )
        case .invalidConnectionID:
            AppCopy.current.text(
                "服务器未返回有效的连接标识符。",
                "The server did not return a valid connection identifier."
            )
        case .transactionStateUnavailable:
            AppCopy.current.text(
                "服务器未返回当前事务状态。",
                "The server did not return its current transaction state."
            )
        case .licenseRequired:
            AppCopy.current.text(
                "30 天试用或许可证不可用。你仍可打开工作区和本地 SQL，但需要在“设置 > 许可证”中激活后才能连接数据库。",
                "The 30-day trial or license is unavailable. You can still open workspaces and local SQL, but database access requires activation in Settings > License."
            )
        }
    }
}
