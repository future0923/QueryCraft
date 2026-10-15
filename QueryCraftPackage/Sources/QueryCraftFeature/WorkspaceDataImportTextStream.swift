import Foundation
import CoreFoundation

/// Small synchronous input window used on the import reader actor, never by a view.
struct WorkspaceDataImportByteReader {
    let handle: FileHandle?
    private var buffer: Data
    private var cursor = 0
    private var eof: Bool
    private(set) var position = 0

    init(handle: FileHandle) { self.handle = handle; buffer = Data(); eof = false }
    init(data: Data) { handle = nil; buffer = data; eof = true }

    mutating func peek(_ offset: Int = 0) throws -> UInt8? {
        if position.isMultiple(of: 65_536) { try Task.checkCancellation() }
        while cursor + offset >= buffer.count && !eof {
            buffer = Data(buffer.dropFirst(cursor)); cursor = 0
            let chunk = try autoreleasepool { try handle?.read(upToCount: 65_536) ?? Data() }
            eof = chunk.isEmpty
            buffer.append(chunk)
        }
        return cursor + offset < buffer.count ? buffer[cursor + offset] : nil
    }
    mutating func advance(_ count: Int = 1) { cursor += count; position += count }
    mutating func skipBOM() throws {
        if try peek() == 0xef, try peek(1) == 0xbb, try peek(2) == 0xbf { advance(3) }
    }
    mutating func reset() throws {
        guard let handle else { cursor = 0; position = 0; try skipBOM(); return }
        try handle.seek(toOffset: 0)
        buffer = Data(); cursor = 0; position = 0; eof = false
        try skipBOM()
    }
    private func runEnd(until stop: (UInt8) -> Bool) -> Int {
        buffer.withUnsafeBytes { raw -> Int in
            let bytes = raw.bindMemory(to: UInt8.self)
            var end = cursor
            while end < bytes.count && !stop(bytes[end]) { end += 1 }
            return end
        }
    }
    mutating func run(until stop: (UInt8) -> Bool) -> Data {
        let end = runEnd(until: stop)
        let result = Data(buffer[cursor..<end])
        advance(end - cursor)
        return result
    }
    mutating func skipRun(until stop: (UInt8) -> Bool) {
        advance(runEnd(until: stop) - cursor)
    }

}

/// Non-UTF-8 input is transcoded a window at a time to an owned UTF-8 file.
/// Keep this owner alive until parsing has finished.
final class WorkspaceDataImportTextStream {
    let handle: FileHandle
    private let temporary: WorkspaceDataImportSpool?

    init(handle original: FileHandle, encoding: WorkspaceDataImportOptions.Encoding) throws {
        let prefix = try original.read(upToCount: 3) ?? Data()
        try original.seek(toOffset: 0)
        let resolved: String.Encoding
        switch encoding {
        case .automatic:
            if prefix.starts(with: [0xff, 0xfe]) { resolved = .utf16LittleEndian }
            else if prefix.starts(with: [0xfe, 0xff]) { resolved = .utf16BigEndian }
            else { resolved = .utf8 }
        case .utf8: resolved = .utf8
        case .utf16LE: resolved = .utf16LittleEndian
        case .utf16BE: resolved = .utf16BigEndian
        case .gb18030:
            resolved = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
        if resolved == .utf8 { handle = original; temporary = nil; return }
        let temporary = try WorkspaceDataImportSpool()
        let writer = try FileHandle(forWritingTo: temporary.url)
        defer { try? writer.close() }
        var pending = Data(), first = true
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try original.read(upToCount: 65_536) ?? Data() }
            pending.append(chunk)
            if pending.isEmpty { break }
            let atEnd = chunk.isEmpty
            try autoreleasepool {
                var decoded: String?, used = 0
                for suffix in 0...(atEnd ? 0 : min(3, pending.count)) {
                    let length = pending.count - suffix
                    if let text = String(data: pending.prefix(length), encoding: resolved) {
                        decoded = text; used = length; break
                    }
                }
                guard var text = decoded, used > 0 else {
                    throw WorkspaceDataImportError.invalid("无法按所选编码读取文件，请调整文件编码。", "Cannot decode the file. Choose the correct encoding.")
                }
                // Foundation may replace an incomplete UTF-16 surrogate; never split a pair.
                if resolved == .utf16LittleEndian || resolved == .utf16BigEndian {
                    var length = pending.count - pending.count % 2
                    if !atEnd && length >= 2 {
                        let a = UInt16(pending[length - 2]), b = UInt16(pending[length - 1])
                        let unit = resolved == .utf16LittleEndian ? a | b << 8 : a << 8 | b
                        if (0xd800...0xdbff).contains(unit) { length -= 2 }
                    }
                    guard length > 0, let exact = String(data: pending.prefix(length), encoding: resolved) else {
                        throw WorkspaceDataImportError.invalid("UTF-16 文件编码无效。", "Invalid UTF-16 input.")
                    }
                    text = exact; used = length
                    if atEnd && used != pending.count { throw WorkspaceDataImportError.invalid("UTF-16 文件被截断。", "Truncated UTF-16 input.") }
                }
                if first { if text.first == "\u{feff}" { text.removeFirst() }; first = false }
                try writer.write(contentsOf: Data(text.utf8))
                pending = Data(pending.dropFirst(used))
            }
            if atEnd { break }
        }
        try writer.close()
        self.temporary = temporary
        handle = try FileHandle(forReadingFrom: temporary.url)
    }
    deinit { if temporary != nil { try? handle.close() } }
}

/// Header/range handling is shared by delimited text, JSON array rows and worksheets.
final class WorkspaceDataImportTableBuilder {
    let options: WorkspaceDataImportOptions
    private let builder = WorkspaceDataImportRowBuilder()
    private var columns: [String]?
    private var count = 0, width = 0, selectedMin = Int.max, selectedMax = 0
    private let padsMissing: Bool
    var nextRecordNumber: Int { count + 1 }

    init(options: WorkspaceDataImportOptions, names: [String]? = nil, padsMissing: Bool = false) throws {
        guard options.headerRow >= 0, options.firstDataRow >= 1, options.lastDataRow >= 0,
              options.lastDataRow == 0 || options.lastDataRow >= options.firstDataRow,
              names != nil || options.headerRow == 0 || options.firstDataRow > options.headerRow else {
            throw WorkspaceDataImportError.invalid("标题行或数据行范围无效。", "Invalid header or data row range.")
        }
        self.options = options; columns = names; self.padsMissing = padsMissing
    }
    func append(_ row: [String?]) throws {
        count += 1; width = max(width, row.count)
        if columns == nil && count == options.headerRow {
            columns = row.map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        }
        if count >= options.firstDataRow && (options.lastDataRow == 0 || count <= options.lastDataRow) {
            selectedMin = min(selectedMin, row.count); selectedMax = max(selectedMax, row.count)
            try builder.append(options.trimsWhitespace || options.emptyAsNull ? row.map(options.normalized) : row)
        }
    }
    func finish() throws -> WorkspaceDataImportFile {
        if columns == nil && options.headerRow > 0 {
            throw WorkspaceDataImportError.invalid("找不到指定的标题行。", "The selected header row does not exist.")
        }
        let columns = columns ?? (0..<width).map { "column_\($0 + 1)" }
        if !padsMissing && selectedMin != Int.max && (selectedMin != columns.count || selectedMax != columns.count) {
            throw WorkspaceDataImportError.invalid("数据行的字段数量不一致。", "Rows have inconsistent column counts.")
        }
        // Worksheets use their maximum used width, including a sparse header.
        let names = padsMissing && columns.count < width ? columns + Array(repeating: "", count: width - columns.count) : columns
        return try builder.finish(columns: names, padsMissing: padsMissing)
    }
}
