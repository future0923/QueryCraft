import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

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
        let quote: UInt8 = self == .postgresql ? 34 : 96
        var bytes: [UInt8] = [quote]
        bytes.reserveCapacity(value.utf8.count + 2)
        for byte in value.utf8 {
            bytes.append(byte)
            if byte == quote { bytes.append(byte) }
        }
        bytes.append(quote)
        return String(decoding: bytes, as: UTF8.self)
    }

    func literal(_ value: WorkspaceDatabaseDataCell) throws -> String {
        switch value {
        case .null: return "NULL"
        case .binary:
            throw WorkspaceDataExportError.incompleteBinaryValue
        case let .text(text):
            if self == .postgresql {
                if !text.utf8.contains(where: { $0 == 0 || $0 == 39 || $0 == 92 }) { return "E'\(text)'" }
                var bytes: [UInt8] = [69, 39]
                bytes.reserveCapacity(text.utf8.count + 8)
                for byte in text.utf8 {
                    guard byte != 0 else { throw WorkspaceDataExportError.unsupportedSQLValue }
                    if byte == 39 || byte == 92 { bytes.append(byte) }
                    bytes.append(byte)
                }
                bytes.append(39)
                return String(decoding: bytes, as: UTF8.self)
            }
            // Hex text is independent of MySQL's NO_BACKSLASH_ESCAPES mode.
            if text.utf8.contains(where: { $0 == 92 || $0 < 32 }) {
                let digits = Array("0123456789ABCDEF".utf8)
                var bytes: [UInt8] = []
                bytes.reserveCapacity(text.utf8.count * 2)
                for byte in text.utf8 {
                    bytes.append(digits[Int(byte >> 4)])
                    bytes.append(digits[Int(byte & 15)])
                }
                let hex = String(decoding: bytes, as: UTF8.self)
                return self == .doris ? "UNHEX('\(hex)')" : "CONVERT(X'\(hex)' USING utf8mb4)"
            }
            if !text.utf8.contains(39) { return "'\(text)'" }
            var bytes: [UInt8] = [39]
            bytes.reserveCapacity(text.utf8.count + 8)
            for byte in text.utf8 {
                bytes.append(byte)
                if byte == 39 { bytes.append(byte) }
            }
            bytes.append(39)
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
