import Foundation

enum WorkspaceSQLExportDialect: Equatable, Sendable {
    case mysql
    case postgresql
    case doris

    init?(databaseType: DatabaseType) {
        switch databaseType {
        case .mysql: self = .mysql
        case .postgresql: self = .postgresql
        case .doris: self = .doris
        case .redis, .elasticsearch, .kafka: return nil
        }
    }

    func identifier(_ value: String) -> String {
        let quote = self == .postgresql ? "\"" : "`"
        return quote + value.replacingOccurrences(of: quote, with: quote + quote) + quote
    }

    func literal(_ value: WorkspaceDatabaseDataCell) throws -> String {
        switch value {
        case .null: return "NULL"
        case .binary:
            throw WorkspaceDataExportError.incompleteBinaryValue
        case let .text(text):
            if self == .postgresql {
                guard !text.contains("\0") else { throw WorkspaceDataExportError.unsupportedSQLValue }
                let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "''")
                return "E'\(escaped)'"
            }
            // Hex text is independent of MySQL's NO_BACKSLASH_ESCAPES mode.
            if text.contains("\\") || text.unicodeScalars.contains(where: { $0.value < 32 }) {
                let hex = text.utf8.map { String(format: "%02X", $0) }.joined()
                return self == .doris ? "UNHEX('\(hex)')" : "CONVERT(X'\(hex)' USING utf8mb4)"
            }
            return "'\(text.replacingOccurrences(of: "'", with: "''"))'"
        }
    }
}
