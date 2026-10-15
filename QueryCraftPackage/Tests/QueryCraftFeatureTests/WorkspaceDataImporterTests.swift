import Foundation
import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

struct WorkspaceDataImporterTests {
    @Test("Mapping rejects duplicate targets, generated columns, missing required fields and NULL")
    func mappingValidation() throws {
        let schema = WorkspaceDataImportSchema(columns: [column("id"), column("value", nullable: true), column("computed", extra: "STORED GENERATED")], tableParts: ["db", "table"], supportsRollback: true)
        let file = try WorkspaceDataImportFile(columns: ["ID", "value"], rows: [["1", "ok"]])
        #expect(schema.automaticMapping(file.columns) == ["id", "value"])
        let invalidMappings: [[String?]] = [["id", "id"], [nil, "value"], ["id", "computed"]]
        for mapping in invalidMappings {
            let plan = WorkspaceDataImportPlan(file: file, schema: schema, mapping: mapping, batchSize: 2, dialect: .mysql)
            #expect(throws: WorkspaceDataImportError.self) { try plan.validate() }
        }
        let nulls = try WorkspaceDataImportFile(columns: ["id"], rows: [[nil]])
        #expect(throws: WorkspaceDataImportError.self) {
            try WorkspaceDataImportPlan(file: nulls, schema: schema, mapping: ["id"], batchSize: 2, dialect: .mysql).validate()
        }
    }

    @Test("Import captures database and qualified identifiers, skips generated fields, and commits exact batches", arguments: [DatabaseType.mysql, .postgresql])
    func commits(type: DatabaseType) async throws {
        let session = ImportTestSession(type: type)
        let (target, plan, factory) = try await makePlan(session: session, type: type, count: 5)
        #expect(plan.mapping == ["id", "value"])
        let result = await WorkspaceDataImporter().run(target: target, plan: plan, authorize: {}, progress: { _ in })
        #expect(result.status == .completed)
        #expect(result.committedRows == 5)
        let queries = await session.queries
        let inserts = queries.filter { $0.hasPrefix("INSERT") }
        #expect(inserts.count == 3)
        #expect(queries.contains("COMMIT"))
        #expect(!queries.contains("ROLLBACK"))
        #expect(await factory.databases.allSatisfy { $0 == "target_db" })
        #expect(await session.isConnected() == false)
        let expected = type == .postgresql ? "\"audit\".\"table.with.dot\"" : "`target_db`.`table.with.dot`"
        #expect(inserts.allSatisfy { $0.contains(expected) })
        #expect(inserts.allSatisfy { $0.contains("OVERRIDING SYSTEM VALUE") == (type == .postgresql) })
        let rows = try inserts.flatMap { try WorkspaceSQLImporter.read($0, options: .init()).rows }
        #expect(try rows == plan.file.rows)
    }

    @Test("A corrupt disk snapshot fails before connecting or writing")
    func corruptSnapshot() async throws {
        let session = ImportTestSession()
        let (target, original, factory) = try await makePlan(session: session)
        let spool = try WorkspaceDataImportSpool()
        try Data([0, 1, 2]).write(to: spool.url)
        let file = try WorkspaceDataImportFile(columns: original.file.columns, storage: .disk(spool, offsets: [0, 8]), previewRows: [])
        let plan = WorkspaceDataImportPlan(file: file, schema: original.schema, mapping: original.mapping, batchSize: 2, dialect: .mysql)
        let before = await factory.databases.count
        let result = await WorkspaceDataImporter().run(target: target, plan: plan, authorize: {}, progress: { _ in })
        #expect(result.status == .failed)
        #expect(result.committedRows == 0)
        #expect(await factory.databases.count == before)
        #expect(await session.queries.isEmpty)
    }

    @Test("Disk-backed imports commit complete full-length values and retain rollback behavior")
    func diskExecution() async throws {
        let builder = WorkspaceDataImportRowBuilder()
        let payload = String(repeating: "x", count: 2048)
        for index in 0..<2501 { try builder.append([String(index), payload]) }
        let file = try builder.finish(columns: ["id", "value"])
        #expect(file.isDiskBacked)
        for failure: Int? in [nil, 2] {
            let session = ImportTestSession(failInsert: failure)
            let (target, base, _) = try await makePlan(session: session)
            let plan = WorkspaceDataImportPlan(file: file, schema: base.schema, mapping: ["id", "value"], batchSize: 1000, dialect: .mysql)
            let result = await WorkspaceDataImporter().run(target: target, plan: plan, authorize: {}, progress: { _ in })
            #expect(result.status == (failure == nil ? .completed : .failed))
            #expect(result.committedRows == (failure == nil ? 2501 : 0))
            let inserts = await session.queries.filter { $0.hasPrefix("INSERT") }
            let first = try #require(inserts.first)
            #expect(try WorkspaceSQLImporter.read(first, options: .init()).readRows(in: 0..<1)[0][1] == payload)
            #expect(await session.queries.contains(failure == nil ? "COMMIT" : "ROLLBACK"))
        }
    }

    @Test("Mapping menus defer their choices until opened and preserve selection on cell reuse")
    @MainActor func lazyMappingMenu() throws {
        let popup = WorkspaceDataImportMappingPopUpButton()
        let choices = [("", "Skip")] + (0..<1000).map { ("field_\($0)", "field_\($0) · text") }
        popup.configure(choices: choices, selected: "field_77")
        #expect(popup.numberOfItems == 1)
        #expect(popup.titleOfSelectedItem == "field_77 · text")
        let menu = try #require(popup.menu)
        popup.menuNeedsUpdate(menu)
        #expect(popup.numberOfItems == 1001)
        #expect(popup.selectedItem?.representedObject as? String == "field_77")
        popup.selectItem(at: 1)
        #expect(popup.selectedItem?.representedObject as? String == "field_0")
        popup.configure(choices: choices, selected: "")
        #expect(popup.numberOfItems == 1)
        #expect(popup.titleOfSelectedItem == "Skip")
        popup.menuNeedsUpdate(menu)
        #expect(popup.selectedItem?.representedObject as? String == "")
    }

    @Test("Wide import tables reuse visible controls and scroll independently in an offscreen window")
    @MainActor func wideTablesScroll() async throws {
        let source = (0..<1000).map { WorkspaceDataImportModel.SourceColumn(name: "field_\($0)", index: $0) }
        let target = (0..<1000).map { column("field_\($0)") }
        let rows = (0..<200).map { WorkspaceDataImportModel.PreviewRow(id: $0, cells: Array(repeating: String($0), count: 78)) }
        let host = NSHostingView(rootView: HStack {
            WorkspaceDataImportMappingTable(sourceColumns: source, targetColumns: target, mapping: source.map { $0.name }, onChange: { _, _ in }).frame(width: 300)
            WorkspaceDataImportPreviewTable(rows: rows, columns: Array(source.prefix(78)))
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
        }
        func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
        let tables = tables(in: host)
        let mapping = try #require(tables.first(where: { $0.tableColumns.count == 2 }))
        let preview = try #require(tables.first(where: { $0.tableColumns.count == 78 }))
        #expect(mapping.numberOfRows == 1000)
        #expect(preview.numberOfRows == 200)
        #expect(preview.rowView(atRow: 0, makeIfNecessary: true) is WorkspaceDatabaseDataRowView)
        #expect(preview.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)
        let previewOrigin = try #require(preview.enclosingScrollView).contentView.bounds.origin
        mapping.scrollRowToVisible(999)
        mapping.layoutSubtreeIfNeeded()
        #expect(try #require(mapping.enclosingScrollView).contentView.bounds.origin.y > 0)
        #expect(try #require(preview.enclosingScrollView).contentView.bounds.origin == previewOrigin)
        let visible = mapping.rows(in: mapping.visibleRect)
        #expect(visible.length > 0 && visible.length < 30)
        let mappingOrigin = try #require(mapping.enclosingScrollView).contentView.bounds.origin
        preview.scrollRowToVisible(199)
        preview.scrollColumnToVisible(77)
        preview.layoutSubtreeIfNeeded()
        #expect(try #require(preview.enclosingScrollView).contentView.bounds.origin.x > 0)
        #expect(try #require(preview.enclosingScrollView).contentView.bounds.origin.y > 0)
        #expect(try #require(mapping.enclosingScrollView).contentView.bounds.origin == mappingOrigin)
        var controls = 0
        for row in 0..<1000 {
            if let cell = mapping.view(atColumn: 1, row: row, makeIfNecessary: false),
               let popup = cell.subviews.first(where: { $0 is NSPopUpButton }) as? NSPopUpButton {
                controls += 1
                #expect(popup.numberOfItems == 1)
            }
        }
        #expect(controls > 0 && controls < 40)
    }

    @Test("A failed batch rolls back every row and closes its session")
    func rollback() async throws {
        let session = ImportTestSession(failInsert: 2)
        let (target, plan, _) = try await makePlan(session: session)
        let result = await WorkspaceDataImporter().run(target: target, plan: plan, authorize: {}, progress: { _ in })
        #expect(result.status == .failed)
        #expect(result.committedRows == 0)
        #expect(await session.queries.contains("ROLLBACK"))
        #expect(await session.queries.contains("COMMIT") == false)
        #expect(await session.isConnected() == false)
    }

    @Test("Actual task cancellation rolls back using an uncancelled cleanup task")
    func cancel() async throws {
        let session = ImportTestSession()
        let (target, plan, _) = try await makePlan(session: session)
        let operation = Task {
            await WorkspaceDataImporter().run(target: target, plan: plan, authorize: {}, progress: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        let result = await operation.value
        #expect(result.status == .cancelled)
        #expect(result.committedRows == 0)
        #expect(await session.queries.filter { $0.hasPrefix("INSERT") }.count == 1)
        #expect(await session.queries.contains("ROLLBACK"))
        #expect(await session.rollbackWasCancelled == false)
    }

    @Test("Safety Lock is checked before connecting and again before each batch")
    @MainActor func lockChecks() async throws {
        let lock = WorkspaceSafetyLock()
        let session = ImportTestSession()
        let (target, plan, factory) = try await makePlan(session: session)
        let authorization: WorkspaceDataImporter.Authorize = {
            if lock.isEnabled { throw WorkspaceDatabaseDataRowInsertError.safetyLockEnabled }
        }
        let initialConnections = await factory.databases.count
        let blocked = await WorkspaceDataImporter().run(target: target, plan: plan, authorize: authorization, progress: { _ in })
        #expect(blocked.status == .failed)
        #expect(await factory.databases.count == initialConnections)
        #expect(await session.queries.isEmpty)
        lock.disable()
        let relocked = await WorkspaceDataImporter().run(target: target, plan: plan, authorize: authorization, progress: { _ in await lock.enable() })
        #expect(relocked.status == .failed)
        #expect(relocked.committedRows == 0)
        #expect(await session.queries.filter { $0.hasPrefix("INSERT") }.count == 1)
        #expect(await session.queries.contains("ROLLBACK"))
    }

    @Test("Lost commit or rollback acknowledgement is reported as uncertain", arguments: [true, false])
    func uncertain(commit: Bool) async throws {
        let session = ImportTestSession(failInsert: commit ? nil : 2, failCommit: commit, failRollback: !commit)
        let (target, plan, _) = try await makePlan(session: session)
        let result = await WorkspaceDataImporter().run(target: target, plan: plan, authorize: {}, progress: { _ in })
        #expect(result.status == .uncertain)
        #expect(result.committedRows == nil)
        #expect(await session.isConnected() == false)
    }

    @Test("Schema changes and nontransactional tables cannot start writes")
    func schemaChecks() async throws {
        let session = ImportTestSession()
        let (target, plan, _) = try await makePlan(session: session)
        await session.changeSchema()
        let result = await WorkspaceDataImporter().run(target: target, plan: plan, authorize: {}, progress: { _ in })
        #expect(result.status == .failed)
        #expect(await session.queries.isEmpty)
        let noRollback = WorkspaceDataImportSchema(columns: plan.schema.columns, tableParts: plan.schema.tableParts, supportsRollback: false)
        #expect(throws: WorkspaceDataImportError.self) {
            try WorkspaceDataImportPlan(file: plan.file, schema: noRollback, mapping: plan.mapping, batchSize: 2, dialect: .mysql).validate()
        }
        for type in [DatabaseType.doris, .redis, .elasticsearch, .kafka] { #expect(!WorkspaceDataImportTarget.supports(type)) }
    }

    @Test("Byte limits split batches and SQL-looking values stay data")
    func boundedStatements() async throws {
        let session = ImportTestSession()
        let (_, plan, _) = try await makePlan(session: session, count: 5)
        let batch = try plan.statement(from: 0, maximumBytes: plan.prefix.utf8.count + 160)
        #expect(batch.count == 1)
        #expect(try WorkspaceSQLImporter.read(batch.sql, options: .init()).rows[0] == plan.file.rows[0])
        #expect(throws: WorkspaceDataImportError.self) { try plan.statement(from: 0, maximumBytes: 10) }
    }

    @Test("Boolean values map to MySQL boolean storage without changing text columns")
    func booleanValues() throws {
        let boolean = WorkspaceDatabaseColumn(name: "flag", type: "tinyint(1)", collation: nil, isNullable: false, key: "", defaultValue: nil, extra: "", comment: "")
        let schema = WorkspaceDataImportSchema(columns: [boolean, column("label")], tableParts: ["db", "t"], supportsRollback: true)
        let file = try WorkspaceDataImportFile(columns: ["flag", "label"], rows: [["true", "true"], ["false", "false"]])
        let plan = WorkspaceDataImportPlan(file: file, schema: schema, mapping: ["flag", "label"], batchSize: 500, dialect: .mysql)
        let statement = try plan.statement(from: 0)
        #expect(try WorkspaceSQLImporter.read(statement.sql, options: .init()).rows == [["1", "true"], ["0", "false"]])
    }

    @Test("Wizard layouts mount without desktop input and keep a fixed content frame")
    @MainActor func wizardLayout() async throws {
        let session = ImportTestSession()
        let (target, _, _) = try await makePlan(session: session)
        let model = WorkspaceDataImportModel(target: target, targetLabel: "Test / target_db / table.with.dot", safetyLock: WorkspaceSafetyLock(), authorize: {})
        let directory = FileManager.default.temporaryDirectory.appending(path: "QueryCraftImportPreview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "sample.csv")
        try "id,value\n1,中文\n2,example".write(to: url, atomically: true, encoding: .utf8)
        model.selectFile(url)
        model.loadPreview()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.isLoading && ContinuousClock.now < deadline { await Task.yield() }
        #expect(!model.isLoading)
        #expect(model.errorMessage.isEmpty)
        #expect(model.mapping == ["id", "value"])
        let isolationPath = ProcessInfo.processInfo.environment["QUERYCRAFT_UI_VISUAL_QA_DIR"]
        if let isolationPath {
            try #require(FileManager.default.fileExists(atPath: isolationPath + "/shield.ready"))
        }
        for step in WorkspaceDataImportModel.Step.allCases {
            model.step = step
            let host = NSHostingView(rootView: WorkspaceDataImportView(model: model, close: {}).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.setContentSize(NSSize(width: 960, height: 720))
            // Normal regression stays offscreen. Explicit visual QA requires the
            // guarded screen/input isolation supervisor to be running.
            if isolationPath != nil {
                window.animationBehavior = .none
                window.center()
                window.orderFrontRegardless()
            }
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
            }
            #expect(host.bounds.width == 960)
            #expect(host.bounds.height == 720)
            if let isolationPath {
                try #require(FileManager.default.fileExists(atPath: isolationPath + "/shield.ready"))
                try await Task.sleep(for: .milliseconds(300))
                let request = URL(fileURLWithPath: isolationPath).appending(path: "capture-request")
                let acknowledgement = URL(fileURLWithPath: isolationPath).appending(path: "capture-done")
                try? FileManager.default.removeItem(at: acknowledgement)
                try "\(window.windowNumber)\n\(directory.appending(path: "visible-import-\(step.rawValue).png").path)".write(to: request, atomically: true, encoding: .utf8)
                let captureDeadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !FileManager.default.fileExists(atPath: acknowledgement.path), ContinuousClock.now < captureDeadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect((try? String(contentsOf: acknowledgement, encoding: .utf8)) == "0")
            }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    Attachment.record(data, named: "import-\(step.rawValue).png")
                    try data.write(to: directory.appending(path: "import-\(step.rawValue).png"))
                }
            }
            window.setContentSize(NSSize(width: 760, height: 580))
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.width == 760)
            #expect(host.bounds.height == 580)
            window.close()
        }
        if let isolationPath {
            let exportTarget = WorkspaceTableDataExportTarget(sessionFactory: target.sessionFactory, configuration: target.configuration, selection: target.selection)
            for format in WorkspaceDataExportFormat.contextMenuFormats {
                try #require(FileManager.default.fileExists(atPath: isolationPath + "/shield.ready"))
                WorkspaceTableDataExportPresenter.chooseDestination(target: exportTarget, format: format, preferences: .init())
                let panel = try await visibleFilePanel()
                defer { panel.cancel(nil) }
                #expect(!(panel is NSOpenPanel))
                #expect(panel.nameFieldStringValue == "table.with.dot.\(format.fileExtension)")
                #expect(panel.allowedContentTypes == [format.contentType])
                panel.cancel(nil)
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(FileManager.default.fileExists(atPath: isolationPath + "/shield.ready"))
            let selectedURL = model.fileURL
            model.chooseFile()
            let panel = try await visibleFilePanel()
            defer { panel.cancel(nil) }
            let open = try #require(panel as? NSOpenPanel)
            #expect(!open.canChooseDirectories)
            #expect(!open.allowsMultipleSelection)
            open.cancel(nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.fileURL == selectedURL)
        }
        model.close()
    }

    @MainActor private func visibleFilePanel() async throws -> NSSavePanel {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let panel = NSApp.windows.first(where: { $0 is NSSavePanel && $0.isVisible }) as? NSSavePanel { return panel }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WorkspaceDataImportError.invalid("UI", "Native file panel did not appear")
    }

    private func makePlan(session: ImportTestSession, type: DatabaseType = .mysql, count: Int = 5) async throws -> (WorkspaceDataImportTarget, WorkspaceDataImportPlan, ImportTestFactory) {
        let factory = ImportTestFactory(session: session)
        let target = WorkspaceDataImportTarget(sessionFactory: factory,
            configuration: .init(databaseType: type, host: "localhost", port: 3306, username: "test", password: nil, database: "unrelated", tlsMode: .disabled),
            selection: .init(databaseName: "target_db", objectName: type == .postgresql ? "audit.table.with.dot" : "table.with.dot", kind: .table))
        let schema = try await target.loadSchema()
        let file = try WorkspaceDataImportFile(columns: ["id", "value"], rows: (0..<count).map { [String($0), "'); DROP TABLE unrelated; -- \\中文"] })
        let plan = WorkspaceDataImportPlan(file: file, schema: schema, mapping: schema.automaticMapping(file.columns), batchSize: 2, dialect: target.dialect)
        return (target, plan, factory)
    }
    private func column(_ name: String, nullable: Bool = false, extra: String = "") -> WorkspaceDatabaseColumn {
        .init(name: name, type: "text", collation: nil, isNullable: nullable, key: "", defaultValue: nil, extra: extra, comment: "")
    }
}

private actor ImportTestFactory: WorkspaceSessionFactory {
    let session: ImportTestSession
    private(set) var databases: [String?] = []
    init(session: ImportTestSession) { self.session = session }
    func makeSession(configuration: DatabaseConnectionConfiguration) -> any WorkspaceSession {
        databases.append(configuration.database); return session
    }
}

private actor ImportTestSession: WorkspaceSession {
    let type: DatabaseType
    let failInsert: Int?
    let failCommit: Bool
    let failRollback: Bool
    private var connected = false, changed = false, insertCount = 0
    private(set) var queries: [String] = []
    private(set) var rollbackWasCancelled = false
    init(type: DatabaseType = .mysql, failInsert: Int? = nil, failCommit: Bool = false, failRollback: Bool = false) {
        self.type = type; self.failInsert = failInsert; self.failCommit = failCommit; self.failRollback = failRollback
    }
    func connect() { connected = true }
    func isConnected() async -> Bool { connected }
    func close() { connected = false }
    func connectionID() -> Int { 123 }
    func fetchDatabases() -> [String] { ["target_db"] }
    func fetchObjects(in database: String) -> [WorkspaceDatabaseObject] { [.init(name: "audit.table.with.dot", kind: .table)] }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) -> Int { 0 }
    func changeSchema() { changed = true }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) -> WorkspaceDatabaseObjectDetails {
        .init(columns: [
            .init(name: "id", type: changed ? "bigint" : "integer", collation: nil, isNullable: false, key: "PRI", defaultValue: nil, extra: type == .postgresql ? "IDENTITY" : "auto_increment", comment: ""),
            .init(name: "value", type: "text", collation: nil, isNullable: false, key: "", defaultValue: nil, extra: "", comment: ""),
            .init(name: "computed", type: "integer", collation: nil, isNullable: false, key: "", defaultValue: nil, extra: "STORED GENERATED", comment: "")
        ], ddl: "", tableInformation: .init(dataSize: nil, indexSize: nil, comment: "", engine: "InnoDB"))
    }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) -> WorkspaceDatabaseDataFetchResult {
        .init(columns: [.init(id: 0, name: "id", type: "bigint", origin: .init(databaseName: database, schemaName: "audit", tableName: "table.with.dot", columnName: "id"))], hasNextPage: false)
    }
    func executeStatement(_ sql: String, kind: SQLStatementKind, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        queries.append(sql)
        if sql == "SET SESSION sql_mode = CONCAT_WS(',', @@SESSION.sql_mode, 'STRICT_ALL_TABLES')" {
            throw WorkspaceSessionError.transactionStateUnavailable
        }
        if sql == "SELECT @@SESSION.sql_mode" {
            try await onBatch(.init(columns: [.init(id: 0, name: "sql_mode", type: "text")], rows: [.init(id: 0, values: [.text("STRICT_ALL_TABLES")])]))
        }
        if sql == "COMMIT" && failCommit { throw WorkspaceSessionError.notConnected }
        if sql == "ROLLBACK" {
            rollbackWasCancelled = Task.isCancelled
            if failRollback { throw WorkspaceSessionError.notConnected }
        }
        if kind == .insert {
            insertCount += 1
            if insertCount == failInsert { throw WorkspaceDataImportError.invalid("模拟写入失败", "Simulated write failure") }
            let rows = try WorkspaceSQLImporter.read(sql, options: .init()).rows.count
            return .init(columns: [], rowCount: rows)
        }
        return .init(columns: [], rowCount: 0)
    }
}
