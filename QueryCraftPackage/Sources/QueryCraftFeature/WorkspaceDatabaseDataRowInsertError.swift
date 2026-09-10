import Foundation

public enum WorkspaceDatabaseDataRowInsertError: Error, Equatable {
    case tableRequired
    case binaryValueUnavailable(String)
    case safetyLockEnabled
    case editingContextChanged
    case unexpectedAffectedRows(Int)
}

extension WorkspaceDatabaseDataRowInsertError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tableRequired:
            AppCopy.current.text(
                "只能向真实表新增数据，视图保持只读。",
                "Rows can only be added to base tables. Views remain read-only."
            )
        case let .binaryValueUnavailable(columnName):
            AppCopy.current.text(
                "列“\(columnName)”只保留了二进制值大小，无法复制这一行。",
                "Column \"\(columnName)\" retains only the binary value size, so this row cannot be duplicated."
            )
        case .safetyLockEnabled:
            AppCopy.current.text(
                "安全锁已启用，新增数据被阻止。",
                "Safety Lock is enabled, so the insert was blocked."
            )
        case .editingContextChanged:
            AppCopy.current.text(
                "当前表或数据库连接已发生变化，请重新新增。",
                "The current table or database connection changed. Start the insert again."
            )
        case let .unexpectedAffectedRows(count):
            AppCopy.current.text(
                "MySQL 返回了意外的受影响行数：\(count)。",
                "MySQL returned an unexpected affected-row count: \(count)."
            )
        }
    }
}
