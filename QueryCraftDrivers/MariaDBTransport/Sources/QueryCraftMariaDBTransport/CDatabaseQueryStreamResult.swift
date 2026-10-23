import Foundation
#if canImport(QueryCraftFeature)
import QueryCraftFeature
#elseif canImport(QueryCraftMobileCore)
import QueryCraftMobileCore
#endif

public struct CDatabaseQueryStreamResult: Sendable {
    public let columns: [WorkspaceDatabaseDataColumn]
    public let rowCount: Int
    public let affectedRows: UInt64
    public let insertID: UInt64
    public let transactionState: WorkspaceQueryTransactionState
}

public enum CDatabaseQueryStreamError: LocalizedError {
    case rowTooLarge
    public var errorDescription: String? { "单行结果超过 8 MiB，读取已停止；请减少大字段或缩小查询范围。" }
}
