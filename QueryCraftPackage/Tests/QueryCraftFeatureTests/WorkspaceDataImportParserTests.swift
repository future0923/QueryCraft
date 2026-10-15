import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceDataImportParserTests {
    @Test("CSV preserves quoting, multiline values, NULL and empty strings")
    func csvValues() throws {
        let result = try WorkspaceDelimitedImporter.read("id,value\r\n1,\"a,\"\"b\"\"\r\nc\"\r\n2,NULL\r\n3,\"NULL\"\r\n4,\r\n", options: .init())
        #expect(result.columns == ["id", "value"])
        #expect(try result.rows == [["1", "a,\"b\"\r\nc"], ["2", nil], ["3", "NULL"], ["4", ""]])
    }
    @Test("Delimited input rejects malformed rows and ambiguous headers", arguments: ["id,value\n1", "id,id\n1,2", "id,value\n1,\"open", "id,value\n1,\"x\"oops", "id,value\n1,a\"b"])
    func malformedCSV(_ text: String) {
        #expect(throws: WorkspaceDataImportError.self) { try WorkspaceDelimitedImporter.read(text, options: .init()) }
    }
    @Test("TSV and custom delimiters honor header and data ranges")
    func delimitedOptions() throws {
        var options = WorkspaceDataImportOptions()
        options.format = .tsv; options.headerRow = 2; options.firstDataRow = 3; options.lastDataRow = 3
        #expect(try WorkspaceDelimitedImporter.read("note\nid\tvalue\n1\ta\n2\tb", options: options).rows == [["1", "a"]])
        options.format = .text; options.delimiter = "|"; options.headerRow = 0; options.firstDataRow = 1; options.lastDataRow = 0
        options.trimsWhitespace = true; options.emptyAsNull = true
        let file = try WorkspaceDelimitedImporter.read(" 1 | \n2|x", options: options)
        #expect(file.columns == ["column_1", "column_2"])
        #expect(try file.rows == [["1", nil], ["2", "x"]])
    }
    @Test("JSON numbers retain original precision and nested types")
    func jsonPrecision() throws {
        var options = WorkspaceDataImportOptions(); options.format = .json; options.firstDataRow = 1
        let file = try WorkspaceJSONImporter.read(#"[{"id":9007199254740993,"amount":1234567890.123456789,"nested":{"n":12345678901234567890,"b":true},"value":null},{"id":2,"extra":"x"}]"#, options: options)
        #expect(file.columns == ["id", "amount", "nested", "value", "extra"])
        #expect(try file.rows[0] == ["9007199254740993", "1234567890.123456789", #"{"n":12345678901234567890,"b":true}"#, nil, nil])
        #expect(try file.rows[1] == ["2", nil, nil, nil, "x"])
    }
    @Test("JSON Lines, tabular exports, and array rows are importable")
    func jsonLayouts() throws {
        var options = WorkspaceDataImportOptions(); options.format = .json; options.firstDataRow = 1
        #expect(try WorkspaceJSONImporter.read("{\"id\":1}\n{\"id\":2}", options: options).rows == [["1"], ["2"]])
        #expect(try WorkspaceJSONImporter.read(#"{"columns":["id","value"],"rows":[[1,null],[2,""]]}"#, options: options).rows == [["1", nil], ["2", ""]])
        options.headerRow = 1; options.firstDataRow = 2
        #expect(try WorkspaceJSONImporter.read(#"[["id"],[1],[2]]"#, options: options).rows == [["1"], ["2"]])
    }
    @Test("JSON rejects duplicate keys, mixed rows, malformed values", arguments: [#"[{"id":1,"id":2}]"#, #"[{"id":1},[2]]"#, #"[{"id":NaN}]"#, #"[{"id":01}]"#, #"[{"id":"\q"}]"#])
    func malformedJSON(_ text: String) {
        #expect(throws: WorkspaceDataImportError.self) { try WorkspaceJSONImporter.read(text, options: .init()) }
    }
    @Test("SQL extracts literal data, transactions and export-generated escaping")
    func sqlLiterals() throws {
        let sql = "START TRANSACTION; INSERT INTO `old_db`.`old_table` (`id`, `value`) VALUES (9007199254740993, 'O''Reilly'),(2,CONVERT(X'615C62' USING utf8mb4)); INSERT INTO `old_db`.`old_table` (`id`, `value`) VALUES (3,NULL); COMMIT;"
        let file = try WorkspaceSQLImporter.read(sql, options: .init())
        #expect(file.columns == ["id", "value"])
        #expect(try file.rows == [["9007199254740993", "O'Reilly"], ["2", "a\\b"], ["3", nil]])
        #expect(try WorkspaceSQLImporter.read("INSERT INTO t (v) OVERRIDING SYSTEM VALUE VALUES (E'a\\\\b');", options: .init()).rows == [["a\\b"]])
        var standard = WorkspaceDataImportOptions(); standard.sqlBackslashEscapes = false
        #expect(try WorkspaceSQLImporter.read("INSERT INTO t (v) VALUES ('a\\b');", options: standard).rows == [["a\\b"]])
    }
    @Test("SQL cannot execute arbitrary statements or silently rewrite unsupported semantics", arguments: [
        "DROP TABLE t;", "INSERT INTO t (v) VALUES (1); DELETE FROM t;", "INSERT INTO t (v) SELECT v FROM s;",
        "INSERT IGNORE INTO t (v) VALUES (1);", "INSERT INTO t (v) VALUES (NOW());", "INSERT INTO t VALUES (1);",
        "INSERT INTO t (v) VALUES (1); INSERT INTO other (v) VALUES (2);", "/*! DROP TABLE t */ INSERT INTO t (v) VALUES (1);",
        "INSERT INTO t (v) VALUES (1) ON DUPLICATE KEY UPDATE v=2;", "INSERT INTO t (v) VALUES ('unterminated);"
    ])
    func rejectsUnsafeSQL(_ sql: String) {
        #expect(throws: WorkspaceDataImportError.self) { try WorkspaceSQLImporter.read(sql, options: .init()) }
    }
    @Test("Text decoding honors BOM, rejects invalid UTF-8, and supports GBK")
    func encoding() throws {
        #expect(try WorkspaceDataImportReader.decode(Data([0xef,0xbb,0xbf]) + Data("中文".utf8), encoding: .automatic) == "中文")
        #expect(try WorkspaceDataImportReader.decode(Data([0xff,0xfe,0x61,0]), encoding: .automatic) == "a")
        #expect(try WorkspaceDataImportReader.decode(Data([0xd6,0xd0,0xce,0xc4]), encoding: .gb18030) == "中文")
        #expect(throws: WorkspaceDataImportError.self) { try WorkspaceDataImportReader.decode(Data([0xff]), encoding: .utf8) }
    }

    @Test("SQL files larger than the former safety threshold remain importable")
    func largeSQLFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = String(repeating: "x", count: 52 * 1024 * 1024)
        let url = directory.appending(path: "large.sql")
        try "INSERT INTO source (value) VALUES ('\(payload)');".write(to: url, atomically: false, encoding: .utf8)
        var options = WorkspaceDataImportOptions(); options.format = .sql
        let file = try await WorkspaceDataImportReader().read(url: url, options: options)
        #expect(file.rowCount == 1)
        #expect(try file.rows[0][0]?.count == payload.count)
    }
    @Test("SQL decimal and exponent tokens retain precision without per-cell regular expressions")
    func sqlNumbers() throws {
        let file = try WorkspaceSQLImporter.read("INSERT INTO t (a,b,c,d) VALUES (-123.4567890123456789, +1.25e-30, 12., 9007199254740993);", options: .init())
        #expect(try file.rows == [["-123.4567890123456789", "+1.25e-30", "12.", "9007199254740993"]])
        for value in ["1.2.3", "1e", "1e+", "+", "--", ".5"] {
            #expect(throws: WorkspaceDataImportError.self) {
                try WorkspaceSQLImporter.read("INSERT INTO t (a) VALUES (\(value));", options: .init())
            }
        }
    }

    @Test("SQL streaming preserves Unicode, escapes, BOM and comments across input windows")
    func sqlInputBoundaries() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = WorkspaceDataImportOptions(); options.format = .sql
        let value = String(repeating: "中文🙂'\\\n", count: 20_000)
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
        for padding in [65_480, 65_499, 65_535] {
            let sql = "\u{feff}/*" + String(repeating: "a", count: padding) + "*/ INSERT INTO `来源` (`文本`) VALUES ('\(escaped)');"
            try sql.write(to: url, atomically: false, encoding: .utf8)
            let file = try await WorkspaceDataImportReader().read(url: url, options: options)
            #expect(file.columns == ["文本"])
            #expect(try file.readRows(in: 0..<1) == [[value]])
            #expect(file.previewRows[0][0]?.count == 512)
        }
        try Data("INSERT INTO t (v) VALUES ('".utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0xff, 0x27, 0x29, 0x3b])); try handle.close()
        await #expect(throws: WorkspaceDataImportError.self) {
            try await WorkspaceDataImportReader().read(url: url, options: options)
        }
    }

    @Test("Large SQL snapshots spill, preserve full values, and remain unchanged after source replacement")
    func diskSnapshot() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = String(repeating: "中", count: 700)
        let text = "INSERT INTO source (id,value) VALUES " + (0..<5003).map { "(\($0),'\(payload)')" }.joined(separator: ",") + ";"
        try text.write(to: url, atomically: false, encoding: .utf8)
        var options = WorkspaceDataImportOptions(); options.format = .sql
        let file = try await WorkspaceDataImportReader().read(url: url, options: options)
        #expect(file.isDiskBacked)
        #expect(file.rowCount == 5003)
        #expect(file.previewRows.count == 200)
        #expect(file.previewRows[0][1]?.count == 512)
        try "changed".write(to: url, atomically: true, encoding: .utf8)
        #expect(try file.readRows(in: 4999..<5003) == (4999..<5003).map { [String($0), payload] })
        #expect(try file.readRows(in: 0..<2) == [["0", payload], ["1", payload]])
        #expect(throws: WorkspaceDataImportError.self) { try file.readRows(in: 0..<5004) }
    }

    @Test("Streaming SQL observes cancellation without accepting a partial snapshot")
    func sqlReadCancellation() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        try "INSERT INTO t (v) VALUES ('\(String(repeating: "x", count: 128 * 1024))');".write(to: url, atomically: false, encoding: .utf8)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var options = WorkspaceDataImportOptions(); options.format = .sql
            return try await WorkspaceDataImportReader().read(url: url, options: options)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Excel handles compressed shared strings, sparse cells, dates and sheet selection")
    func excelFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "import-workbook", withExtension: "xlsx", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        var options = WorkspaceDataImportOptions(); options.format = .excel
        let file = try WorkspaceXLSXImporter.read(data, options: options)
        #expect(file.sheetNames == ["数据", "Second", "Escapes"])
        #expect(file.columns == ["id", "value", "created"])
        #expect(try file.rows == [["9007199254740993", "中文 & text", "2024-01-01 00:00:00.000"], ["2", nil, nil]])
        options.sheetIndex = 1
        #expect(try WorkspaceXLSXImporter.read(data, options: options).rows == [["42"]])
        options.sheetIndex = 2
        #expect(try WorkspaceXLSXImporter.read(data, options: options).rows == [["line\rnext _x0041_", "12:00:00.000"]])
        #expect(throws: WorkspaceDataImportError.self) { try WorkspaceXLSXImporter.read(Data([0xd0, 0xcf]), options: options) }
        #expect(throws: WorkspaceDataImportError.self) { try WorkspaceXLSXImporter.read(data.dropLast(10), options: options) }
    }
    @Test("Lossless exports distinguish NULL, empty strings and SpreadsheetML escape-looking text", arguments: WorkspaceDataExportFormat.allCases)
    func losslessValues(_ format: WorkspaceDataExportFormat) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let values: [String?] = [nil, "", "NULL", "_x0041_", "_x005F_x0041_", "a\r\nb\tc", "中文🙂", "\u{01}", "=1+1"]
        var options = WorkspaceDataExportPreferences().options(for: format)
        options.sqlTableName = "source"
        options.sqlTableIdentifierParts = ["source"]
        options.sanitizesSpreadsheetFormulas = false
        if format == .xlsx { options.nullStyle = .empty }
        let rows = values.enumerated().map { WorkspaceDatabaseDataRow(id: $0.offset, values: [$0.element.map(WorkspaceDatabaseDataCell.text) ?? .null]) }
        let request = WorkspaceDataExportRequest(columns: [.init(name: "value", dataIndex: 0)], options: options, estimatedRowCount: rows.count, worksheetName: "data", source: ImportRoundTripSource(rows))
        let url = directory.appending(path: "data.\(format.fileExtension)")
        _ = try await WorkspaceDataExporter().export(request, to: url)
        var readOptions = WorkspaceDataImportOptions()
        readOptions.format = .detect(url)
        if format == .json { readOptions.firstDataRow = 1 }
        if format == .xlsx { readOptions.nullToken = "" }
        let parsed = try await WorkspaceDataImportReader().read(url: url, options: readOptions)
        #expect(try parsed.rows.map { $0[0] } == values)
    }

    @Test("All four QueryCraft exports can be parsed back as import data", arguments: WorkspaceDataExportFormat.allCases)
    func exportRoundTrip(_ format: WorkspaceDataExportFormat) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = WorkspaceDataExportPreferences().options(for: format)
        options.sqlTableName = "source"; options.sqlTableIdentifierParts = ["source"]
        options.sanitizesSpreadsheetFormulas = false
        let rows = [WorkspaceDatabaseDataRow(id: 0, values: [.text("9007199254740993"), .text("O'Reilly\\中文")])]
        let request = WorkspaceDataExportRequest(columns: [.init(name: "id", dataIndex: 0), .init(name: "value", dataIndex: 1)], options: options, estimatedRowCount: 1, worksheetName: "data", source: ImportRoundTripSource(rows))
        let file = directory.appending(path: "data.\(format.fileExtension)")
        _ = try await WorkspaceDataExporter().export(request, to: file)
        var readOptions = WorkspaceDataImportOptions()
        readOptions.format = WorkspaceDataImportFormat.detect(file)
        if format == .json { readOptions.firstDataRow = 1 }
        let parsed = try await WorkspaceDataImportReader().read(url: file, options: readOptions)
        let values = Dictionary(uniqueKeysWithValues: zip(parsed.columns, try parsed.rows[0]))
        #expect(values["id"] == "9007199254740993")
        #expect(values["value"] == "O'Reilly\\中文")
    }
}

private actor ImportRoundTripSource: WorkspaceDataExportRowSource {
    var rows: [WorkspaceDatabaseDataRow]?
    init(_ rows: [WorkspaceDatabaseDataRow]) { self.rows = rows }
    func nextBatch() -> [WorkspaceDatabaseDataRow]? { defer { rows = nil }; return rows }
    func finish() { rows = nil }
}
