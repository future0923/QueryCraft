import Foundation

/// A data-only grammar: never sends file SQL or its target identifiers to the server.
enum WorkspaceSQLImporter {
    static func read(_ text: String, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        var parser = Parser(scanner: Scanner(text: text, backslashEscapes: options.sqlBackslashEscapes))
        return try parser.read()
    }

    static func read(handle: FileHandle, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        var parser = Parser(scanner: Scanner(handle: handle, backslashEscapes: options.sqlBackslashEscapes))
        return try parser.read()
    }

    enum Token: Equatable {
        case word(String), string(String), identifier(String), number(String), symbol(Character), end
    }

    struct Scanner {
        private var buffer: Data
        private let handle: FileHandle?
        private var reachedEnd: Bool
        private var cursor = 0
        private var position = 0
        let backslashEscapes: Bool

        init(text: String, backslashEscapes: Bool) {
            buffer = Data(text.utf8)
            handle = nil
            reachedEnd = true
            self.backslashEscapes = backslashEscapes
        }

        init(handle: FileHandle, backslashEscapes: Bool) {
            buffer = Data()
            self.handle = handle
            reachedEnd = false
            self.backslashEscapes = backslashEscapes
        }

        func invalid() -> WorkspaceDataImportError {
            .invalid("SQL 在字节 \(position + 1) 附近不受支持。仅接受带字段列表的 INSERT INTO … VALUES 字面量数据。", "Unsupported SQL near byte \(position + 1). Use literal INSERT INTO … VALUES with column lists.")
        }

        mutating func peek(_ offset: Int = 0) throws -> UInt8? {
            if position.isMultiple(of: 64 * 1024) { try Task.checkCancellation() }
            if cursor + offset >= buffer.count && !reachedEnd {
                try Task.checkCancellation()
                // Keep at most two lookahead bytes when refilling the input window.
                buffer = Data(buffer.dropFirst(cursor))
                cursor = 0
                let chunk = try handle?.read(upToCount: 64 * 1024) ?? Data()
                reachedEnd = chunk.isEmpty
                buffer.append(chunk)
            }
            return cursor + offset < buffer.count ? buffer[cursor + offset] : nil
        }

        mutating func advance(_ count: Int = 1) {
            cursor += count
            position += count
        }

        mutating func next() throws -> Token {
            while let byte = try peek() {
                if position == 0, byte == 0xef, try peek(1) == 0xbb, try peek(2) == 0xbf { advance(3); continue }
                if Self.isWhitespace(byte) { advance(); continue }
                if try byte == 35 || (byte == 45 && peek(1) == 45) {
                    while let c = try peek(), c != 10 && c != 13 { advance() }
                    continue
                }
                if try byte == 47 && peek(1) == 42 {
                    guard try peek(2) != 33 else { throw invalid() }
                    advance(2)
                    var closed = false
                    while let c = try peek() {
                        if try c == 42 && peek(1) == 47 { advance(2); closed = true; break }
                        advance()
                    }
                    guard closed else { throw invalid() }
                    continue
                }
                break
            }
            guard let c = try peek() else { return .end }
            if let symbol = Self.symbol(c) { advance(); return .symbol(symbol) }
            if c == 39 { return .string(try quoted(39, escapes: backslashEscapes)) }
            if c == 96 || c == 34 { return .identifier(try quoted(c, escapes: false)) }
            if try (c == 69 || c == 101) && peek(1) == 39 {
                advance()
                return .string(try quoted(39, escapes: true))
            }
            var bytes: [UInt8] = []
            if Self.isDigit(c) || c == 45 || c == 43 {
                while let byte = try peek(), !Self.isWhitespace(byte) && (Self.symbol(byte) == nil || byte == 46) {
                    bytes.append(byte); advance()
                }
                guard Self.isNumber(bytes) else { throw invalid() }
                return .number(String(decoding: bytes, as: UTF8.self))
            }
            while let byte = try peek(), Self.isWordByte(byte) { bytes.append(byte); advance() }
            guard !bytes.isEmpty, let word = String(bytes: bytes, encoding: .utf8) else { throw invalid() }
            return .word(word)
        }

        mutating func quoted(_ quote: UInt8, escapes: Bool) throws -> String {
            advance()
            var result: [UInt8] = []
            while let c = try peek() {
                if position.isMultiple(of: 64 * 1024) { try Task.checkCancellation() }
                // Copy runs of literal UTF-8 at once; the input window bounds cancellation latency.
                let end = buffer.withUnsafeBytes { raw -> Int in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    var end = cursor
                    while end < bytes.count && bytes[end] != quote && !(escapes && bytes[end] == 92) { end += 1 }
                    return end
                }
                if end > cursor {
                    result.append(contentsOf: buffer[cursor..<end])
                    advance(end - cursor)
                    continue
                }
                advance()
                if c == quote {
                    if try peek() == quote { result.append(quote); advance() }
                    else {
                        guard let value = String(bytes: result, encoding: .utf8) else { throw invalid() }
                        return value
                    }
                } else if c == 92 && escapes {
                    guard let escaped = try peek() else { throw invalid() }
                    advance()
                    switch escaped {
                    case 48: result.append(0)
                    case 110: result.append(10)
                    case 114: result.append(13)
                    case 116: result.append(9)
                    case 98: result.append(8)
                    case 90: result.append(26)
                    case 92, 39, 34: result.append(escaped)
                    default: throw invalid()
                    }
                } else { result.append(c) }
            }
            throw invalid()
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 9 || byte == 10 || byte == 11 || byte == 12 || byte == 13 || byte == 32
        }
        private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
        private static func isWordByte(_ byte: UInt8) -> Bool {
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || isDigit(byte)
                || byte == 95 || byte == 36 || byte >= 128
        }
        private static func symbol(_ byte: UInt8) -> Character? {
            switch byte {
            case 40: "("
            case 41: ")"
            case 44: ","
            case 46: "."
            case 59: ";"
            default: nil
            }
        }

        /// Avoid compiling an ICU regular expression for every numeric cell.
        private static func isNumber(_ bytes: [UInt8]) -> Bool {
            var i = 0
            if bytes.first == 43 || bytes.first == 45 { i += 1 }
            let start = i
            while i < bytes.count && isDigit(bytes[i]) { i += 1 }
            guard i > start else { return false }
            if i < bytes.count && bytes[i] == 46 {
                i += 1
                while i < bytes.count && isDigit(bytes[i]) { i += 1 }
            }
            if i < bytes.count && (bytes[i] == 69 || bytes[i] == 101) {
                i += 1
                if i < bytes.count && (bytes[i] == 43 || bytes[i] == 45) { i += 1 }
                let exponent = i
                while i < bytes.count && isDigit(bytes[i]) { i += 1 }
                guard i > exponent else { return false }
            }
            return i == bytes.count
        }
    }

    struct Parser {
        var scanner: Scanner
        var lookahead: Token?
        mutating func take() throws -> Token {
            if let token = lookahead { lookahead = nil; return token }
            return try scanner.next()
        }
        mutating func accept(_ token: Token) throws -> Bool {
            let next = try take()
            let matches: Bool
            if case .word(let lhs) = next, case .word(let rhs) = token { matches = lhs.uppercased() == rhs.uppercased() }
            else { matches = next == token }
            if !matches { lookahead = next }
            return matches
        }
        mutating func expect(_ token: Token) throws { guard try accept(token) else { throw scanner.invalid() } }
        mutating func name() throws -> String {
            switch try take() {
            case .word(let name), .identifier(let name): return name
            default: throw scanner.invalid()
            }
        }
        mutating func read() throws -> WorkspaceDataImportFile {
            var columns: [String] = [], source: [String]?
            let rows = WorkspaceDataImportRowBuilder()
            while try !accept(.end) {
                try Task.checkCancellation()
                if try accept(.symbol(";")) { continue }
                if try accept(.word("START")) { try expect(.word("TRANSACTION")); try expect(.symbol(";")); continue }
                if try accept(.word("BEGIN")) { _ = try accept(.word("TRANSACTION")); try expect(.symbol(";")); continue }
                if try accept(.word("COMMIT")) { try expect(.symbol(";")); continue }
                try expect(.word("INSERT")); try expect(.word("INTO"))
                var target = [try name()]
                while try accept(.symbol(".")) { target.append(try name()) }
                if let source, source != target { throw WorkspaceDataImportError.invalid("SQL 文件包含多张表，请拆分后导入。", "The SQL file contains multiple tables. Split it before importing.") }
                source = target
                try expect(.symbol("("))
                var current = [try name()]
                while try accept(.symbol(",")) { current.append(try name()) }
                try expect(.symbol(")"))
                if columns.isEmpty { columns = current }
                guard columns == current else { throw WorkspaceDataImportError.invalid("各 INSERT 的字段列表必须一致。", "All INSERT statements must have the same column list.") }
                if try accept(.word("OVERRIDING")) { try expect(.word("SYSTEM")); try expect(.word("VALUE")) }
                try expect(.word("VALUES"))
                repeat {
                    try autoreleasepool {
                        try expect(.symbol("("))
                        var row = [try value()]
                        while try accept(.symbol(",")) { row.append(try value()) }
                        try expect(.symbol(")"))
                        guard row.count == columns.count else { throw scanner.invalid() }
                        try rows.append(row)
                    }
                } while try accept(.symbol(","))
                if try !accept(.symbol(";")) { try expect(.end); break }
            }
            return try rows.finish(columns: columns)
        }
        mutating func value() throws -> String? {
            switch try take() {
            case .string(let value), .number(let value): return value
            case .word(let word):
                switch word.uppercased() {
                case "NULL": return nil
                case "TRUE": return "true"
                case "FALSE": return "false"
                case "CONVERT":
                    try expect(.symbol("(")); try expect(.word("X"))
                    guard case .string(let hex) = try take() else { throw scanner.invalid() }
                    try expect(.word("USING")); try expect(.word("utf8mb4")); try expect(.symbol(")"))
                    return try decodeHex(hex)
                case "UNHEX":
                    try expect(.symbol("("))
                    guard case .string(let hex) = try take() else { throw scanner.invalid() }
                    try expect(.symbol(")")); return try decodeHex(hex)
                default: throw scanner.invalid()
                }
            default: throw scanner.invalid()
            }
        }
        func decodeHex(_ hex: String) throws -> String {
            let bytes = Array(hex.utf8)
            guard bytes.count.isMultiple(of: 2) else { throw scanner.invalid() }
            var data = Data()
            for i in stride(from: 0, to: bytes.count, by: 2) {
                guard let byte = UInt8(String(decoding: bytes[i..<i+2], as: UTF8.self), radix: 16) else { throw scanner.invalid() }
                data.append(byte)
            }
            guard let value = String(data: data, encoding: .utf8) else { throw scanner.invalid() }
            return value
        }
    }
}
