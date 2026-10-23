import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

struct SQLExecutionStatement: Equatable, Sendable, Identifiable {
    let index: Int
    let source: SQLSourceSnapshot
    let range: SQLSourceRange
    let kind: SQLStatementKind

    var id: Int { index }

    var sql: String {
        (source.text as NSString).substring(with: range.nsRange)
    }
}
