import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

enum MobileQueryBatchEvent: Sendable {
    case started(Int)
    case completed(Int, MobileSQLPreview)
}

enum MobileQueryBatchError: LocalizedError {
    case tooManyStatements, resultBudget, truncatedSession
    var errorDescription: String? {
        switch self {
        case .tooManyStatements: "一次最多执行 20 条查询，请缩小执行范围。"
        case .resultBudget: "整批结果已达到 8 MiB 原始数据预算，后续语句未执行。"
        case .truncatedSession: "当前结果已截断，读取连接已关闭，后续语句未执行。请单独运行其余查询。"
        }
    }
}

enum MobileQueryBatchLimits {
    static let maximumStatements = 20
    static let maximumBytes = 8_388_608
    static func validate(_ statements: [SQLExecutionStatement]) throws {
        guard !statements.isEmpty, statements.count <= maximumStatements else { throw MobileQueryBatchError.tooManyStatements }
        guard statements.allSatisfy({ $0.kind == .read }) else { throw MobileQueryError.readOnlySQLRequired }
    }

    static func retainedBytes(_ preview: MobileSQLPreview) -> Int {
        preview.result.rows.enumerated().reduce(0) { total, row in
            total + row.element.enumerated().reduce(0) { bytes, cell in
                if preview.cells.indices.contains(row.offset), preview.cells[row.offset].indices.contains(cell.offset),
                   case let .binary(count, _) = preview.cells[row.offset][cell.offset] { return bytes + count }
                return bytes + (cell.element?.utf8.count ?? 0)
            }
        }
    }
}
