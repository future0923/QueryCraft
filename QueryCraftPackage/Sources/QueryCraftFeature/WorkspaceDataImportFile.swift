import Foundation
import CoreFoundation

/// Import data is a frozen, validated snapshot. Execution never rereads a changed file.
struct WorkspaceDataImportFile: Sendable {
    let columns: [String]
    private let storage: WorkspaceDataImportRows
    let previewRows: [[String?]]
    var rowCount: Int { storage.count }
    var rows: [[String?]] { get throws { try readRows(in: 0..<rowCount) } }
    var isDiskBacked: Bool { storage.isDiskBacked }

    func readRows(in range: Range<Int>) throws -> [[String?]] { try storage.read(in: range) }
    var sheetNames: [String] = []

    init(columns: [String], rows: [[String?]], sheetNames: [String] = []) throws {
        guard !columns.isEmpty,
              !columns.contains(where: { $0.isEmpty }), Set(columns).count == columns.count else {
            throw WorkspaceDataImportError.invalid("字段名为空或重复，请调整标题行。", "Column names are empty or duplicated. Adjust the header row.")
        }
        guard rows.allSatisfy({ $0.count == columns.count }) else {
            throw WorkspaceDataImportError.invalid("数据行的字段数量不一致。", "Rows have inconsistent column counts.")
        }
        self.columns = columns
        self.storage = .memory(rows)
        self.previewRows = Self.preview(rows.prefix(200))
        self.sheetNames = sheetNames
    }

    init(columns: [String], storage: WorkspaceDataImportRows, previewRows: [[String?]]) throws {
        guard !columns.isEmpty, !columns.contains(where: { $0.isEmpty }), Set(columns).count == columns.count else {
            throw WorkspaceDataImportError.invalid("字段名为空或重复，请调整标题行。", "Column names are empty or duplicated. Adjust the header row.")
        }
        self.columns = columns
        self.storage = storage
        self.previewRows = previewRows
    }

    static func preview(_ rows: some Sequence<[String?]>) -> [[String?]] {
        rows.map { $0.map { value in value.map { String($0.prefix(512)) } } }
    }

}

enum WorkspaceDataImportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, tsv, text, json, excel, sql
    var id: String { rawValue }
    var title: String {
        switch self {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .text: AppCopy.current.text("分隔文本", "Delimited Text")
        case .json: "JSON / JSONL"
        case .excel: "Excel (XLSX / XLSM)"
        case .sql: "SQL INSERT"
        }
    }
    var usesRows: Bool { self != .sql }
    var isDelimited: Bool { [.csv, .tsv, .text].contains(self) }
    static func detect(_ url: URL) -> Self {
        switch url.pathExtension.lowercased() {
        case "tsv": .tsv
        case "txt": .text
        case "json", "jsonl", "ndjson": .json
        case "xlsx", "xlsm", "xls": .excel
        case "sql": .sql
        default: .csv
        }
    }
}

struct WorkspaceDataImportOptions: Equatable, Sendable {
    enum Encoding: String, CaseIterable, Identifiable, Sendable {
        case automatic, utf8, gb18030, utf16LE, utf16BE
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: AppCopy.current.text("自动（UTF-8 / BOM）", "Auto (UTF-8 / BOM)")
            case .utf8: "UTF-8"
            case .gb18030: "GB18030 / GBK"
            case .utf16LE: "UTF-16 LE"
            case .utf16BE: "UTF-16 BE"
            }
        }
    }
    var format = WorkspaceDataImportFormat.csv
    var encoding = Encoding.automatic
    var delimiter = ","
    var headerRow = 1
    var firstDataRow = 2
    var lastDataRow = 0
    var trimsWhitespace = false
    var emptyAsNull = false
    var nullToken = "NULL"
    var sheetIndex = 0
    var previewRows = 50
    // MySQL dumps conventionally use backslash escapes; standard SQL does not.
    var sqlBackslashEscapes = true

    func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = trimsWhitespace ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value
        return emptyAsNull && result.isEmpty ? nil : result
    }
}

enum WorkspaceDataImportError: LocalizedError {
    case invalid(String, String)
    var errorDescription: String? {
        switch self {
        case let .invalid(zh, en): AppCopy.current.text(zh, en)
        }
    }
}

actor WorkspaceDataImportReader {
    func read(url: URL, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if options.format == .excel { return try WorkspaceXLSXImporter.read(url: url, options: options) }
        let source = try WorkspaceDataImportTextStream(handle: handle, encoding: options.encoding)
        defer { withExtendedLifetime(source) {} }
        switch options.format {
        case .csv, .tsv, .text: return try WorkspaceDelimitedImporter.read(handle: source.handle, options: options)
        case .json: return try WorkspaceJSONImporter.read(handle: source.handle, options: options)
        case .sql: return try WorkspaceSQLImporter.read(handle: source.handle, options: options)
        case .excel: fatalError("Handled above")
        }
    }

    static func decode(_ data: Data, encoding: WorkspaceDataImportOptions.Encoding) throws -> String {
        let resolved: String.Encoding
        switch encoding {
        case .automatic:
            if data.starts(with: [0xff, 0xfe]) { resolved = .utf16LittleEndian }
            else if data.starts(with: [0xfe, 0xff]) { resolved = .utf16BigEndian }
            else { resolved = .utf8 }
        case .utf8: resolved = .utf8
        case .utf16LE: resolved = .utf16LittleEndian
        case .utf16BE: resolved = .utf16BigEndian
        case .gb18030:
            resolved = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
        guard var text = String(data: data, encoding: resolved) else {
            throw WorkspaceDataImportError.invalid("无法按所选编码读取文件，请调整文件编码。", "Cannot decode the file. Choose the correct encoding.")
        }
        if text.first == "\u{feff}" { text.removeFirst() }
        return text
    }

    static func table(_ records: [[String?]], options: WorkspaceDataImportOptions, names: [String]? = nil) throws -> WorkspaceDataImportFile {
        guard options.headerRow >= 0, options.firstDataRow >= 1, options.lastDataRow >= 0,
              options.lastDataRow == 0 || options.lastDataRow >= options.firstDataRow,
              names != nil || options.headerRow == 0 || options.firstDataRow > options.headerRow else {
            throw WorkspaceDataImportError.invalid("标题行或数据行范围无效。", "Invalid header or data row range.")
        }
        let width = names?.count ?? records.map(\.count).max() ?? 0
        let columns: [String]
        if let names { columns = names }
        else if options.headerRow > 0 {
            guard options.headerRow <= records.count else {
                throw WorkspaceDataImportError.invalid("找不到指定的标题行。", "The selected header row does not exist.")
            }
            columns = records[options.headerRow - 1].map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        } else { columns = (0..<width).map { "column_\($0 + 1)" } }
        let end = options.lastDataRow == 0 ? records.count : min(options.lastDataRow, records.count)
        let start = min(options.firstDataRow - 1, end)
        return try WorkspaceDataImportFile(columns: columns, rows: records[start..<end].map { $0.map(options.normalized) })
    }
}
