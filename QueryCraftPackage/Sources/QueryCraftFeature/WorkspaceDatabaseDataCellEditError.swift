import Foundation

public enum WorkspaceDatabaseDataCellEditError: Error, Equatable {
    case tableRequired
    case metadataUnavailable
    case primaryKeyRequired
    case primaryKeyValueUnavailable(String)
    case binaryValueUnavailable
    case generatedColumn
    case nullNotAllowed
    case defaultUnavailable
    case unchangedValue
    case safetyLockEnabled
    case editingContextChanged
    case rowChanged
    case unexpectedAffectedRows(Int)
}

extension WorkspaceDatabaseDataCellEditError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tableRequired:
            AppCopy.current.text(
                "只能修改真实表中的数据，视图保持只读。",
                "Only data in base tables can be edited. Views remain read-only."
            )
        case .metadataUnavailable:
            AppCopy.current.text(
                "无法读取这个单元格对应的列信息。",
                "Column information for this cell is unavailable."
            )
        case .primaryKeyRequired:
            AppCopy.current.text(
                "此表没有主键，无法可靠定位单行。",
                "This table has no primary key, so a single row cannot be identified safely."
            )
        case let .primaryKeyValueUnavailable(columnName):
            AppCopy.current.text(
                "主键列“\(columnName)”的原始值不可用。",
                "The original value for primary-key column \"\(columnName)\" is unavailable."
            )
        case .binaryValueUnavailable:
            AppCopy.current.text(
                "当前结果只保留了二进制值的大小，无法安全修改这个单元格。",
                "The current result retains only the binary value size, so this cell cannot be edited safely."
            )
        case .generatedColumn:
            AppCopy.current.text(
                "生成列由数据库计算，不能直接修改。",
                "Generated columns are computed by the database and cannot be edited directly."
            )
        case .nullNotAllowed:
            AppCopy.current.text(
                "此列不允许 NULL。",
                "This column does not allow NULL."
            )
        case .defaultUnavailable:
            AppCopy.current.text(
                "此列没有可用的默认值。",
                "This column does not have an available default value."
            )
        case .unchangedValue:
            AppCopy.current.text("值没有变化。", "The value has not changed.")
        case .safetyLockEnabled:
            AppCopy.current.text(
                "安全锁已启用，数据修改被阻止。",
                "Safety Lock is enabled, so the data change was blocked."
            )
        case .editingContextChanged:
            AppCopy.current.text(
                "当前表或数据库连接已发生变化，请重新选择单元格。",
                "The current table or database connection changed. Select the cell again."
            )
        case .rowChanged:
            AppCopy.current.text(
                "找不到这个主键对应的数据行，可能已被删除或主键已变化。请刷新后重试。",
                "No row matches this primary key. It may have been deleted or its primary key may have changed. Refresh and try again."
            )
        case let .unexpectedAffectedRows(count):
            AppCopy.current.text(
                "数据库返回了意外的受影响行数：\(count)。",
                "The database returned an unexpected affected-row count: \(count)."
            )
        }
    }
}
