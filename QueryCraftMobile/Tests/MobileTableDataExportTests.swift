import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

struct MobileTableDataExportTests {
    private func configuration() throws -> MobileSQLConfiguration {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        return .init(host: "127.0.0.1", port: port, username: "proof_reader", password: "querycraft-proof-reader",
                     database: "querycraft_ios_proof", tlsMode: .required)
    }
    private func object(_ name: String = "export_rows", kind: MobileDatabaseObject.Kind = .table) -> MobileDatabaseObject {
        .init(database: "querycraft_ios_proof", name: name, kind: kind, comment: "")
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test(arguments: WorkspaceDataExportFormat.allCases)
    func entireFilteredTableStartsAtZeroRetainsSortAcrossBatches(format: WorkspaceDataExportFormat) async throws {
        let config = try configuration(), service = MobileMySQLService(), object = object()
        let columns = try await service.columns(configuration: config, object: object)
        let filter = WorkspaceDatabaseDataFilter(conditions: [.init(columnName: "id", columnKind: .number,
            operation: .between, value: "90", secondValue: "410")])
        var captured = try await service.page(configuration: config, object: object, columns: columns, offset: 100,
            size: 25, sortColumn: "id", ascending: false, filter: filter)
        let snapshot = MobileDataExportSnapshot.table(captured, configuration: config, service: service)
        // Later page/filter/order changes cannot alter the captured export request.
        captured.filter = .empty; captured.sortColumn = nil; captured.ascending = true
        var options = WorkspaceDataExportPreferences().options(for: format)
        options.scope = .allTableRows; options.sqlTableName = object.name
        let request = try snapshot.request(options: options)
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "out." + options.fileExtension)
        let count = try await WorkspaceDataExporter().export(request, to: file)
        #expect(count == 321)
        let bytes = try Data(contentsOf: file)
        switch format {
        case .json:
            let rows = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
            #expect(rows.count == 321)
            #expect(rows.first?["id"] as? String == "410"); #expect(rows.last?["id"] as? String == "90")
            #expect(rows.first?["note"] as? String == "雪,410")
            #expect(rows.last?["note"] is NSNull)
            #expect(rows.first?["amount"] as? String == "410.25")
        case .csv:
            let csv = String(decoding: bytes.dropFirst(3), as: UTF8.self)
            #expect(csv.hasPrefix("id,note,amount\r\n410,\"雪,410\",410.25\r\n"))
            #expect(csv.hasSuffix("90,NULL,90.25\r\n"))
        case .sql:
            let sql = String(decoding: bytes, as: UTF8.self)
            #expect(sql.contains("INSERT INTO `export_rows`")); #expect(sql.contains("'410'")); #expect(sql.contains("'90'"))
            #expect(!sql.contains("'89'")); #expect(!sql.contains("'411'"))
        case .xlsx: #expect(bytes.starts(with: [0x50, 0x4b]))
        }
        // Already-loaded page keeps its bounded scope.
        options.scope = .currentData
        let loaded = try snapshot.request(options: options)
        #expect(loaded.estimatedRowCount == 25)
    }

    @Test @MainActor func viewAndEmptyFilteredTableKeepRealColumnsAndAllRows() async throws {
        let config = try configuration(), service = MobileMySQLService()
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for isEmpty in [false, true] {
            let object = object("export_view", kind: .view)
            let columns = try await service.columns(configuration: config, object: object)
            let filter = isEmpty ? WorkspaceDatabaseDataFilter(conditions: [.init(columnName: "id", columnKind: .number,
                operation: .lessThan, value: "0")]) : .empty
            let page = try await service.page(configuration: config, object: object, columns: columns, offset: 0,
                size: 25, sortColumn: "id", ascending: true, filter: filter)
            let snapshot = MobileDataExportSnapshot.table(page, configuration: config, service: service)
            let model = MobileDataExportModel(snapshot: snapshot, temporaryRoot: root)
            if isEmpty { #expect(!model.canPrepare); #expect(snapshot.allRowsProvider != nil) }
            model.scope = .allTableRows; model.format = .json
            #expect(model.canPrepare)
            await model.prepare()?.value
            let file = try #require(model.file)
            #expect(file.rowCount == (isEmpty ? 0 : 455))
            #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) is [[String: Any]])
            model.cancel()
        }
    }

    @Test func oversizedRowFailsRatherThanExportingTruncatedData() async throws {
        let config = try configuration(), service = MobileMySQLService(), object = object("export_large")
        let columns = try await service.columns(configuration: config, object: object)
        // A previously committed empty preview, e.g. prior to an external insert.
        let metadata = try await MobileMariaDBExecutor().preview(configuration: config,
            sql: "SELECT * FROM querycraft_ios_proof.export_large WHERE 1=0", maximumRows: 1, maximumBytes: 1024)
        let captured = MobileTableSnapshot(object: object, preview: metadata, columns: columns,
            offset: 0, pageSize: 25, hasNextPage: false, hasStableOrder: true)
        let snapshot = MobileDataExportSnapshot.table(captured, configuration: config, service: service)
        var options = WorkspaceDataExportPreferences().options(for: .csv); options.scope = .allTableRows
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "original.csv"); try Data("original".utf8).write(to: file)
        await #expect(throws: MobileQueryError.self) {
            _ = try await WorkspaceDataExporter().export(snapshot.request(options: options), to: file)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }

    @Test @MainActor func modelScopesAndCapturedSourceSurviveBrowserNavigation() async throws {
        let config = try configuration(), browser = MobileBrowserModel(configuration: config)
        let root = try root(); defer { browser.cancelAll(); try? FileManager.default.removeItem(at: root) }
        await browser.loadDatabases().value
        await browser.loadObjects()?.value
        await browser.selectObject(object())?.value
        let captured = try #require(browser.dataExportSnapshot())
        await browser.selectObject(object("epoch_values"))?.value
        let model = MobileDataExportModel(snapshot: captured, temporaryRoot: root)
        #expect(model.scope == .currentData)
        model.scope = .allTableRows; model.format = .json
        await model.prepare()?.value
        let file = try #require(model.file)
        #expect(file.rowCount == 455); #expect(model.completedRows == 455)
        #expect(browser.snapshot?.object.name == "epoch_values")
        #expect(browser.snapshot?.preview.result.rows.count == 3)
        model.cancel()
    }

    @Test @MainActor func failedBatchRetryCreatesFreshSourceWithoutAppendingOrLosingScope() async throws {
        let state = RetriableExportPages()
        let snapshot = MobileDataExportSnapshot(data: .init(columns: ["id"], rows: []), name: "captured",
            scopeDescription: "当前表页", allRowsProvider: .init(estimatedRowCount: nil, makeSource: {
                WorkspacePagedDataExportRowSource(pageSize: 200, loadPage: { offset, limit in
                    try await state.page(offset: offset, limit: limit)
                }, onFinish: { await state.close() })
            }))
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = MobileDataExportModel(snapshot: snapshot, temporaryRoot: root)
        model.scope = .allTableRows; model.format = .json
        await model.prepare()?.value
        #expect(model.file == nil); #expect(model.message != nil); #expect(model.canPrepare)
        #expect(model.scope == .allTableRows); #expect(snapshot.data.rows.isEmpty)
        await model.prepare()?.value
        let file = try #require(model.file)
        #expect(file.rowCount == 455); #expect(model.message == nil)
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [[String: String]])
        #expect(rows.count == 455); #expect(rows.first?["id"] == "0"); #expect(rows.last?["id"] == "454")
        #expect(await state.offsets == [0, 200, 0, 200, 400]); #expect(await state.closes == 2)
        model.cancel()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func sharedSourceFencesSchemaChangesAndClosesOnceOnFailure() async throws {
        let state = ExportPageTestState()
        let source = WorkspacePagedDataExportRowSource(pageSize: 200, loadPage: { offset, limit in
            await state.record(offset, limit)
            return .init(columns: [.init(id: 0, name: offset == 0 ? "id" : "changed")],
                rows: (0..<limit).map { .init(id: offset + $0, values: [.text(String(offset + $0))]) }, hasNextPage: true)
        }, onFinish: { await state.close() })
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "out.json"); try Data("original".utf8).write(to: file)
        let request = WorkspaceDataExportRequest(columns: [.init(name: "id", dataIndex: 0)],
            options: WorkspaceDataExportPreferences().options(for: .json), estimatedRowCount: nil,
            worksheetName: "out", source: source)
        await #expect(throws: WorkspaceDataExportError.self) {
            _ = try await WorkspaceDataExporter().export(request, to: file)
        }
        await source.finish()
        #expect(await state.offsets == [0, 200]); #expect(await state.limits == [200, 200])
        #expect(await state.closes == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }

    @Test func cancelledInFlightPageCannotResumeOrPublishAFile() async throws {
        let state = ExportPageTestState()
        let source = WorkspacePagedDataExportRowSource(pageSize: 200, loadPage: { offset, limit in
            await state.record(offset, limit)
            try await Task.sleep(for: .seconds(10))
            return .init(columns: [.init(id: 0, name: "id")], rows: [], hasNextPage: false)
        }, onFinish: { await state.close() })
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "out.json")
        let request = WorkspaceDataExportRequest(columns: [.init(name: "id", dataIndex: 0)],
            options: WorkspaceDataExportPreferences().options(for: .json), estimatedRowCount: nil,
            worksheetName: "out", source: source)
        let task = Task { try await WorkspaceDataExporter().export(request, to: file) }
        let deadline = ContinuousClock.now + .seconds(3)
        while await state.offsets.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await state.closes == 1); #expect(try await source.nextBatch() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

private actor ExportPageTestState {
    var offsets: [Int] = []
    var limits: [Int] = []
    var closes = 0
    func record(_ offset: Int, _ limit: Int) { offsets.append(offset); limits.append(limit) }
    func close() { closes += 1 }
}

private actor RetriableExportPages {
    var offsets: [Int] = []
    var closes = 0
    private var failed = false
    func close() { closes += 1 }
    func page(offset: Int, limit: Int) throws -> WorkspacePagedDataExportRowSource.Page {
        offsets.append(offset)
        if offset == 200, !failed { failed = true; throw CocoaError(.fileReadNoPermission) }
        let end = min(455, offset + limit)
        return .init(columns: [.init(id: 0, name: "id")],
            rows: (offset..<end).map { .init(id: $0, values: [.text(String($0))]) }, hasNextPage: end < 455)
    }
}
