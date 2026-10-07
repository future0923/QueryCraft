import Foundation
import Observation

/// Presentation only: the inspector and producer always use the paired source page.
@MainActor @Observable
final class WorkspaceKafkaJSONTableModel {
    private(set) var page: WorkspaceDatabaseDataPage?
    private(set) var sourcePage: WorkspaceDatabaseDataPage?
    private(set) var selectionID: String?
    private(set) var schemaID: UUID?
    @ObservationIgnored private let worker = WorkspaceKafkaJSONTableWorker()
    private struct Request: Equatable {
        let revision: UUID?
        let selection: String
        let schema: UUID
    }
    @ObservationIgnored private var currentRequest: Request?

    func load(_ source: WorkspaceDatabaseDataPage?, selectionID: String, schemaID: UUID) async {
        let request = Request(revision: source?.revision, selection: selectionID, schema: schemaID)
        currentRequest = request
        guard let source else { return }
        do {
            let result = try await worker.project(source, context: selectionID, schemaID: schemaID)
            try Task.checkCancellation()
            guard currentRequest == request else { return }
            self.selectionID = selectionID
            self.schemaID = schemaID
            sourcePage = source
            page = result
        } catch is CancellationError {
            // A newer page or mode owns publication.
        } catch {
            // Malformed/unsupported values are handled per row in the worker.
            // Retain the raw page if an unexpected presentation error occurs.
            guard currentRequest == request, !Task.isCancelled else { return }
            self.selectionID = selectionID
            self.schemaID = schemaID
            sourcePage = source
            page = source
        }
    }

    func state(for source: WorkspaceDatabaseDataState, selectionID: String, schemaID: UUID? = nil) -> WorkspaceDatabaseDataState {
        guard source.page != nil else { return source }
        guard self.selectionID == selectionID, let page else { return .loading }
        if source.isStopped { return .stopped(page) }
        let rebuildingSchema = schemaID.map { $0 != self.schemaID } ?? false
        return source.isFetching || rebuildingSchema || sourcePage?.revision != source.page?.revision ? .fetching(page) : .loaded(page)
    }
}

/// JSON parsing and page construction run away from the main actor. Live rows are
/// parsed once, and the schema is frozen after the first JSON batch to keep widths,
/// column order and horizontal scroll stable. Unknown fields retain their raw Value.
actor WorkspaceKafkaJSONTableWorker {
    static let maximumColumns = 128
    private struct ParsedRow {
        let source: WorkspaceDatabaseDataRow
        let fields: [String: WorkspaceDatabaseDataCell]?
    }
    private var context: String?
    private var schemaID: UUID?
    private var streamID: UUID?
    private var paths: [String] = []
    private var liveSchemaFrozen = false
    private var cachedRows: [Int: ParsedRow] = [:]
    private var cachedRevision: UUID?
    private var cachedPage: WorkspaceDatabaseDataPage?

    func project(_ source: WorkspaceDatabaseDataPage, context: String, schemaID: UUID) throws -> WorkspaceDatabaseDataPage {
        try Task.checkCancellation()
        if self.context != context || self.schemaID != schemaID || streamID != source.live?.id {
            self.context = context
            self.schemaID = schemaID
            streamID = source.live?.id
            paths = []
            cachedRows = [:]
            cachedRevision = nil
            cachedPage = nil
            liveSchemaFrozen = false
        }
        if cachedRevision == source.revision, let cachedPage { return cachedPage }
        guard let valueColumn = source.columns.first(where: { $0.name == "value" }) else { return source }

        // Work on local copies so cancellation cannot publish a partial schema/cache.
        var nextPaths = paths
        var knownPaths = Set(paths)
        var nextCache: [Int: ParsedRow] = [:]
        var parsedRows: [ParsedRow] = []
        for index in 0..<source.rowCount {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            guard let row = source.row(at: index) else { continue }
            let parsed: ParsedRow
            if let cached = cachedRows[row.id], cached.source == row { parsed = cached }
            else {
                let fields: [String: WorkspaceDatabaseDataCell]?
                if case let .text(text) = row.value(at: valueColumn.id) {
                    fields = KafkaJSONFieldParser.fields(text)
                } else { fields = nil }
                parsed = ParsedRow(source: row, fields: fields)
            }
            parsedRows.append(parsed)
            nextCache[row.id] = parsed
            if !liveSchemaFrozen, let fields = parsed.fields {
                for path in fields.keys.sorted() where !knownPaths.contains(path) {
                    guard nextPaths.count < Self.maximumColumns else { break }
                    knownPaths.insert(path)
                    nextPaths.append(path)
                }
            }
        }
        let metadata = source.columns.filter { $0.id != valueColumn.id }
        var columns = metadata.enumerated().map {
            WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element.name, type: $0.element.type)
        }
        columns += nextPaths.enumerated().map {
            // Mixed JSON fields have no single database type. Keep the shared
            // timestamp formatter's name-based detection available for them.
            .init(id: metadata.count + $0.offset, name: "value." + $0.element)
        }
        // Always retain the original Value as the last column, including rows
        // successfully expanded. A payload must never appear to become NULL.
        columns.append(.init(id: columns.count, name: "value", type: "TEXT"))
        var rows: [WorkspaceDatabaseDataRow] = []
        rows.reserveCapacity(parsedRows.count)
        for (index, parsed) in parsedRows.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            var values = metadata.map { parsed.source.value(at: $0.id) }
            values += nextPaths.map { parsed.fields?[$0] ?? .null }
            values.append(parsed.source.value(at: valueColumn.id))
            rows.append(.init(id: parsed.source.id, values: values))
        }
        var result = WorkspaceDatabaseDataPage(columns: columns, rows: rows, offset: source.offset,
            limit: source.limit, hasNextPage: source.hasNextPage, sort: source.sort, filter: source.filter)
        result.live = source.live
        try Task.checkCancellation()
        paths = nextPaths
        cachedRows = nextCache
        if source.live != nil, !paths.isEmpty { liveSchemaFrozen = true }
        cachedRevision = source.revision
        cachedPage = result
        return result
    }
}

/// A bounded lexical parser keeps numbers byte exact, including integers beyond
/// Double/Int64 precision. Arrays stay intact; objects become escaped dot paths.
private struct KafkaJSONFieldParser {
    private enum Failure: Error { case unsupported }
    private let bytes: [UInt8]
    private var index = 0
    private var nodeCount = 0
    private var result: [String: WorkspaceDatabaseDataCell] = [:]

    static func fields(_ text: String) -> [String: WorkspaceDatabaseDataCell]? {
        guard text.utf8.count <= 1_048_576 else { return nil }
        var parser = Self(bytes: Array(text.utf8))
        do {
            parser.whitespace()
            guard parser.peek == 123 else { return nil }
            try parser.value(path: [], depth: 0)
            parser.whitespace()
            guard parser.index == parser.bytes.count else { return nil }
            return parser.result
        } catch { return nil }
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
    private mutating func whitespace() {
        while let byte = peek, byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
    }
    private mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard peek == byte else { throw Failure.unsupported }
        index += 1
    }

    private mutating func value(path: [String]?, depth: Int) throws {
        nodeCount += 1
        guard depth <= 32, nodeCount <= 4096 else { throw Failure.unsupported }
        whitespace()
        let start = index
        var cell: WorkspaceDatabaseDataCell
        switch peek {
        case 123:
            index += 1
            whitespace()
            if peek == 125 { index += 1; cell = .text("{}") }
            else {
                var keys = Set<String>()
                repeat {
                    let key = try string()
                    guard keys.insert(key).inserted else { throw Failure.unsupported }
                    try consume(58)
                    try value(path: path.map { $0 + [key] }, depth: depth + 1)
                    whitespace()
                    if peek != 44 { break }
                    index += 1
                } while true
                try consume(125)
                return
            }
        case 91:
            index += 1
            whitespace()
            if peek != 93 {
                repeat {
                    try value(path: nil, depth: depth + 1)
                    whitespace()
                    if peek != 44 { break }
                    index += 1
                } while true
            }
            try consume(93)
            cell = .text(String(decoding: bytes[start..<index], as: UTF8.self))
        case 34: cell = .text(try string())
        case 116: try literal("true"); cell = .text("true")
        case 102: try literal("false"); cell = .text("false")
        case 110: try literal("null"); cell = .null
        default:
            try number()
            cell = .text(String(decoding: bytes[start..<index], as: UTF8.self))
        }
        if let path, !path.isEmpty {
            guard result.count < WorkspaceKafkaJSONTableWorker.maximumColumns else { throw Failure.unsupported }
            result[path.map(Self.escaped).joined(separator: ".")] = cell
        }
    }

    private static func escaped(_ key: String) -> String {
        if key.isEmpty { return "\\e" }
        return key.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ".", with: "\\.")
    }

    private mutating func string() throws -> String {
        whitespace()
        let start = index
        try consume(34)
        var escaped = false
        while let byte = peek {
            index += 1
            if escaped { escaped = false }
            else if byte == 92 { escaped = true }
            else if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
        }
        throw Failure.unsupported
    }

    private mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            guard peek == byte else { throw Failure.unsupported }
            index += 1
        }
    }

    private mutating func number() throws {
        if peek == 45 { index += 1 }
        if peek == 48 { index += 1 }
        else {
            guard let byte = peek, (49...57).contains(byte) else { throw Failure.unsupported }
            digits()
        }
        if peek == 46 {
            index += 1
            let start = index
            digits()
            guard index > start else { throw Failure.unsupported }
        }
        if peek == 101 || peek == 69 {
            index += 1
            if peek == 43 || peek == 45 { index += 1 }
            let start = index
            digits()
            guard index > start else { throw Failure.unsupported }
        }
    }
    private mutating func digits() {
        while let byte = peek, (48...57).contains(byte) { index += 1 }
    }
}
