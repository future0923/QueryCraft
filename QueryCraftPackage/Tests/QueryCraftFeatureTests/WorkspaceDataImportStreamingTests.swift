import Foundation
import CoreFoundation
import Testing
import zlib
@testable import QueryCraftFeature

struct WorkspaceDataImportStreamingTests {
    @Test("CSV windows preserve CRLF, escaped quotes, multiline data and Unicode delimiters")
    func csvWindows() async throws {
        let value = String(repeating: "中文🙂\r\n", count: 12_000) + "\"end\""
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        var options = WorkspaceDataImportOptions(); options.format = .text; options.delimiter = "🙂"
        let text = "\u{feff}id🙂value\r\n1🙂\"\(escaped)\"\r\n2🙂NULL\r\n3🙂\"NULL\"\r\n4🙂\r\n"
        let file = try await read(Data(text.utf8), extension: "txt", options: options)
        #expect(try file.rows == [["1", value], ["2", nil], ["3", "NULL"], ["4", ""]])
    }

    @Test("Legacy text encodings stream across multibyte and surrogate boundaries", arguments: [WorkspaceDataImportOptions.Encoding.gb18030, .utf16LE, .utf16BE, .automatic])
    func encodingWindows(_ encoding: WorkspaceDataImportOptions.Encoding) async throws {
        let header = "id,value\n1,"
        let fill = encoding == .gb18030 ? 65_536-header.count-1 : 32_768-header.count-2
        let value = String(repeating: "x", count: fill) + "🙂中文" + String(repeating: "a", count: 70_000)
        let text = header + value + "\n"
        let resolved: String.Encoding
        switch encoding {
        case .gb18030: resolved = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .utf16BE: resolved = .utf16BigEndian
        default: resolved = .utf16LittleEndian
        }
        var data = try #require(text.data(using: resolved))
        if encoding == .automatic { data = Data([0xff,0xfe]) + data }
        var options = WorkspaceDataImportOptions(); options.encoding = encoding
        let file = try await read(data, extension: "csv", options: options)
        #expect(try file.readRows(in: 0..<1) == [["1",value]])
        #expect(file.previewRows[0][1]?.count == 512)
    }

    @Test("CSV disk snapshots preserve selected ranges, full values and empty/header semantics")
    func csvDisk() async throws {
        let payload = String(repeating: "x", count: 1500)
        let rows = (0..<5003).map { "\($0),\(payload)" }.joined(separator: "\n")
        var options = WorkspaceDataImportOptions(); options.headerRow = 2; options.firstDataRow = 3
        let file = try await read(Data(("ignored\nid,value\n" + rows).utf8), extension: "csv", options: options)
        #expect(file.isDiskBacked)
        #expect(file.rowCount == 5003)
        #expect(try file.readRows(in: 5001..<5003) == [["5001",payload],["5002",payload]])
        options.firstDataRow = 5; options.lastDataRow = 6
        let selected = try WorkspaceDelimitedImporter.read("note\nid,value\n0,a\n1,b\n2,c\n3,d\nwrong,width,after-range", options: options)
        #expect(try selected.rows == [["2","c"],["3","d"]])
    }

    @Test("JSON streaming pads earlier rows when a column first appears after the spill threshold")
    func jsonLateColumns() async throws {
        let payload = String(repeating: "中", count: 500)
        let records = (0..<5003).map { index in
            "{\"id\":\(index),\"value\":\"\(payload)\"" + (index == 5002 ? ",\"late\":9007199254740993}" : "}")
        }
        var options = WorkspaceDataImportOptions(); options.format = .json; options.firstDataRow = 1; options.headerRow = 0
        for text in ["["+records.joined(separator: ",")+"]", records.joined(separator: "\n")] {
            let file = try await read(Data(text.utf8), extension: "json", options: options)
            #expect(file.isDiskBacked)
            #expect(file.columns == ["id","value","late"])
            #expect(file.rowCount == 5003)
            #expect(try file.readRows(in: 0..<1) == [["0",payload,nil]])
            #expect(try file.readRows(in: 5002..<5003) == [["5002",payload,"9007199254740993"]])
            #expect(file.previewRows[0].count == 3)
        }
    }

    @Test("JSON wrapper rows can precede columns; JSONL array rows and exact numeric tokens remain supported")
    func jsonWrappers() async throws {
        var options = WorkspaceDataImportOptions(); options.format = .json; options.firstDataRow = 1; options.headerRow = 0
        let payload = String(repeating: "a", count: 66_000) + "中文🙂"
        let value = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
        let text = "{\"rows\":[[9007199254740993,\(value)],[2,null]],\"columns\":[{\"name\":\"id\"},{\"name\":\"value\"}]}"
        let file = try await read(Data(text.utf8), extension: "json", options: options)
        #expect(file.columns == ["id","value"])
        #expect(try file.rows == [["9007199254740993",payload],["2",nil]])
        let lines = try WorkspaceJSONImporter.read("[1,\"a\"]\n[2,\"b\"]", options: options)
        #expect(try lines.rows == [["1","a"],["2","b"]])
        #expect(try WorkspaceJSONImporter.read("\u{feff}[[1]]", options: options).rows == [["1"]])
    }

    @Test("Excel reads ZIP64, disk-backed shared strings, sparse cells and cached dates without whole entry buffers")
    func excelStreaming() async throws {
        let values = (0..<2501).map { "\($0)-" + String(repeating: "中文", count: 400) }
        let shared = "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" + values.map { "<si><t>\($0)</t></si>" }.joined() + "</sst>"
        let rows: String = (0..<5003).map { index -> String in
            let n = index+2
            return "<row r=\"\(n)\"><c r=\"A\(n)\"><v>\(index)</v></c><c r=\"C\(n)\" t=\"s\"><v>\(index % 2501)</v></c></row>"
        }.joined()
        let sheet = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>id</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>blank</t></is></c><c r=\"C1\" t=\"inlineStr\"><is><t>value</t></is></c></row>" + rows + "</sheetData></worksheet>"
        let workbook = "<workbook xmlns:r=\"urn:r\"><sheets><sheet name=\"Data\" r:id=\"r1\"/></sheets></workbook>"
        let rels = "<Relationships><Relationship Id=\"r1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"
        let data = zip64([("xl/workbook.xml",workbook),("xl/_rels/workbook.xml.rels",rels),("xl/sharedStrings.xml",shared),("xl/worksheets/sheet1.xml",sheet)])
        var options = WorkspaceDataImportOptions(); options.format = .excel
        let file = try await read(data, extension: "xlsx", options: options)
        #expect(file.isDiskBacked)
        #expect(file.rowCount == 5003)
        #expect(file.columns == ["id","blank","value"])
        #expect(try file.readRows(in: 5002..<5003) == [["5002",nil,values[0]]])
        #expect(try file.readRows(in: 100..<101) == [["100",nil,values[100]]])
        #expect(file.sheetNames == ["Data"])
        var broken = data; broken[100] ^= 1
        let damaged = broken
        await #expect(throws: (any Error).self) { try await read(damaged, extension: "xlsx", options: options) }
    }

    @Test("All streaming file paths observe cancellation before producing a snapshot", arguments: [WorkspaceDataImportFormat.csv, .json, .excel])
    func cancelled(_ format: WorkspaceDataImportFormat) async throws {
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var options = WorkspaceDataImportOptions(); options.format = format
            return try await read(Data("id,value\n1,test".utf8), extension: "data", options: options)
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }

    private func read(_ data: Data, extension ext: String, options: WorkspaceDataImportOptions) async throws -> WorkspaceDataImportFile {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).\(ext)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await WorkspaceDataImportReader().read(url: url, options: options)
    }

    private func zip64(_ entries: [(String,String)]) -> Data {
        var file = Data(), central = Data()
        func integer(_ value: UInt64, bytes: Int) -> Data {
            var value = value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0.prefix(bytes)) }
        }
        for (name,text) in entries {
            let name = Data(name.utf8), body = Data(text.utf8), offset = file.count
            let crc = body.withUnsafeBytes { crc32(0,$0.bindMemory(to: Bytef.self).baseAddress,uInt($0.count)) }
            var local = integer(0x04034b50,bytes:4)
            for number in [45,0,0,0,0] { local += integer(UInt64(number),bytes:2) }
            local += integer(UInt64(crc),bytes:4)
            local += integer(0xffff_ffff,bytes:4) + integer(0xffff_ffff,bytes:4)
            local += integer(UInt64(name.count),bytes:2) + integer(20,bytes:2)
            local += name + integer(1,bytes:2) + integer(16,bytes:2) + integer(UInt64(body.count),bytes:8) + integer(UInt64(body.count),bytes:8)
            file += local + body
            var header = integer(0x02014b50,bytes:4)
            for number in [45,45,0,0,0,0] { header += integer(UInt64(number),bytes:2) }
            header += integer(UInt64(crc),bytes:4) + integer(0xffff_ffff,bytes:4) + integer(0xffff_ffff,bytes:4)
            for number in [name.count,28,0,0,0] { header += integer(UInt64(number),bytes:2) }
            header += integer(0,bytes:4) + integer(0xffff_ffff,bytes:4)
            header += name + integer(1,bytes:2) + integer(24,bytes:2) + integer(UInt64(body.count),bytes:8) + integer(UInt64(body.count),bytes:8) + integer(UInt64(offset),bytes:8)
            central += header
        }
        let centralOffset = file.count
        file += central
        let zip64Offset = file.count
        file += integer(0x06064b50,bytes:4) + integer(44,bytes:8)
        file += integer(45,bytes:2) + integer(45,bytes:2) + integer(0,bytes:4) + integer(0,bytes:4)
        file += integer(UInt64(entries.count),bytes:8) + integer(UInt64(entries.count),bytes:8) + integer(UInt64(central.count),bytes:8) + integer(UInt64(centralOffset),bytes:8)
        file += integer(0x07064b50,bytes:4) + integer(0,bytes:4) + integer(UInt64(zip64Offset),bytes:8) + integer(1,bytes:4)
        file += integer(0x06054b50,bytes:4) + integer(0,bytes:2) + integer(0,bytes:2) + integer(0xffff,bytes:2) + integer(0xffff,bytes:2)
        file += integer(0xffff_ffff,bytes:4) + integer(0xffff_ffff,bytes:4) + integer(0,bytes:2)
        return file
    }
}
