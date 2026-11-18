import Foundation
import CryptoKit

/// One consumer per job. No row collection or shared-string table grows with the result.
actor MCPExportWriter {
    private let request: MCPExportRequest
    private let file: FileHandle
    private var archive: WorkspaceStreamingZIPWriter?
    private var entry: WorkspaceStreamingZIPWriter.Entry?
    private var queryIndex = -1
    private var sourceColumns: [WorkspaceDatabaseDataColumn]?
    private var columns: [MCPExportColumn] = []
    private(set) var counts: [Int]
    private(set) var textFallbackCells = 0
    private var rawBytes = 0
    private var resolvedColumns: [[MCPExportColumn]] = []
    private var closed = false

    init(request: MCPExportRequest, temporaryURL: URL) throws {
        self.request = request
        counts = Array(repeating: 0, count: request.queries.count)
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WorkspaceDataExportError.unableToCreateFile
        }
        file = try FileHandle(forWritingTo: temporaryURL)
        if request.format == .xlsx || request.queries.count > 1 {
            archive = WorkspaceStreamingZIPWriter(fileHandle: file, maximumFileBytes: request.limits.fileBytes, maximumRawBytes: request.limits.rawBytes)
        }
    }

    func beginQuery(_ index: Int) throws {
        guard index == queryIndex + 1, index < counts.count, entry == nil, !closed else { throw WorkspaceDataExportError.missingRow }
        queryIndex = index; sourceColumns = nil; columns = []
    }

    func consume(_ batch: WorkspaceDatabaseDataBatch) throws {
        try Task.checkCancellation()
        guard queryIndex >= 0, !closed else { throw WorkspaceDataExportError.missingRow }
        if sourceColumns == nil { try beginColumns(batch.columns, sample: batch.rows.first) }
        guard sourceColumns == batch.columns else { throw WorkspaceDataExportError.changedColumns }
        var pending = Data()
        pending.reserveCapacity(256 * 1_024)
        for row in batch.rows {
            try Task.checkCancellation()
            guard row.values.count == batch.columns.count else { throw WorkspaceDataExportError.missingColumns }
            guard counts.reduce(0, +) < request.limits.rows else { throw MCPFailure("Export row limit exceeded; no file was published.", code: .resultTooLarge) }
            if request.format == .xlsx, counts[queryIndex] >= 1_048_575 { throw WorkspaceDataExportError.fileTooLarge }
            var bytes = 0
            for c in batch.columns.indices {
                switch row.value(at: c) {
                case .null: break
                case let .text(value): bytes += value.utf8.count
                case .binary: throw WorkspaceDataExportError.unavailableColumn(batch.columns[c].name)
                }
                guard bytes <= MCPExportLimits.rowBytes else { throw WorkspaceDataExportError.fileTooLarge }
            }
            var data = Data()
            if request.format == .xlsx {
                let number = counts[queryIndex] + 2
                data.appendUTF8("<row r=\"\(number)\">")
                for (index, c) in columns.enumerated() {
                    let ref = WorkspaceXLSXExporter.columnLetters(for: index) + String(number)
                    switch row.value(at: c.sourceIndex) {
                    case .null: break
                    case let .text(value): try appendCell(value, ref: ref, column: c, to: &data)
                    case .binary: throw WorkspaceDataExportError.unavailableColumn(c.title)
                    }
                }
                data.appendUTF8("</row>")
            } else {
                let fields = try columns.map { c -> String in
                    switch row.value(at: c.sourceIndex) {
                    case .null: return "\"\\N\""
                    case let .text(value): return Self.csv(value)
                    case .binary: throw WorkspaceDataExportError.unavailableColumn(c.title)
                    }
                }
                data.appendUTF8(fields.joined(separator: ",") + "\r\n")
            }
            pending.append(data)
            if pending.count >= 256 * 1_024 { try write(pending); pending.removeAll(keepingCapacity: true) }
            counts[queryIndex] += 1
        }
        if !pending.isEmpty { try write(pending) }
    }

    func endQuery(_ result: WorkspaceQueryExecutionResult) throws {
        if sourceColumns == nil { try beginColumns(result.columns, sample: nil) }
        guard sourceColumns == result.columns, result.rowCount == counts[queryIndex] else { throw WorkspaceDataExportError.missingRow }
        if let expected = request.queries[queryIndex].expectedRows, expected != counts[queryIndex] {
            throw MCPFailure("Query \(queryIndex + 1) exported \(counts[queryIndex]) rows; expected \(expected). No file was published.")
        }
        if request.format == .xlsx {
            let last = WorkspaceXLSXExporter.columnLetters(for: columns.count - 1)
            try write(Data("</sheetData><autoFilter ref=\"A1:\(last)\(counts[queryIndex] + 1)\"/></worksheet>".utf8))
        }
        if var finished = entry { try archive?.finishEntry(&finished); entry = nil }
    }

    func finish() throws -> Data {
        try Task.checkCancellation()
        guard queryIndex == counts.count - 1, entry == nil, !closed else { throw WorkspaceDataExportError.missingRow }
        let manifest: MCPJSONValue = .object([
            "version": 1, "format": .string(request.format.rawValue), "timezone": .string(request.timezone),
            "consistency": .string(request.consistency.rawValue), "rows": .int(counts.reduce(0, +)),
            "text_fallback_cells": .int(textFallbackCells),
            "csv_encoding": "UTF-8 BOM", "csv_null": "\\N", "csv_escape": "Backslashes doubled in non-NULL values; spreadsheet-risk fields prefixed with one TAB inside quotes. Remove that prefix before unescaping backslashes. CSV consumers must import text columns explicitly; XLSX is preferred for exact spreadsheet types.",
            "queries": .array(request.queries.enumerated().map { i, q in .object([
                "name": .string(q.name), "rows": .int(counts[i]),
                "csv_file": .string("\(i + 1)-\(q.name).csv"),
                "columns": .array(resolvedColumns[i].map { .object(["source_index": .int($0.sourceIndex), "title": .string($0.title), "type": .string($0.kind.rawValue)]) })
            ]) })
        ])
        let manifestData = try JSONEncoder().encode(manifest)
        if request.format == .xlsx {
            let n = request.queries.count
            try archive?.writeEntry(path: "[Content_Types].xml", data: WorkspaceXLSXExporter.contentTypesXML(sheetCount: n))
            try archive?.writeEntry(path: "_rels/.rels", data: WorkspaceXLSXExporter.packageRelsXML())
            try archive?.writeEntry(path: "xl/workbook.xml", data: WorkspaceXLSXExporter.workbookXML(sheetNames: request.queries.map(\.name)))
            try archive?.writeEntry(path: "xl/_rels/workbook.xml.rels", data: WorkspaceXLSXExporter.workbookRelsXML(sheetCount: n))
            try archive?.writeEntry(path: "xl/styles.xml", data: Self.styles)
        } else if archive != nil {
            try archive?.writeEntry(path: "manifest.json", data: manifestData)
        }
        try archive?.finish()
        try file.synchronize(); try file.close(); closed = true
        return manifestData
    }

    func abort() { if !closed { try? file.close(); closed = true }; archive = nil; entry = nil }

    private func beginColumns(_ source: [WorkspaceDatabaseDataColumn], sample: WorkspaceDatabaseDataRow?) throws {
        guard !source.isEmpty, source.count <= 256 else { throw WorkspaceDataExportError.missingColumns }
        sourceColumns = source
        columns = request.queries[queryIndex].columns ?? source.enumerated().map { i, c in
            MCPExportColumn(sourceIndex: i, title: c.name, kind: .text, dateFormat: nil, width: nil)
        }
        guard columns.allSatisfy({ source.indices.contains($0.sourceIndex) }) else { throw WorkspaceDataExportError.missingColumns }
        resolvedColumns.append(columns)
        if request.format == .xlsx {
            entry = try archive?.beginEntry(path: "xl/worksheets/sheet\(queryIndex + 1).xml")
            var data = Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><cols>".utf8)
            for (i, c) in columns.enumerated() {
                let sampleWidth: Int
                if let sample, case let .text(value) = sample.value(at: c.sourceIndex) { sampleWidth = min(40, value.count) } else { sampleWidth = 12 }
                let width = c.width ?? min(48, max(12, c.title.count * 2 + 2, sampleWidth + 2))
                data.appendUTF8("<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(width)\" customWidth=\"1\"/>")
            }
            data.appendUTF8("</cols><sheetData><row r=\"1\">")
            for (i, c) in columns.enumerated() { try Self.appendText(c.title, ref: WorkspaceXLSXExporter.columnLetters(for: i) + "1", style: 1, to: &data) }
            data.appendUTF8("</row>"); try write(data)
        } else {
            if archive != nil { entry = try archive?.beginEntry(path: "\(queryIndex + 1)-\(request.queries[queryIndex].name).csv") }
            try write(Data([0xef, 0xbb, 0xbf]))
            try write(Data((columns.map { Self.csv($0.title) }.joined(separator: ",") + "\r\n").utf8))
        }
    }

    private func write(_ data: Data) throws {
        guard data.count <= request.limits.rawBytes - rawBytes else { throw WorkspaceDataExportError.fileTooLarge }
        rawBytes += data.count
        if var active = entry { try archive?.write(data, to: &active); entry = active }
        else {
            guard archive == nil, rawBytes <= request.limits.fileBytes else { throw WorkspaceDataExportError.fileTooLarge }
            try file.write(contentsOf: data)
        }
    }

    private func appendCell(_ value: String, ref: String, column: MCPExportColumn, to data: inout Data) throws {
        if column.kind == .integer, value.range(of: #"^-?(?:0|[1-9][0-9]{0,14})$"#, options: .regularExpression) != nil {
            data.appendUTF8("<c r=\"\(ref)\" t=\"n\"><v>\(value)</v></c>"); return
        }
        if [.date, .datetime].contains(column.kind), column.dateFormat != nil, let serial = Self.excelDate(value, dateOnly: column.kind == .date) {
            let style = column.dateFormat == "yyyy-mm-dd" ? 2 : 3
            data.appendUTF8("<c r=\"\(ref)\" s=\"\(style)\" t=\"n\"><v>\(serial)</v></c>"); return
        }
        if column.kind != .text { textFallbackCells += 1 }
        try Self.appendText(value, ref: ref, style: 0, to: &data)
    }

    private static func appendText(_ value: String, ref: String, style: Int, to data: inout Data) throws {
        guard value.utf16.count <= 32_767 else { throw WorkspaceDataExportError.fileTooLarge }
        data.appendUTF8("<c r=\"\(ref)\" t=\"inlineStr\" s=\"\(style)\"><is><t xml:space=\"preserve\">")
        data.appendSpreadsheetText(value); data.appendUTF8("</t></is></c>")
    }

    static func csv(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\\", with: "\\\\")
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let risky = first.map { "=+-@＝＋－＠0123456789".contains($0) } ?? false
        if risky || value.first.map({ $0.isWhitespace }) == true { text = "\t" + text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func excelDate(_ value: String, dateOnly: Bool) -> Double? {
        let pattern = dateOnly ? #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"# : #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let parts = value.split(whereSeparator: { "- :".contains($0) }).compactMap { Int($0) }
        guard parts.count == (dateOnly ? 3 : 6), parts[0] >= 1900, parts[0] <= 9999 else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: dateOnly ? 0 : parts[3], minute: dateOnly ? 0 : parts[4], second: dateOnly ? 0 : parts[5])
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components,
              let base = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30)),
              let minimum = calendar.date(from: DateComponents(year: 1900, month: 3, day: 1)), date >= minimum else { return nil }
        return date.timeIntervalSince(base) / 86_400
    }

    private static var styles: Data {
        var xml = String(decoding: WorkspaceXLSXExporter.stylesXML(), as: UTF8.self)
        xml = xml.replacingOccurrences(of: "<fonts", with: "<numFmts count=\"2\"><numFmt numFmtId=\"164\" formatCode=\"yyyy-mm-dd\"/><numFmt numFmtId=\"165\" formatCode=\"yyyy-mm-dd hh:mm:ss\"/></numFmts><fonts")
        xml = xml.replacingOccurrences(of: "<cellXfs count=\"2\">", with: "<cellXfs count=\"4\">")
        xml = xml.replacingOccurrences(of: "</cellXfs>", with: "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/><xf numFmtId=\"165\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs>")
        return Data(xml.utf8)
    }
}
