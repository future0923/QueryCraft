import Foundation

enum SQLExecutionPolicyError: LocalizedError, Equatable {
    case safetyLockEnabled
    case unclassifiedStatement

    var errorDescription: String? {
        switch self {
        case .safetyLockEnabled:
            AppCopy.current.text(
                "安全锁已启用。停用安全锁后才能运行更改数据或数据库结构的语句。",
                "Safety Lock is enabled. Disable it to run statements that change data or database structure."
            )
        case .unclassifiedStatement:
            AppCopy.current.text(
                "安全锁无法确定此 SQL 是否会更改数据。停用安全锁后可将原始 SQL 提交到数据库。",
                "Safety Lock cannot determine whether this SQL changes data. Disable it to submit the exact SQL to the database."
            )
        }
    }
}
