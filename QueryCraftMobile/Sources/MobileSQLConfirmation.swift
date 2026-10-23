import Foundation
import QueryCraftMobileTransport

struct MobileSQLConfirmation: Identifiable {
    let id = UUID()
    let statements: [SQLExecutionStatement]
    let configuration: MariaDBTransportConfiguration
    let sourceText: String
    let revision: UInt64
    var requiresUnlock: Bool
    var sql: String { statements.map(\.sql).joined(separator: "\n\n") }
}
