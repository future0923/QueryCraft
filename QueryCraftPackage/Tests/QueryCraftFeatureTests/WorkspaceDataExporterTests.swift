import Foundation
import Testing
@testable import QueryCraftFeature

@Suite("Workspace Data Exporter")
struct WorkspaceDataExporterTests {
    private let columns = [
        WorkspaceGridCopyColumn(name: "id", dataIndex: 0),
        WorkspaceGridCopyColumn(name: "display,name", dataIndex: 1),
    ]
    private let rows = [
        WorkspaceDatabaseDataRow(
            id: 0,
            values: [.text("1"), .text("Alice")]
        ),
        WorkspaceDatabaseDataRow(
            id: 1,
            values: [.null, .text("line 1\nline \"2\"")]
        ),
        WorkspaceDatabaseDataRow(
            id: 2,
            values: [.text("=1+1"), .text("")]
        ),
    ]

    @Test("Export formats resolve their native filename extensions")
    func resolvesFormatContentTypes() {
        #expect(
            WorkspaceDataExportFormat.xlsx.contentType
                .preferredFilenameExtension == "xlsx"
        )
        #expect(
            WorkspaceDataExportFormat.csv.contentType
                .preferredFilenameExtension == "csv"
        )
        #expect(
            WorkspaceDataExportFormat.json.contentType
                .preferredFilenameExtension == "json"
        )
        #expect(
            WorkspaceDataExportFormat.sql.contentType
                .preferredFilenameExtension == "sql"
        )
        var lineOptions = WorkspaceDataExportOptions()
        lineOptions.format = .json
        lineOptions.jsonLayout = .lines
        #expect(lineOptions.fileExtension == "jsonl")
    }

    @Test("CSV applies delimiter, line ending, quote, and BOM options")
    func exportsCustomizedCSV() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "result.csv")
        let rows = rows
        var options = WorkspaceDataExportOptions()
        options.format = .csv
        options.csvIncludesUTF8BOM = false
        options.csvDelimiter = .tab
        options.csvLineEnding = .lf
        options.csvQuotePolicy = .allText
        let request = makeRequest(
            rows: .indexes(IndexSet(integer: 0)),
            columns: columns,
            options: options,
            sourceRows: rows
        )

        _ = try await WorkspaceDataExporter().export(
            request,
            to: destination
        )

        let data = try Data(contentsOf: destination)
        #expect(!data.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(
            String(decoding: data, as: UTF8.self)
                == "\"id\"\t\"display,name\"\n\"1\"\t\"Alice\"\n"
        )
    }

    @Test("CSV preserves NULL and empty strings and sanitizes formulas")
    func exportsCSV() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "result.csv")
        let rows = rows
        var options = WorkspaceDataExportOptions()
        options.format = .csv
        let request = makeRequest(
            rows: .range(0...2),
            columns: columns,
            options: options,
            sourceRows: rows
        )

        let rowCount = try await WorkspaceDataExporter().export(
            request,
            to: destination
        )

        #expect(rowCount == 3)
        let expected = "id,\"display,name\"\r\n"
            + "1,Alice\r\n"
            + "NULL,\"line 1\nline \"\"2\"\"\"\r\n"
            + "'=1+1,\"\"\r\n"
        let exportedData = try Data(contentsOf: destination)
        #expect(exportedData.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == expected
        )
    }

    @Test("JSON object layouts disambiguate duplicate column names")
    func exportsJSONObjectLayouts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = rows
        let duplicateColumns = [
            WorkspaceGridCopyColumn(name: "value", dataIndex: 0),
            WorkspaceGridCopyColumn(name: "value", dataIndex: 1),
        ]

        var objectOptions = WorkspaceDataExportOptions()
        objectOptions.format = .json
        objectOptions.jsonLayout = .objects
        objectOptions.prettyPrintsJSON = false
        let objectDestination = directory.appending(path: "objects.json")
        _ = try await WorkspaceDataExporter().export(
            makeRequest(
                rows: .indexes(IndexSet(integer: 0)),
                columns: duplicateColumns,
                options: objectOptions,
                sourceRows: rows
            ),
            to: objectDestination
        )
        let objects = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: objectDestination)
            ) as? [[String: String]]
        )
        #expect(objects == [["value": "1", "value_2": "Alice"]])

        var lineOptions = objectOptions
        lineOptions.jsonLayout = .lines
        let lineDestination = directory.appending(path: "objects.jsonl")
        _ = try await WorkspaceDataExporter().export(
            makeRequest(
                rows: .range(0...1),
                columns: duplicateColumns,
                options: lineOptions,
                sourceRows: rows
            ),
            to: lineDestination
        )
        let lineData = try String(
            contentsOf: lineDestination,
            encoding: .utf8
        )
        #expect(lineData.split(separator: "\n").count == 2)
    }

    @Test("SQL batches rows and escapes identifiers and text")
    func exportsSQL() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "result.sql")
        let sqlRows = [
            WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("1"), .text("O'Reilly")]
            ),
            WorkspaceDatabaseDataRow(
                id: 1,
                values: [.null, .text("Alice")]
            ),
        ]
        var options = WorkspaceDataExportOptions()
        options.format = .sql
        options.sqlTableName = "app.order"
        options.sqlInsertBatchSize = 1
        options.sqlConflictStrategy = .ignore
        let request = makeRequest(
            rows: .range(0...1),
            columns: columns,
            options: options,
            sourceRows: sqlRows
        )

        _ = try await WorkspaceDataExporter().export(
            request,
            to: destination
        )

        let sql = try String(contentsOf: destination, encoding: .utf8)
        #expect(sql.hasPrefix("START TRANSACTION;\n"))
        #expect(
            sql.contains(
                "INSERT IGNORE INTO `app`.`order` (`id`, `display,name`) VALUES"
            )
        )
        #expect(sql.contains("'O''Reilly'"))
        #expect(sql.contains("(NULL, 'Alice')"))
        #expect(sql.hasSuffix("COMMIT;\n"))
    }

    @Test("SQL export does not invent a missing table name")
    func rejectsSQLWithoutTableName() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "result.sql")
        var options = WorkspaceDataExportOptions()
        options.format = .sql
        let request = makeRequest(
            rows: .indexes(IndexSet(integer: 0)),
            columns: columns,
            options: options,
            sourceRows: rows
        )

        do {
            _ = try await WorkspaceDataExporter().export(
                request,
                to: destination
            )
            Issue.record("Expected SQL export to require a table name.")
        } catch let error as WorkspaceDataExportError {
            guard case .missingSQLTableName = error else {
                Issue.record("Unexpected export error: \(error)")
                return
            }
        }
    }

    @Test("JSON preserves column order, duplicate names, and NULL")
    func exportsJSON() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "result.json")
        let rows = rows
        var options = WorkspaceDataExportOptions()
        options.format = .json
        options.prettyPrintsJSON = false
        let duplicateColumns = [
            WorkspaceGridCopyColumn(name: "value", dataIndex: 0),
            WorkspaceGridCopyColumn(name: "value", dataIndex: 1),
        ]
        let request = makeRequest(
            rows: .range(0...1),
            columns: duplicateColumns,
            options: options,
            sourceRows: rows
        )

        _ = try await WorkspaceDataExporter().export(
            request,
            to: destination
        )

        let data = try Data(contentsOf: destination)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["columns"] as? [String] == ["value", "value"])
        let exportedRows = try #require(object["rows"] as? [[Any]])
        #expect(exportedRows.count == 2)
        #expect(exportedRows[0][0] as? String == "1")
        #expect(exportedRows[0][1] as? String == "Alice")
        #expect(exportedRows[1][0] is NSNull)
    }

    @Test("A failed export removes its incomplete temporary file")
    func removesPartialFileAfterFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "result.csv")
        let request = WorkspaceDataExportRequest(
            columns: columns,
            options: WorkspaceDataExportOptions(),
            estimatedRowCount: 2,
            worksheetName: "Result",
            source: WorkspaceSnapshotDataExportRowSource(
                rows: .range(0...1),
                rowAt: { index in
                    index == 0
                        ? WorkspaceDatabaseDataRow(
                            id: 0,
                            values: [.text("1"), .text("Alice")]
                        )
                        : nil
                }
            )
        )

        await #expect(throws: WorkspaceDataExportError.self) {
            try await WorkspaceDataExporter().export(
                request,
                to: destination
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    @Test("A successful export atomically replaces an existing file")
    func replacesExistingFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "result.csv")
        try Data("old contents".utf8).write(to: destination)
        let rows = rows
        var options = WorkspaceDataExportOptions()
        options.format = .csv
        let request = makeRequest(
            rows: .indexes(IndexSet(integer: 0)),
            columns: columns,
            options: options,
            sourceRows: rows
        )

        _ = try await WorkspaceDataExporter().export(
            request,
            to: destination
        )

        let exportedData = try Data(contentsOf: destination)
        #expect(exportedData.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "id,\"display,name\"\r\n1,Alice\r\n"
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent) == ["result.csv"]
        )
    }

    @Test("XLSX is a valid workbook and preserves text values")
    func exportsXLSX() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "result.xlsx")
        let rows = [
            WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("00123"), .text("<Alice & Bob>")]
            ),
            WorkspaceDatabaseDataRow(
                id: 1,
                values: [.null, .text("")]
            ),
        ]
        var options = WorkspaceDataExportOptions()
        options.format = .xlsx
        let request = makeRequest(
            rows: .range(0...1),
            columns: columns,
            options: options,
            sourceRows: rows
        )

        let rowCount = try await WorkspaceDataExporter().export(
            request,
            to: destination
        )

        #expect(rowCount == 2)
        let validation = try runUnzip(["-t", destination.path])
        #expect(validation.status == 0)
        let worksheet = try runUnzip([
            "-p",
            destination.path,
            "xl/worksheets/sheet1.xml",
        ])
        #expect(worksheet.status == 0)
        let xml = String(decoding: worksheet.output, as: UTF8.self)
        #expect(xml.contains(">00123<"))
        #expect(xml.contains("&lt;Alice &amp; Bob&gt;"))
        #expect(xml.contains("state=\"frozen\""))
        #expect(xml.contains("<autoFilter"))
    }

    @Test("XLSX honors worksheet, freeze, and filter options")
    func exportsCustomizedXLSX() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "result.xlsx")
        let rows = rows
        var options = WorkspaceDataExportOptions()
        options.format = .xlsx
        options.xlsxWorksheetName = "Custom Sheet"
        options.xlsxFreezesHeader = false
        options.xlsxAddsAutoFilter = false
        let request = makeRequest(
            rows: .indexes(IndexSet(integer: 0)),
            columns: columns,
            options: options,
            sourceRows: rows
        )

        _ = try await WorkspaceDataExporter().export(
            request,
            to: destination
        )

        let worksheet = try runUnzip([
            "-p",
            destination.path,
            "xl/worksheets/sheet1.xml",
        ])
        let worksheetXML = String(
            decoding: worksheet.output,
            as: UTF8.self
        )
        #expect(!worksheetXML.contains("state=\"frozen\""))
        #expect(!worksheetXML.contains("<autoFilter"))
        let workbook = try runUnzip([
            "-p",
            destination.path,
            "xl/workbook.xml",
        ])
        let workbookXML = String(decoding: workbook.output, as: UTF8.self)
        #expect(workbookXML.contains("name=\"Custom Sheet\""))
    }

    @Test(
        "Stored query results export 30,000 XLSX rows with bounded overhead",
        .timeLimit(.minutes(1))
    )
    func exportsRepresentativeXLSXQuickly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "performance.xlsx")
        let columnCount = 12
        let rowCount = 30_000
        let columns = (0..<columnCount).map {
            WorkspaceGridCopyColumn(name: "column_\($0)", dataIndex: $0)
        }
        let rows = (0..<rowCount).map { rowIndex in
            WorkspaceDatabaseDataRow(
                id: rowIndex,
                values: (0..<columnCount).map {
                    .text("row \(rowIndex) value \($0) & <data>")
                }
            )
        }
        var options = WorkspaceDataExportOptions()
        options.format = .xlsx
        let duration = try await ContinuousClock().measure {
            let store = try WorkspaceQueryResultStore()
            try await store.append(rows)
            let request = WorkspaceDataExportRequest(
                columns: columns,
                options: options,
                estimatedRowCount: rowCount,
                worksheetName: "Performance",
                source: store.makeDataExportRowSource(
                    rows: .range(0...(rowCount - 1))
                )
            )
            _ = try await WorkspaceDataExporter().export(
                request,
                to: destination
            )
        }

        #expect(duration < .seconds(5))
        let fileSize = try #require(
            try destination.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
        )
        #expect(fileSize < 10 * 1_024 * 1_024)
        #expect(try runUnzip(["-t", destination.path]).status == 0)
    }

    @Test("Entire table source reads every page in bounded batches")
    func streamsEntireTable() async throws {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "events",
            kind: .table
        )
        let sourceRows = (0..<12_050).map { index in
            WorkspaceDatabaseDataRow(
                id: index,
                values: [.text(String(index))]
            )
        }
        let page = WorkspaceDatabaseDataPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "id")],
            rows: sourceRows,
            offset: 0,
            limit: sourceRows.count,
            hasNextPage: false
        )
        let factory = InMemoryWorkspaceSessionFactory(
            databases: ["app"],
            dataByObject: [selection: page]
        )
        let source = WorkspaceTableDataExportRowSource(
            sessionFactory: factory,
            configuration: DatabaseConnectionConfiguration(
                host: "localhost",
                port: 3306,
                username: "test",
                password: nil,
                database: "app",
                tlsMode: .disabled
            ),
            selection: selection,
            sort: .none
        )

        var batchSizes: [Int] = []
        var rowCount = 0
        while let batch = try await source.nextBatch() {
            batchSizes.append(batch.count)
            rowCount += batch.count
        }
        await source.finish()

        #expect(batchSizes == [5_000, 5_000, 2_050])
        #expect(rowCount == sourceRows.count)
    }

    @Test("Snapshot ranges are consumed in bounded batches")
    func batchesSnapshotRanges() async throws {
        let source = WorkspaceSnapshotDataExportRowSource(
            rows: .range(0...2_500),
            rowAt: { index in
                WorkspaceDatabaseDataRow(
                    id: index,
                    values: [.text(String(index))]
                )
            }
        )

        let first = try #require(try await source.nextBatch())
        let finished = try await source.nextBatch()

        #expect(first.count == 2_501)
        #expect(first.first?.id == 0)
        #expect(first.last?.id == 2_500)
        #expect(finished == nil)
    }

    @Test("Snapshot selections preserve sparse row indexes")
    func batchesSparseSnapshotSelection() async throws {
        let indexes = IndexSet([2, 7, 42, 8_000])
        let source = WorkspaceSnapshotDataExportRowSource(
            rows: .indexes(indexes),
            rowAt: { index in
                WorkspaceDatabaseDataRow(
                    id: index,
                    values: [.text(String(index))]
                )
            }
        )

        let batch = try #require(try await source.nextBatch())

        #expect(batch.map(\.id) == [2, 7, 42, 8_000])
        #expect(try await source.nextBatch() == nil)
    }

    private func makeRequest(
        rows: WorkspaceGridCopyRows,
        columns: [WorkspaceGridCopyColumn],
        options: WorkspaceDataExportOptions,
        sourceRows: [WorkspaceDatabaseDataRow]
    ) -> WorkspaceDataExportRequest {
        WorkspaceDataExportRequest(
            columns: columns,
            options: options,
            estimatedRowCount: rows.count,
            worksheetName: "Result",
            source: WorkspaceSnapshotDataExportRowSource(
                rows: rows,
                rowAt: { sourceRows[$0] }
            )
        )
    }

    private func runUnzip(
        _ arguments: [String]
    ) throws -> (status: Int32, output: Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            output.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "QueryCraftExportTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
