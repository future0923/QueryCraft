import Foundation

/// Preserves numeric tokens; retains one record rather than the document tree.
enum WorkspaceJSONImporter {
    indirect enum Value {
        case object([(String, Value)]), array([Value]), scalar(String), atom(String), null
        func cell() throws -> String? {
            switch self {
            case .scalar(let text), .atom(let text): return text
            case .null: return nil
            default: return json
            }
        }
        var json: String {
            switch self {
            case .null: "null"
            case .atom(let text): text
            case .scalar(let text): String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
            case .array(let values): "[" + values.map(\.json).joined(separator: ",") + "]"
            case .object(let pairs): "{" + pairs.map { Self.scalar($0.0).json + ":" + $0.1.json }.joined(separator: ",") + "}"
            }
        }
    }

    static func read(_ text: String, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        try read(WorkspaceDataImportByteReader(data: Data(text.utf8)), options: options)
    }
    static func read(handle: FileHandle, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        try read(WorkspaceDataImportByteReader(handle: handle), options: options)
    }
    private static func read(_ input: WorkspaceDataImportByteReader, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        var parser = Parser(input: input)
        try parser.input.skipBOM()
        guard try !parser.atEnd else { throw error("JSON 文件为空。", "The JSON file is empty.") }
        let first = try parser.peek()
        var wrapperNames: [String]?, container = false
        // Discover wrappers/JSONL without retaining a top-level array. This pass is
        // structural only; individual rows are validated when they are consumed.
        if first == 123 {
            try parser.require(123)
            var columns: Value?, rowsAreArray = false, keys = Set<String>()
            if try !parser.consume(125) {
                repeat {
                    let key = try parser.string()
                    guard keys.insert(key).inserted else { throw parser.malformed() }
                    try parser.require(58)
                    if key == "columns" { columns = try parser.value(depth: 1) }
                    else { if key == "rows" { rowsAreArray = try parser.peek() == 91 }; try parser.scanValue(depth: 1) }
                } while try parser.consume(44)
                try parser.require(125)
            }
            if try parser.atEnd, rowsAreArray, case .array(let columns) = columns {
                wrapperNames = try columns.map { item in
                    if case .scalar(let name) = item { return name }
                    if case .object(let fields) = item,
                       case .scalar(let name) = fields.first(where: { $0.0 == "name" })?.1 { return name }
                    throw error("JSON columns 必须包含字段名。", "JSON columns must contain column names.")
                }
            }
            try parser.input.reset()
        } else if first == 91 {
            try parser.scanValue(depth: 0)
            container = try parser.atEnd
            try parser.input.reset()
        }
        let sink = try RowSink(options: options, names: wrapperNames)
        if wrapperNames != nil {
            try parser.require(123)
            if try !parser.consume(125) {
                repeat {
                    let key = try parser.string(); try parser.require(58)
                    if key == "rows" { try parser.readRows(into: sink) }
                    else { try parser.skipValue(depth: 1) }
                } while try parser.consume(44)
                try parser.require(125)
            }
            guard try parser.atEnd else { throw parser.malformed() }
        } else if container {
            try parser.readRows(into: sink)
            guard try parser.atEnd else { throw parser.malformed() }
        } else {
            while try !parser.atEnd { try autoreleasepool { try sink.append(parser.value(depth: 0)) } }
        }
        return try sink.finish()
    }

    private static func error(_ zh: String, _ en: String) -> WorkspaceDataImportError { .invalid(zh, en) }

    final class RowSink {
        let options: WorkspaceDataImportOptions
        let names: [String]?
        var objects: Bool?
        var ordered: [String] = [], indices: [String: Int] = [:], count = 0
        let builder = WorkspaceDataImportRowBuilder()
        var table: WorkspaceDataImportTableBuilder?
        init(options: WorkspaceDataImportOptions, names: [String]?) throws {
            self.options = options; self.names = names
            // Names bypass the header/data relationship for object rows, as before.
            _ = try WorkspaceDataImportTableBuilder(options: options, names: ["validation"])
        }
        func append(_ record: Value) throws {
            count += 1
            switch record {
            case .object(let pairs):
                guard objects != false else { throw error("不能混用 JSON 对象行和数组行。", "Cannot mix JSON object and array rows.") }
                objects = true
                var row = Array<String?>(repeating: nil, count: ordered.count)
                for (key, value) in pairs {
                    let index: Int
                    if let found = indices[key] { index = found }
                    else { index = ordered.count; indices[key] = index; ordered.append(key); row.append(nil) }
                    row[index] = try value.cell()
                }
                if count >= options.firstDataRow && (options.lastDataRow == 0 || count <= options.lastDataRow) {
                    try builder.append(options.trimsWhitespace || options.emptyAsNull ? row.map(options.normalized) : row)
                }
            case .array(let cells):
                guard objects != true else { throw error("不能混用 JSON 对象行和数组行。", "Cannot mix JSON object and array rows.") }
                objects = false
                if table == nil { table = try WorkspaceDataImportTableBuilder(options: options, names: names) }
                try table?.append(cells.map { try $0.cell() })
            default: throw error("JSON 须为对象、对象数组或二维数组。", "JSON must contain objects or arrays of rows.")
            }
        }
        func finish() throws -> WorkspaceDataImportFile {
            if objects == true { return try builder.finish(columns: ordered, padsMissing: true) }
            return try (table ?? WorkspaceDataImportTableBuilder(options: options, names: names)).finish()
        }
    }

    struct Parser {
        var input: WorkspaceDataImportByteReader
        var atEnd: Bool { mutating get throws { try space(); return try input.peek() == nil } }
        mutating func space() throws { while let c = try input.peek(), c == 9 || c == 10 || c == 13 || c == 32 { input.advance() } }
        mutating func peek() throws -> UInt8? { try space(); return try input.peek() }
        mutating func consume(_ byte: UInt8) throws -> Bool {
            try space()
            if try input.peek() == byte { input.advance(); return true }
            return false
        }
        mutating func require(_ byte: UInt8) throws { guard try consume(byte) else { throw malformed() } }
        func malformed() -> WorkspaceDataImportError { .invalid("JSON 在字节 \(input.position + 1) 附近格式无效。", "Invalid JSON near byte \(input.position + 1).") }
        mutating func readRows(into sink: RowSink) throws {
            try require(91)
            if try consume(93) { return }
            repeat { try autoreleasepool { try sink.append(value(depth: 1)) } } while try consume(44)
            try require(93)
        }
        mutating func value(depth: Int) throws -> Value {
            try space()
            guard depth < 64, let first = try input.peek() else { throw malformed() }
            if first == 34 { return .scalar(try string()) }
            if try consume(123) {
                var pairs: [(String, Value)] = [], keys = Set<String>()
                if try consume(125) { return .object(pairs) }
                repeat {
                    let key = try string()
                    guard keys.insert(key).inserted else { throw error("JSON 对象含重复字段：\(key)", "Duplicate JSON key: \(key)") }
                    try require(58); pairs.append((key, try value(depth: depth + 1)))
                } while try consume(44)
                try require(125); return .object(pairs)
            }
            if try consume(91) {
                var values: [Value] = []
                if try consume(93) { return .array(values) }
                repeat { values.append(try value(depth: depth + 1)) } while try consume(44)
                try require(93); return .array(values)
            }
            return try atom()
        }
        /// Discovery only: no AST, cell strings or numeric tokens. The subsequent
        /// parse validates all grammar, including metadata skipped from the result.
        mutating func scanValue(depth: Int) throws {
            try space()
            guard let first = try input.peek() else { throw malformed() }
            if first != 34 && first != 123 && first != 91 {
                while let c = try input.peek(), ![9,10,13,32,44,93,125].contains(c) { input.advance() }
                return
            }
            var stack: [UInt8] = [], quoted = false
            while let c = try input.peek() {
                input.advance()
                if quoted {
                    if c == 92 { guard try input.peek() != nil else { throw malformed() }; input.advance() }
                    else if c == 34 { quoted = false; if stack.isEmpty { return } }
                    else { input.skipRun(until: { $0 == 34 || $0 == 92 }) }
                } else if c == 34 { quoted = true }
                else if c == 123 || c == 91 {
                    stack.append(c)
                    guard stack.count + depth <= 64 else { throw malformed() }
                } else if c == 125 || c == 93 {
                    guard stack.popLast() == (c == 125 ? 123 : 91) else { throw malformed() }
                    if stack.isEmpty { return }
                } else { input.skipRun(until: { $0 == 34 || $0 == 123 || $0 == 91 || $0 == 125 || $0 == 93 }) }
            }
            throw malformed()
        }
        mutating func skipValue(depth: Int) throws {
            try space(); guard depth < 64, let first = try input.peek() else { throw malformed() }
            if first == 34 { _ = try string(); return }
            if try consume(123) {
                var keys = Set<String>()
                if try consume(125) { return }
                repeat {
                    let key = try string(); guard keys.insert(key).inserted else { throw malformed() }
                    try require(58); try skipValue(depth: depth + 1)
                } while try consume(44)
                try require(125); return
            }
            if try consume(91) {
                if try consume(93) { return }
                repeat { try autoreleasepool { try skipValue(depth: depth + 1) } } while try consume(44)
                try require(93); return
            }
            _ = try atom()
        }
        mutating func atom() throws -> Value {
            var bytes: [UInt8] = []
            while let byte = try input.peek(), ![9,10,13,32,44,93,125].contains(byte) { bytes.append(byte); input.advance() }
            let token = String(decoding: bytes, as: UTF8.self)
            if token == "null" { return .null }
            if token == "true" || token == "false" { return .atom(token) }
            var i = bytes.first == 45 ? 1 : 0
            let start = i
            while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }
            guard i > start, i - start == 1 || bytes[start] != 48 else { throw malformed() }
            if i < bytes.count && bytes[i] == 46 {
                i += 1; let fraction = i
                while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }
                guard i > fraction else { throw malformed() }
            }
            if i < bytes.count && (bytes[i] == 69 || bytes[i] == 101) {
                i += 1
                if i < bytes.count && (bytes[i] == 43 || bytes[i] == 45) { i += 1 }
                let exponent = i
                while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }
                guard i > exponent else { throw malformed() }
            }
            guard i == bytes.count else { throw malformed() }
            return .atom(token)
        }
        mutating func string() throws -> String {
            try require(34)
            var raw = Data(), escaped = false
            while let byte = try input.peek() {
                if byte == 34 {
                    input.advance()
                    if !escaped {
                        guard let text = String(data: raw, encoding: .utf8) else { throw malformed() }
                        return text
                    }
                    var quoted = Data([34]); quoted.append(raw); quoted.append(34)
                    guard let text = try? JSONDecoder().decode(String.self, from: quoted) else { throw malformed() }
                    return text
                }
                guard byte >= 32 else { throw malformed() }
                if byte == 92 {
                    escaped = true; raw.append(byte); input.advance()
                    guard let next = try input.peek() else { throw malformed() }
                    raw.append(next); input.advance()
                } else { raw.append(input.run(until: { $0 == 34 || $0 == 92 || $0 < 32 })) }
            }
            throw malformed()
        }
    }
}
