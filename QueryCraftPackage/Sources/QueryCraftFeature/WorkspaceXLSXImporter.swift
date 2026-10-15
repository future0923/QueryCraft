import Foundation
import zlib

/// Reads OOXML without launching Excel, evaluating formulas, or extracting archive paths.
enum WorkspaceXLSXImporter {
    static func read(_ data: Data, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        try read(Archive(data), options: options)
    }
    static func read(url: URL, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        try read(Archive(url: url), options: options)
    }
    private static func read(_ zip: Archive, options: WorkspaceDataImportOptions) throws -> WorkspaceDataImportFile {
        var sheets: [(String, String)] = [], date1904 = false
        try xml(zip, "xl/workbook.xml", start: { name, attrs in
            if name == "sheet", let title = attrs["name"], let id = attrs["r:id"] { sheets.append((title, id)) }
            if name == "workbookPr" { date1904 = ["1", "true"].contains(attrs["date1904"] ?? "") }
        })
        var paths: [String: String] = [:]
        try xml(zip, "xl/_rels/workbook.xml.rels", start: { name, attrs in
            guard name == "Relationship", let id = attrs["Id"], let target = attrs["Target"], attrs["TargetMode"] != "External" else { return }
            paths[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        })
        guard sheets.indices.contains(options.sheetIndex), let path = paths[sheets[options.sheetIndex].1] else { throw invalid("找不到工作表。", "Worksheet not found.") }
        let sharedBuilder = WorkspaceDataImportRowBuilder()
        var richText = "", readingText = false, phonetic = false
        if zip.contains("xl/sharedStrings.xml") {
            try xml(zip, "xl/sharedStrings.xml", start: { name, _ in
                if name == "si" { richText = "" }
                if name == "rPh" { phonetic = true }
                if name == "t" { readingText = !phonetic }
            }, text: { if readingText { richText += $0 } }, end: { name in
                if name == "t" { readingText = false }
                if name == "rPh" { phonetic = false }
                if name == "si" { try sharedBuilder.append([decodeEscapes(richText)]) }
            })
        }
        let shared = SharedStrings(try sharedBuilder.finish(columns: ["value"]))
        var dateStyles: [Int: DateStyle] = [:]
        var customFormats: [Int: String] = [:], inCellXfs = false, styleIndex = 0
        if zip.contains("xl/styles.xml") {
            try xml(zip, "xl/styles.xml", start: { name, attrs in
                if name == "numFmt", let id = Int(attrs["numFmtId"] ?? ""), let code = attrs["formatCode"] { customFormats[id] = code }
                if name == "cellXfs" { inCellXfs = true }
                if name == "xf", inCellXfs {
                    let id = Int(attrs["numFmtId"] ?? "") ?? 0
                    let code = (customFormats[id] ?? "").lowercased()
                        .replacingOccurrences(of: #""[^"]*"|\\.|\[[^\]]*\]"#, with: "", options: .regularExpression)
                    if id == 46 || (customFormats[id] ?? "").range(of: #"\[[hms]+\]"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        dateStyles[styleIndex] = .duration
                    } else if (18...21).contains(id) || id == 45 || id == 47 {
                        dateStyles[styleIndex] = .time
                    } else if (14...22).contains(id) || (27...36).contains(id) || (50...58).contains(id) || code.range(of: "[ymdhs]", options: .regularExpression) != nil {
                        dateStyles[styleIndex] = code.range(of: "[yd]", options: .regularExpression) == nil && code.range(of: "[hs]", options: .regularExpression) != nil ? .time : .date
                    }
                    styleIndex += 1
                }
            }, end: { if $0 == "cellXfs" { inCellXfs = false } })
        }
        let records = try WorkspaceDataImportTableBuilder(options: options, padsMissing: true)
        let dateFormatter = DateFormatter(), timeFormatter = DateFormatter()
        for formatter in [dateFormatter, timeFormatter] {
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        }
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; timeFormatter.dateFormat = "HH:mm:ss.SSS"
        var row: [String?] = []
        var cellType = "", cellStyle = 0, cellIndex = 0, cellValue = "", inline = ""
        var inValue = false, inText = false, hasValue = false, hasFormula = false
        var rowNumber = 0, lastRowNumber = 0
        try xml(zip, path, start: { name, attrs in
            if name == "row" {
                row = []
                rowNumber = Int(attrs["r"] ?? "") ?? (lastRowNumber + 1)
                guard rowNumber > lastRowNumber, rowNumber <= 1_048_576 else { throw invalid("工作表行号无效。", "Invalid worksheet row number.") }
            }
            if name == "c" {
                cellType = attrs["t"] ?? "n"; cellStyle = Int(attrs["s"] ?? "") ?? 0
                cellValue = ""; inline = ""; hasValue = false; hasFormula = false
                cellIndex = try columnIndex(attrs["r"] ?? "", fallback: row.count)
                guard cellIndex >= row.count, cellIndex < 16_384 else { throw invalid("工作表列地址无效。", "Invalid worksheet cell address.") }
            }
            if name == "v" { inValue = true; hasValue = true }
            if name == "rPh" { phonetic = true }
            if name == "t" { inText = !phonetic }
            if name == "f" { hasFormula = true }
        }, text: { text in
            if inValue { cellValue += text }
            if inText { inline += text }
        }, end: { name in
            if name == "v" { inValue = false }
            if name == "t" { inText = false }
            if name == "rPh" { phonetic = false }
            if name == "c" {
                if hasFormula && !hasValue { throw invalid("公式没有缓存结果，请在 Excel 中重新计算并保存。", "A formula has no cached value. Recalculate and save in Excel.") }
                let value: String?
                switch cellType {
                case "s":
                    guard let index = Int(cellValue), index >= 0 && index < shared.file.rowCount else { throw invalid("共享字符串索引无效。", "Invalid shared-string index.") }
                    value = try shared.value(at: index)
                case "inlineStr": value = decodeEscapes(inline)
                case "b":
                    guard cellValue == "0" || cellValue == "1" else { throw invalid("布尔单元格无效。", "Invalid boolean cell.") }
                    value = cellValue == "1" ? "true" : "false"
                case "e": throw invalid("工作表包含错误单元格：\(cellValue)", "The worksheet contains an error cell: \(cellValue)")
                default:
                    if !hasValue { value = nil }
                    else if cellType == "n", let style = dateStyles[cellStyle] { value = try dateString(cellValue, date1904: date1904, style: style, formatter: style == .time ? timeFormatter : dateFormatter) }
                    else { value = cellType == "str" ? decodeEscapes(cellValue) : cellValue }
                }
                while row.count < cellIndex { row.append(nil) }
                // NULL markers are explicit import options; an empty cell remains NULL.
                row.append(value == options.nullToken && !options.nullToken.isEmpty && rowNumber != options.headerRow ? nil : value)
            }
            if name == "row" {
                while lastRowNumber < rowNumber - 1 { try records.append([]); lastRowNumber += 1 }
                try records.append(row)
                lastRowNumber = rowNumber
            }
        })
        var result = try records.finish()
        result.sheetNames = sheets.map(\.0)
        return result
    }

    private final class SharedStrings {
        let file: WorkspaceDataImportFile
        private var pages: [Int: [String?]] = [:], costs: [Int: Int] = [:]
        private var order: [Int] = []
        private var bytes = 0
        init(_ file: WorkspaceDataImportFile) { self.file = file }
        func value(at index: Int) throws -> String? {
            let page = index / 64
            if let values = pages[page] {
                order.removeAll { $0 == page }; order.append(page)
                return values[index % 64]
            }
            let values = try file.readRows(in: page*64..<min(page*64+64,file.rowCount)).map { $0[0] }
            let cost = values.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
            if cost <= 4 * 1_048_576 {
                while !order.isEmpty && (order.count >= 8 || bytes + cost > 4 * 1_048_576) {
                    let removed = order.removeFirst()
                    pages.removeValue(forKey: removed); bytes -= costs.removeValue(forKey: removed) ?? 0
                }
                pages[page] = values; costs[page] = cost; order.append(page); bytes += cost
            }
            return values[index % 64]
        }
    }

    private static func columnIndex(_ reference: String, fallback: Int) throws -> Int {
        if reference.isEmpty { return fallback }
        var value = 0
        for byte in reference.utf8.prefix(while: { (65...90).contains($0) }) {
            value = value * 26 + Int(byte - 64)
            guard value <= 16_384 else { throw invalid("工作表列地址超出 Excel 格式范围。", "Worksheet column address exceeds the Excel format range.") }
        }
        guard value > 0 else { throw invalid("单元格地址无效。", "Invalid cell address.") }
        return value - 1
    }

    private enum DateStyle { case date, time, duration }

    private static func decodeEscapes(_ text: String) -> String {
        guard text.contains("_x") else { return text }
        let units = Array(text.utf16)
        var result: [UInt16] = [], index = 0
        while index < units.count {
            if index + 6 < units.count, units[index] == 95, units[index + 1] == 120, units[index + 6] == 95,
               let value = UInt16(String(decoding: units[index + 2..<index + 6], as: UTF16.self), radix: 16) {
                result.append(value); index += 7
            } else { result.append(units[index]); index += 1 }
        }
        return String(decoding: result, as: UTF16.self)
    }

    private static func dateString(_ value: String, date1904: Bool, style: DateStyle, formatter: DateFormatter) throws -> String {
        guard style != .duration else { throw invalid("暂不支持 Excel 累计时长格式，请转换为文本后导入。", "Excel elapsed-time formats must be converted to text before importing.") }
        guard let serial = Double(value), serial.isFinite, serial >= 0, serial < 2_958_466,
              date1904 || Int(serial) != 60 else { throw invalid("Excel 日期值无效。", "Invalid Excel date value.") }
        let base: TimeInterval = date1904 ? -2_082_844_800 : -2_209_075_200 // 1904-01-01 / 1899-12-31
        let adjusted = !date1904 && serial >= 60 ? serial - 1 : serial
        let date = Date(timeIntervalSince1970: base + adjusted * 86400)
        return formatter.string(from: date)
    }

    private static func invalid(_ zh: String, _ en: String) -> WorkspaceDataImportError { .invalid(zh, en) }

    private static func xml(_ archive: Archive, _ entry: String, start: @escaping (String, [String: String]) throws -> Void = { _, _ in }, text: @escaping (String) -> Void = { _ in }, end: @escaping (String) throws -> Void = { _ in }) throws {
        let delegate = XMLReader(start: start, text: text, end: end)
        let snapshot = try archive.extract(entry)
        guard let stream = InputStream(url: snapshot.url) else { throw invalid("无法读取 Excel XML。", "Cannot read Excel XML.") }
        defer { withExtendedLifetime(snapshot) {} }
        let parser = XMLParser(stream: stream)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let succeeded = parser.parse()
        if let error = delegate.error { throw error }
        guard succeeded else { throw invalid("Excel XML 格式无效。", "Invalid Excel XML.") }
    }

    private final class XMLReader: NSObject, XMLParserDelegate {
        let start: (String, [String: String]) throws -> Void
        let text: (String) -> Void
        let end: (String) throws -> Void
        var error: (any Error)?
        var count = 0
        init(start: @escaping (String, [String: String]) throws -> Void, text: @escaping (String) -> Void, end: @escaping (String) throws -> Void) { self.start = start; self.text = text; self.end = end }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            do {
                count += 1
                if count.isMultiple(of: 1024) { try Task.checkCancellation() }
                try start(name, attributes)
            } catch { self.error = error; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            do { try Task.checkCancellation(); text(string) } catch { self.error = error; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            do { try end(name) } catch { self.error = error; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            error = invalid("Excel XML 不支持自定义实体。", "Custom XML entities are not supported."); parser.abortParsing()
        }
    }

    private final class Archive {
        struct Entry { let offset: Int; let size: Int; let expanded: Int; let method: Int; let crc: UInt32 }
        let handle: FileHandle?
        let data: Data?
        let size: Int
        var entries: [String: Entry] = [:]
        init(_ data: Data) throws { self.data = data; handle = nil; size = data.count; try directory() }
        init(url: URL) throws {
            data = nil
            let handle = try FileHandle(forReadingFrom: url)
            self.handle = handle
            let length = try handle.seekToEnd()
            guard length <= UInt64(Int.max) else { throw invalid("Excel 文件过大，无法寻址。", "Cannot address this Excel archive.") }
            size = Int(length)
            try directory()
        }
        deinit { try? handle?.close() }
        func read(_ offset: Int, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0, offset <= size, count <= size - offset else { throw invalid("Excel 文件截断。", "Truncated Excel archive.") }
            if count == 0 { return Data() }
            if let data { return Data(data[offset..<offset+count]) }
            guard let handle else { throw invalid("无法读取 Excel。", "Cannot read Excel.") }
            try handle.seek(toOffset: UInt64(offset))
            guard let bytes = try handle.read(upToCount: count), bytes.count == count else { throw invalid("Excel 文件截断。", "Truncated Excel archive.") }
            return bytes
        }
        func u16(_ bytes: Data, _ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i+1]) << 8 }
        func u32(_ bytes: Data, _ i: Int) -> UInt32 { bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt32.self)) } }
        func u64(_ bytes: Data, _ i: Int) throws -> Int {
            let value = bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt64.self)) }
            guard value <= UInt64(Int.max) else { throw invalid("Excel 压缩地址无效。", "Invalid Excel archive offset.") }
            return Int(value)
        }
        func directory() throws {
            guard size >= 22, try read(0, 2) == Data([0x50,0x4b]) else {
                throw invalid("请选择 XLSX 或 XLSM 文件；旧版 XLS 请先另存为 XLSX。", "Choose XLSX or XLSM. Save legacy XLS files as XLSX first.")
            }
            let start = max(0, size - 65_557), tail = try read(start, size - start)
            guard let end = stride(from: tail.count-22, through: 0, by: -1).first(where: { u32(tail,$0) == 0x06054b50 && $0+22+u16(tail,$0+20) == tail.count }),
                  u16(tail,end+4) == 0, u16(tail,end+6) == 0 else { throw invalid("不支持此 Excel 压缩格式。", "Unsupported Excel archive.") }
            var count = u16(tail,end+10), offset = Int(u32(tail,end+16))
            if count == 0xffff || offset == 0xffff_ffff || u32(tail,end+12) == 0xffff_ffff {
                let locator = try read(start+end-20, 20)
                guard u32(locator,0) == 0x07064b50, u32(locator,4) == 0, u32(locator,16) == 1 else { throw invalid("Excel ZIP64 目录无效。", "Invalid Excel ZIP64 directory.") }
                let record = try read(u64(locator,8), 56)
                guard u32(record,0) == 0x06064b50, u32(record,16) == 0, u32(record,20) == 0 else { throw invalid("Excel ZIP64 目录无效。", "Invalid Excel ZIP64 directory.") }
                count = try u64(record,32); offset = try u64(record,48)
            }
            guard count <= size / 46 else { throw invalid("Excel 目录无效。", "Invalid Excel directory.") }
            for _ in 0..<count {
                try Task.checkCancellation()
                let header = try read(offset,46)
                guard u32(header,0) == 0x02014b50, u16(header,8) & 1 == 0, u16(header,34) == 0 else { throw invalid("Excel 文件损坏或已加密。", "The Excel file is corrupt or encrypted.") }
                let nameSize = u16(header,28), extraSize = u16(header,30), comment = u16(header,32)
                let name = String(decoding: try read(offset+46,nameSize), as: UTF8.self)
                let extra = try read(offset+46+nameSize,extraSize)
                var expanded = Int(u32(header,24)), compressed = Int(u32(header,20)), local = Int(u32(header,42))
                if expanded == 0xffff_ffff || compressed == 0xffff_ffff || local == 0xffff_ffff {
                    var i = 0, found = false
                    while i + 4 <= extra.count {
                        let id = u16(extra,i), length = u16(extra,i+2); i += 4
                        guard length <= extra.count-i else { throw invalid("Excel ZIP64 条目无效。", "Invalid Excel ZIP64 entry.") }
                        if id == 1 {
                            var value = i
                            func next() throws -> Int { guard value+8 <= i+length else { throw invalid("Excel ZIP64 条目截断。", "Truncated Excel ZIP64 entry.") }; defer { value += 8 }; return try u64(extra,value) }
                            if expanded == 0xffff_ffff { expanded = try next() }
                            if compressed == 0xffff_ffff { compressed = try next() }
                            if local == 0xffff_ffff { local = try next() }
                            found = true; break
                        }
                        i += length
                    }
                    guard found else { throw invalid("Excel 缺少 ZIP64 信息。", "Missing Excel ZIP64 metadata.") }
                }
                guard entries[name] == nil else { throw invalid("Excel 文件包含重复条目。", "Duplicate Excel archive entry.") }
                entries[name] = Entry(offset: local, size: compressed, expanded: expanded, method: u16(header,10), crc: u32(header,16))
                offset += 46+nameSize+extraSize+comment
            }
        }
        func contains(_ name: String) -> Bool { entries[name] != nil }
        func extract(_ name: String) throws -> WorkspaceDataImportSpool {
            guard let entry = entries[name] else { throw invalid("Excel 缺少条目：\(name)", "Missing Excel entry: \(name)") }
            let header = try read(entry.offset,30)
            guard u32(header,0) == 0x04034b50 else { throw invalid("Excel 条目无效。", "Invalid Excel entry.") }
            let start = entry.offset+30+u16(header,26)+u16(header,28)
            guard start <= size, entry.size <= size-start else { throw invalid("Excel 文件截断。", "Truncated Excel archive.") }
            let spool = try WorkspaceDataImportSpool(), writer = try FileHandle(forWritingTo: spool.url)
            defer { try? writer.close() }
            var checksum: uLong = 0, expanded = 0
            func emit(_ bytes: Data) throws {
                expanded += bytes.count
                guard expanded <= entry.expanded else { throw invalid("Excel 解压长度不符。", "Excel expanded length mismatch.") }
                checksum = bytes.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                try writer.write(contentsOf: bytes)
            }
            if entry.method == 0 {
                for offset in stride(from: 0, to: entry.size, by: 65_536) {
                    try Task.checkCancellation()
                    try autoreleasepool { try emit(read(start+offset,min(65_536,entry.size-offset))) }
                }
            } else if entry.method == 8 {
                var stream = z_stream()
                guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid("无法解压 Excel。", "Cannot decompress Excel.") }
                defer { inflateEnd(&stream) }
                var output = Data(count: 65_536), ended = false
                for offset in stride(from: 0, to: entry.size, by: 65_536) {
                    try Task.checkCancellation()
                    guard !ended else { throw invalid("Excel 压缩数据有多余内容。", "Trailing Excel compressed data.") }
                    try autoreleasepool {
                        let chunk = try read(start+offset,min(65_536,entry.size-offset))
                        try chunk.withUnsafeBytes { raw in
                            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                            stream.avail_in = uInt(chunk.count)
                            repeat {
                                let status = output.withUnsafeMutableBytes { out in
                                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(out.count)
                                    return inflate(&stream,Z_NO_FLUSH)
                                }
                                guard status == Z_OK || status == Z_STREAM_END else { throw invalid("Excel 解压失败。", "Excel decompression failed.") }
                                try emit(Data(output.prefix(65_536-Int(stream.avail_out))))
                                if status == Z_STREAM_END { ended = true; break }
                            } while stream.avail_in > 0 || stream.avail_out == 0
                        }
                    }
                }
                guard ended, stream.total_in == entry.size else { throw invalid("Excel 压缩数据截断。", "Truncated Excel compressed data.") }
            } else { throw invalid("不支持此 Excel 压缩算法。", "Unsupported Excel compression method.") }
            guard expanded == entry.expanded, UInt32(checksum) == entry.crc else { throw invalid("Excel 校验失败。", "Excel checksum mismatch.") }
            try writer.close()
            return spool
        }
    }
}
