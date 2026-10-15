import Foundation

/// A frozen import snapshot. Large SQL results spill to an owned temporary file;
/// readers open independent handles so preview and execution cannot race on a cursor.
enum WorkspaceDataImportRows: Sendable {
    case memory([[String?]])
    indirect case padded(WorkspaceDataImportRows, width: Int)
    case disk(WorkspaceDataImportSpool, offsets: [UInt64])

    var count: Int {
        switch self {
        case .memory(let rows): rows.count
        case .padded(let rows, _): rows.count
        case .disk(_, let offsets): offsets.count - 1
        }
    }
    var isDiskBacked: Bool {
        switch self {
        case .disk: true
        case .memory: false
        case .padded(let rows, _): rows.isDiskBacked
        }
    }

    func read(in range: Range<Int>) throws -> [[String?]] {
        guard range.lowerBound >= 0, range.upperBound <= count else { throw Self.corrupt() }
        guard !range.isEmpty else { return [] }
        switch self {
        case .memory(let rows): return Array(rows[range])
        case .padded(let storage, let width):
            return try storage.read(in: range).map { row in
                guard row.count <= width else { throw Self.corrupt() }
                return row + Array(repeating: nil, count: width - row.count)
            }
        case .disk(let spool, let offsets):
            return try autoreleasepool {
                let handle = try FileHandle(forReadingFrom: spool.url)
                defer { try? handle.close() }
                try handle.seek(toOffset: offsets[range.lowerBound])
                let length = offsets[range.upperBound] - offsets[range.lowerBound]
                guard length <= UInt64(Int.max), let data = try handle.read(upToCount: Int(length)), data.count == Int(length) else { throw Self.corrupt() }
                var cursor = 0
                func integer() throws -> UInt64 {
                    guard cursor <= data.count - 8 else { throw Self.corrupt() }
                    let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt64.self) }.littleEndian
                    cursor += 8
                    return value
                }
                var result: [[String?]] = []
                result.reserveCapacity(range.count)
                for _ in range {
                    try Task.checkCancellation()
                    let width = try integer()
                    guard width <= UInt64((data.count - cursor) / 8) else { throw Self.corrupt() }
                    var row: [String?] = []
                    row.reserveCapacity(Int(width))
                    for _ in 0..<width {
                        let size = try integer()
                        if size == UInt64.max { row.append(nil); continue }
                        guard size <= UInt64(data.count - cursor),
                              let value = String(data: data[cursor..<(cursor + Int(size))], encoding: .utf8) else { throw Self.corrupt() }
                        cursor += Int(size)
                        row.append(value)
                    }
                    result.append(row)
                }
                guard cursor == data.count else { throw Self.corrupt() }
                return result
            }
        }
    }

    private static func corrupt() -> WorkspaceDataImportError {
        .invalid("导入暂存数据无法读取，请重新选择文件。", "Cannot read the import snapshot. Select the file again.")
    }
}

final class WorkspaceDataImportSpool: Sendable {
    let url: URL
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "QueryCraftImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = directory.appending(path: "rows.bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
    }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// Used only by one synchronous parser. Buffer writes to avoid a system call per row.
final class WorkspaceDataImportRowBuilder {
    private var memory: [[String?]] = []
    private var memoryBytes = 0
    private var spool: WorkspaceDataImportSpool?
    private var writer: FileHandle?
    private var offsets: [UInt64] = [0]
    private var buffer = Data()
    private(set) var previewRows: [[String?]] = []

    deinit { try? writer?.close() }

    func append(_ row: [String?]) throws {
        if previewRows.count < 200 { previewRows += WorkspaceDataImportFile.preview([row]) }
        if writer == nil {
            memoryBytes += row.reduce(8) { $0 + 8 + ($1?.utf8.count ?? 0) }
            memory.append(row)
            // A threshold for changing storage, never a limit on accepted input.
            if memoryBytes < 4 * 1024 * 1024 { return }
            let spool = try WorkspaceDataImportSpool()
            self.spool = spool
            writer = try FileHandle(forWritingTo: spool.url)
            for existing in memory { try write(existing) }
            memory.removeAll(keepingCapacity: false)
        } else { try write(row) }
    }

    func finish(columns: [String], padsMissing: Bool = false) throws -> WorkspaceDataImportFile {
        guard let spool, let writer else {
            let rows = padsMissing ? memory.map { $0 + Array(repeating: nil, count: max(0, columns.count - $0.count)) } : memory
            return try WorkspaceDataImportFile(columns: columns, rows: rows)
        }
        if !buffer.isEmpty { try writer.write(contentsOf: buffer); buffer.removeAll() }
        try writer.close()
        self.writer = nil
        let disk = WorkspaceDataImportRows.disk(spool, offsets: offsets)
        let storage: WorkspaceDataImportRows = padsMissing ? .padded(disk, width: columns.count) : disk
        let preview = padsMissing ? previewRows.map { $0 + Array(repeating: nil, count: max(0, columns.count - $0.count)) } : previewRows
        return try WorkspaceDataImportFile(columns: columns, storage: storage, previewRows: preview)
    }

    private func write(_ row: [String?]) throws {
        let start = buffer.count
        appendInteger(UInt64(row.count))
        for value in row {
            guard let value else { appendInteger(UInt64.max); continue }
            appendInteger(UInt64(value.utf8.count))
            buffer.append(contentsOf: value.utf8)
        }
        offsets.append(offsets.last! + UInt64(buffer.count - start))
        if buffer.count >= 1024 * 1024 {
            try writer?.write(contentsOf: buffer)
            let retainsBuffer = buffer.count <= 4 * 1024 * 1024
            buffer.removeAll(keepingCapacity: retainsBuffer)
        }
    }

    private func appendInteger(_ value: UInt64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { buffer.append(contentsOf: $0) }
    }
}
