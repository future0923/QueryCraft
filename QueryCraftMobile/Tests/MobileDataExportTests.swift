import Foundation
import Testing
import zlib
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

struct MobileDataExportTests {
    private func snapshot(columns: [String] = ["id", "name", "note"], values: [[WorkspaceDatabaseDataCell]]? = nil) -> MobileDataExportSnapshot {
        let cells = values ?? [[.text("318987599031067570"), .text("=1+1"), .null],
                               [.text("2"), .text("line,\"雪\"\nnext"), .text("")]]
        return .init(data: .init(columns: columns, details: [], rows: cells.map { $0.map { _ in "preview" } }, cells: cells),
                     name: "admin_user", scopeDescription: "当前页", tableIdentifierParts: ["db.with.dot", "t`name"])
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ snapshot: MobileDataExportSnapshot, options: WorkspaceDataExportOptions, to url: URL) async throws -> Data {
        let request = try snapshot.request(options: options)
        let count = try await WorkspaceDataExporter().export(request, to: url)
        #expect(count == snapshot.data.rows.count)
        return try Data(contentsOf: url)
    }

    @Test func csvKeepsRawValuesNullEmptyQuotingBOMAndDesktopFormulaProtection() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var options = WorkspaceDataExportPreferences().options(for: .csv)
        let data = try await write(snapshot(), options: options, to: root.appending(path: "test.csv"))
        #expect(data.prefix(3) == Data([0xef, 0xbb, 0xbf]))
        #expect(String(decoding: data.dropFirst(3), as: UTF8.self) == "id,name,note\r\n318987599031067570,'=1+1,NULL\r\n2,\"line,\"\"雪\"\"\nnext\",\"\"\r\n")
        options.csvIncludesUTF8BOM = false; options.csvDelimiter = .tab; options.csvLineEnding = .lf
        options.includesColumnNames = false; options.sanitizesSpreadsheetFormulas = false
        let plain = try await write(snapshot(), options: options, to: root.appending(path: "plain.csv"))
        #expect(String(decoding: plain, as: UTF8.self).hasPrefix("318987599031067570\t=1+1\tNULL\n"))
    }

    @Test func jsonAllLayoutsPreserveDuplicateAliasesNullBinaryAndIntegerPrecision() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = snapshot(columns: ["name", "name", "name_2", "binary", "null", "empty"], values: [
            [.text("318987599031067570"), .text("second"), .text("original"), .binary(byteCount: 3, preview: [0, 65, 255]), .null, .text("")]])
        #expect(source.hasBinaryValues)
        for layout in WorkspaceJSONLayout.allCases {
            var options = WorkspaceDataExportPreferences().options(for: .json); options.jsonLayout = layout
            let bytes = try await write(source, options: options, to: root.appending(path: "test." + options.fileExtension))
            if layout == .tabular {
                let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                #expect(object["columns"] as? [String] == source.data.columns)
                let rows = try #require(object["rows"] as? [[Any]])
                #expect(rows[0][0] as? String == "318987599031067570")
            } else {
                let value = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
                let object = try #require(layout == .objects ? (value as? [[String: Any]])?.first : value as? [String: Any])
                #expect(object.count == 6)
                #expect(object["name"] as? String == "318987599031067570")
                #expect(object["name_2"] as? String == "original")
                #expect(object["name_3"] as? String == "second")
                #expect(object["null"] is NSNull)
                #expect(object["empty"] as? String == "")
                #expect((object["binary"] as? [String: Int])?["binaryByteCount"] == 3)
            }
        }
    }

    @Test func xlsxArchiveContainsRawTextControlsAndNativeHeaderOptions() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var options = WorkspaceDataExportPreferences().options(for: .xlsx)
        options.xlsxWorksheetName = "a/b:*?[]name"
        let source = snapshot(columns: ["id", "text"], values: [[.text("318987599031067570"), .text("=1+1\u{0}_x0041_\r雪")]])
        let bytes = try await write(source, options: options, to: root.appending(path: "test.xlsx"))
        let entries = try unzip(bytes)
        let sheet = try #require(entries["xl/worksheets/sheet1.xml"])
        #expect(sheet.contains("318987599031067570"))
        #expect(sheet.contains("_x0000__x005F_x0041__x000D_雪"))
        #expect(sheet.contains("<pane")); #expect(sheet.contains("<autoFilter"))
        #expect(!sheet.contains("<f>")); #expect(sheet.contains("=1+1"))
        #expect(entries["xl/workbook.xml"]?.contains("name=\"abname\"") == true)
    }

    @Test func sqlUsesDesktopIdentifiersLiteralsAndAtomicFailurePreservesExistingFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "result.sql")
        var options = WorkspaceDataExportPreferences().options(for: .sql)
        options.sqlTableName = "t`name"; options.sqlTableIdentifierParts = ["db.with.dot", "t`name"]
        let source = snapshot(columns: ["odd`column"], values: [[.text("quote'\\\n雪")], [.null]])
        let bytes = try await write(source, options: options, to: url)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("INSERT INTO `db.with.dot`.`t``name` (`odd``column`) VALUES\n"))
        #expect(text.contains("CONVERT(X'")); #expect(text.contains("NULL")); #expect(!text.contains("START TRANSACTION"))
        let binary = snapshot(columns: ["binary"], values: [[.binary(byteCount: 100, preview: [1, 2])]])
        await #expect(throws: WorkspaceDataExportError.self) {
            _ = try await WorkspaceDataExporter().export(binary.request(options: options), to: url)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test @MainActor func modelDefaultsSnapshotCaptureSaveWrapperAndCleanup() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = MobileDataExportModel(snapshot: snapshot(), temporaryRoot: root)
        #expect(model.format == .xlsx); #expect(model.preferences.jsonLayout == .objects)
        #expect(!model.preferences.sqlWrapsInTransaction)
        model.format = .sql; model.preferences.sqlIncludesDatabaseName = true
        let operation = try #require(model.prepare()); await operation.value
        let file = try #require(model.file)
        let bytes = try Data(contentsOf: file.url)
        #expect(String(decoding: bytes, as: UTF8.self).contains("`db.with.dot`.`t``name`"))
        let wrapper = try FileWrapper(url: file.url, options: .immediate)
        #expect(wrapper.regularFileContents == bytes)
        model.cancel()
        #expect(model.file == nil); #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(MobileDataExportModel.fileName("../../foo\\bar\n") == ".._.._foo_bar_")
    }

    @Test @MainActor func cancelledNoncooperativeWriterCannotReplaceOrDeleteNewGeneration() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = ControlledExportWriter()
        let model = MobileDataExportModel(snapshot: snapshot(), temporaryRoot: root, writer: writer)
        model.format = .csv
        let first = try #require(model.prepare()); try await wait { await writer.pending == 1 }
        model.cancel()
        let second = try #require(model.prepare()); try await wait { await writer.pending == 2 }
        await writer.complete(1); await second.value
        let file = try #require(model.file)
        await writer.complete(0); await first.value
        #expect(model.file?.id == file.id)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "generation-1")
        #expect(model.message == nil)
        model.cancel()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func emptyAndMissingRawValuesDoNotSilentlyExportNullOrPreview() throws {
        let empty = MobileDataExportSnapshot(data: .init(columns: ["id"], rows: []), name: "empty", scopeDescription: "page")
        #expect(!empty.canExport)
        #expect(throws: WorkspaceDataExportError.self) { try empty.request(options: .init()) }
        let malformed = MobileDataExportSnapshot(data: .init(columns: ["id", "name"], rows: [["1"]]), name: "bad", scopeDescription: "page")
        #expect(throws: WorkspaceDataExportError.self) { try malformed.request(options: .init()) }
    }

    @Test func liveMySQLFilteredPageAndAliasQueryExportRawValues() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        let config = MobileSQLConfiguration(host: "127.0.0.1", port: port, username: "proof_reader", password: "querycraft-proof-reader", database: "querycraft_ios_proof", tlsMode: .required)
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let filter = WorkspaceDatabaseDataFilter(conditions: [.init(columnName: "id", columnKind: .number, operation: .between, value: "110", secondValue: "115")])
        let service = MobileMySQLService()
        let object = MobileDatabaseObject(database: "querycraft_ios_proof", name: "admin_user", kind: .table, comment: "")
        let columns = try await service.columns(configuration: config, object: object)
        let page = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 25, sortColumn: nil, ascending: true, filter: filter)
        let snapshot = MobileDataExportSnapshot(data: .init(preview: page.preview), name: object.name, scopeDescription: "page")
        let bytes = try await write(snapshot, options: WorkspaceDataExportPreferences().options(for: .json), to: root.appending(path: "page.json"))
        let rows = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        #expect(rows.count == 6); #expect(rows.first?["id"] as? String == "110"); #expect(rows.last?["id"] as? String == "115")
        let preview = try await MobileMariaDBExecutor().preview(configuration: config, sql: "SELECT id AS n, created_at AS n, created_time AS n_2 FROM epoch_values ORDER BY id LIMIT 1", maximumRows: 10, maximumBytes: 1_048_576)
        let query = MobileDataExportSnapshot(data: .init(preview: preview), name: "query", scopeDescription: "query")
        let output = try await write(query, options: WorkspaceDataExportPreferences().options(for: .json), to: root.appending(path: "query.json"))
        let result = try #require((JSONSerialization.jsonObject(with: output) as? [[String: Any]])?.first)
        #expect(result["n"] as? String == "318987599031067570")
        #expect(result["n_3"] as? String == "1700000000")
        #expect(result["n_2"] as? String == "1700000000")
    }

    private func wait(_ predicate: @Sendable () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < end else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func unzip(_ bytes: Data) throws -> [String: String] {
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var entries: [String: String] = [:], index = 0
        while index + 46 <= bytes.count {
            guard u32(index) == 0x02014b50 else { index += 1; continue }
            let size = u32(index + 20), nameSize = u16(index + 28), extra = u16(index + 30), comment = u16(index + 32)
            let name = String(decoding: bytes[(index + 46)..<(index + 46 + nameSize)], as: UTF8.self)
            let local = u32(index + 42), start = local + 30 + u16(local + 26) + u16(local + 28)
            var stream = z_stream()
            #expect(inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK)
            var output = [UInt8](repeating: 0, count: 1_048_576)
            let compressed = Array(bytes[start..<(start + size)])
            let status = compressed.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { target in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = uInt(size); stream.next_out = target.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(target.count)
                    return zlib.inflate(&stream, Z_FINISH)
                }
            }
            let count = Int(stream.total_out); inflateEnd(&stream)
            #expect(status == Z_STREAM_END)
            entries[name] = String(decoding: output.prefix(count), as: UTF8.self)
            index += 46 + nameSize + extra + comment
        }
        return entries
    }
}

private actor ControlledExportWriter: MobileDataExportWriting {
    private var requests: [(URL, CheckedContinuation<Int, Never>)] = []
    var pending: Int { requests.count }
    func export(_ request: WorkspaceDataExportRequest, to destination: URL, progress: @escaping WorkspaceDataExporter.ProgressHandler) async throws -> Int {
        let value = await withCheckedContinuation { continuation in requests.append((destination, continuation)) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("generation-\(value)".utf8).write(to: destination)
        await progress(999)
        return request.estimatedRowCount ?? 0
    }
    func complete(_ index: Int) { requests[index].1.resume(returning: index) }
}
