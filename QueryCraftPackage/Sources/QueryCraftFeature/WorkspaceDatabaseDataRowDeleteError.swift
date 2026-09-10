import Foundation

public enum WorkspaceDatabaseDataRowDeleteError: Error, Equatable {
    case tableRequired
    case rowUnavailable
    case primaryKeyRequired
    case primaryKeyValueUnavailable(String)
    case safetyLockEnabled
    case editingContextChanged
    case rowChanged
    case unexpectedAffectedRows(Int)
}

extension WorkspaceDatabaseDataRowDeleteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tableRequired:
            AppCopy.current.text(
                "只能删除真实表中的数据，视图保持只读。",
                "Rows can only be deleted from base tables. Views remain read-only."
            )
        case .rowUnavailable:
            AppCopy.current.text(
                "所选行已不在当前数据页中。",
                "The selected row is no longer on the current data page."
            )
        case .primaryKeyRequired:
            AppCopy.current.text(
                "此表没有主键，无法可靠删除单行。",
                "This table has no primary key, so a single row cannot be deleted safely."
            )
        case let .primaryKeyValueUnavailable(columnName):
            AppCopy.current.text(
                "主键列“\(columnName)”的原始值不可用。",
                "The original value for primary-key column \"\(columnName)\" is unavailable."
            )
        case .safetyLockEnabled:
            AppCopy.current.text(
                "安全锁已启用，删除操作被阻止。",
                "Safety Lock is enabled, so the delete was blocked."
            )
        case .editingContextChanged:
            AppCopy.current.text(
                "当前表或数据库连接已发生变化，请重新选择要删除的行。",
                "The current table or database connection changed. Select the row again."
            )
        case .rowChanged:
            AppCopy.current.text(
                "找不到这个主键对应的数据行，可能已被删除或主键已变化。请刷新后重试。",
                "No row matches this primary key. It may have been deleted or its primary key may have changed. Refresh and try again."
            )
        case let .unexpectedAffectedRows(count):
            AppCopy.current.text(
                "MySQL 返回了意外的受影响行数：\(count)。",
                "MySQL returned an unexpected affected-row count: \(count)."
            )
        }
    }
}
