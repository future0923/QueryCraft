import AppKit
import Foundation
import SwiftUI
@testable import QueryCraftFeature

actor BatchCollector {
    var rows: [WorkspaceDatabaseDataRow] = []
    func append(_ batch: WorkspaceDatabaseDataBatch) { rows += batch.rows }
}

struct MetadataCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct DockerSQLMetadataCheck {
    @MainActor static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let env = ProcessInfo.processInfo.environment
        let type = DatabaseType(rawValue: env["CHECK_DRIVER"]!)!
        let bundle = Bundle(path: env["CHECK_BUNDLE"]!)!
        try bundle.loadAndReturnError()
        guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else {
            throw MetadataCheckFailure(description: "Driver entry unavailable")
        }
        try await entry.init().activate()
        let database = env["CHECK_DATABASE"]!
        let first = env["CHECK_FIRST"]!
        let second = env["CHECK_SECOND"]!
        let session = try await DatabaseDriverRegistry.shared.makeSession(configuration: .init(
            databaseType: type, host: "127.0.0.1", port: Int(env["CHECK_PORT"]!)!,
            username: env["CHECK_USER"]!, password: env["CHECK_PASSWORD"],
            database: database, tlsMode: .disabled
        ))
        do {
            try await session.connect()
            try await verify(session: session, type: type, database: database, first: first, second: second)
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }

    @MainActor static func verify(session: any WorkspaceSession, type: DatabaseType, database: String, first: String, second: String) async throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw MetadataCheckFailure(description: message) }
        }
        let isPG = type == .postgresql
        // Register PostgreSQL schema-qualified identities as the sidebar does.
        _ = try await session.fetchObjects(in: database)
        let object = WorkspaceDatabaseObject(name: isPG ? "\(first).users" : "users", kind: .table)
        let details = try await session.fetchDetails(for: object, in: isPG ? database : first)
        let nickname = details.columns.first { $0.name == "user_nick" }!
        try check(nickname.comment == "昵称（员工名称），这是一段较长的字段注释，用于验证单行省略与完整提示", "Table comment missing")
        try check(nickname.type.contains("20"), "Table varchar length missing: \(nickname.type)")
        let decimal = details.columns.first { $0.name == "amount" }!
        try check(decimal.type.contains("12") && decimal.type.contains("2"), "Table decimal precision missing: \(decimal.type)")
        if isPG {
            let array = details.columns.first { $0.name == "tags" }!
            try check(array.type == "integer[]", "Table array element type missing: \(array.type)")
            let view = try await session.fetchDetails(for: .init(name: "\(first).user_view", kind: .view), in: database)
            try check(view.columns.first?.comment == "视图昵称", "View column comment missing")
        }

        let tableRows = BatchCollector()
        let fetched = try await session.fetchDataPage(for: object, in: isPG ? database : first, offset: 0, limit: 10, sort: .none, onBatch: { await tableRows.append($0) })
        let page = WorkspaceDatabaseDataPage(columns: fetched.columns, rows: await tableRows.rows, offset: 0, limit: 10, hasNextPage: fetched.hasNextPage)
        let selection = WorkspaceDatabaseObjectSelection(databaseName: isPG ? database : first, objectName: object.name, kind: .table)
        let context = WorkspaceDatabaseInspectorContext(selection: selection, detailsState: .loaded(details), page: page, selectedRowIndexes: IndexSet(integer: 0), rowInsertEditor: .init(), pendingLoadedUpdates: [], schemaInspector: nil, isUpdatingLoadedValue: false, loadDetails: {}, updateLoadedValue: { _, _, _ in }, updateDraftValue: { _, _, _ in })
        try check(context.fields?.first { $0.name == "user_nick" }?.comment == nickname.comment, "Table inspector comment mismatch")
        try verifyHeader(columns: page.columns, details: Dictionary(uniqueKeysWithValues: page.columns.compactMap { col in details.columns.first { $0.name == col.sourceColumnName }.map { (col.id, $0) } }))
        if let preview = ProcessInfo.processInfo.environment["CHECK_PREVIEW_PATH"] {
            try await render(context: context, details: details, page: page, path: preview)
        }

        let expression = isPG ? "42::bigint" : "CAST(42 AS UNSIGNED)"
        let sql = "SELECT a.user_nick AS display_name, b.id AS display_name, \(expression) AS user_nick, a.amount AS amount_alias FROM \(first).users a JOIN \(second).users b ON a.id = b.id"
        for empty in [false, true] {
            let batches = BatchCollector()
            let result = try await session.executeReadOnlyQuery(sql + (empty ? " WHERE 1 = 0" : ""), database: database, onBatch: { await batches.append($0) })
            let columns = result.columns
            let rows = await batches.rows
            try check(columns.count == 4 && rows.count == (empty ? 0 : 1), "Query/empty result shape mismatch")
            try check(columns[0].name == columns[1].name, "Duplicate aliases lost")
            try check(columns[0].origin?.columnName == "user_nick", "Alias source lost")
            try check((isPG ? columns[1].origin?.schemaName : columns[1].origin?.databaseName) == second, "Cross-schema/database source lost")
            try check(columns[2].origin == nil && columns[2].type?.contains("bigint") == true, "Expression source/type incorrect: \(columns[2])")
            var mapped: [Int: WorkspaceDatabaseColumn] = [:]
            for col in columns {
                guard let origin = col.origin, let source = WorkspaceQueryResultEditing.selection(for: origin, currentDatabase: database) else { continue }
                let info = try await session.fetchDetails(for: .init(name: source.objectName, kind: source.kind), in: source.databaseName)
                mapped[col.id] = info.columns.first { $0.name == origin.columnName }
            }
            try check(mapped[0]?.comment == nickname.comment && mapped[1]?.comment == "归档编号", "Query source comments mismatched")
            try check(mapped[2] == nil, "Expression borrowed field metadata")
            try verifyHeader(columns: columns, details: mapped)
            if let row = rows.first {
                let queryPage = WorkspaceQueryResultPage(columns: columns, store: try .init(temporary: false), rowCount: rows.count)
                let inspector = WorkspaceQueryResultInspectorContext(page: queryPage, selectedRowIndex: 0, row: row).withColumnDetails(mapped)
                try check(inspector.fields?[0].comment == nickname.comment && inspector.fields?[1].comment == "归档编号" && inspector.fields?[2].comment == "", "Query inspector source comments mismatch")
            }
        }
        print("PASS \(type.rawValue): packaged driver, table/query headers and inspectors, comments, complete types, duplicate aliases, cross-schema/database join, expression and empty result")
    }

    @MainActor static func render(context: WorkspaceDatabaseInspectorContext, details: WorkspaceDatabaseObjectDetails, page: WorkspaceDatabaseDataPage, path: String) async throws {
        let mapped = Dictionary(uniqueKeysWithValues: page.columns.compactMap { col in details.columns.first { $0.name == col.sourceColumnName }.map { (col.id, $0) } })
        for dark in [false, true] {
            let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page, isFetching: false, sqlHeaderConfiguration: .init(columnDetails: mapped), sortData: { _ in })
            let scroll = coordinator.makeScrollView()
            let hosting = NSHostingView(rootView: WorkspaceInspectorView(context: .database(context)).environment(\.colorScheme, dark ? .dark : .light))
            let container = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 400))
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1000, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = container
            scroll.frame = .init(x: 0, y: 0, width: 700, height: 400)
            hosting.frame = .init(x: 700, y: 0, width: 300, height: 400)
            container.addSubview(scroll)
            container.addSubview(hosting)
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(50))
                container.layoutSubtreeIfNeeded()
            }
            guard let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
                throw MetadataCheckFailure(description: "Offscreen preview unavailable")
            }
            container.cacheDisplay(in: container.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw MetadataCheckFailure(description: "PNG preview unavailable")
            }
            try png.write(to: URL(fileURLWithPath: path + (dark ? "-dark.png" : "-light.png")))
            window.contentView = nil
        }
    }

    @MainActor static func verifyHeader(columns: [WorkspaceDatabaseDataColumn], details: [Int: WorkspaceDatabaseColumn]) throws {
        let table = NSTableView(frame: .init(x: 0, y: 0, width: 800, height: 200))
        table.headerView = WorkspaceGridHeaderView(frame: .init(x: 0, y: 0, width: 800, height: 64))
        for col in columns {
            let native = NSTableColumn(identifier: .init("queryResult.column.\(col.id)"))
            native.title = col.name
            table.addTableColumn(native)
        }
        WorkspaceSQLGridHeader.configure(in: table, columns: columns, configuration: .init(columnDetails: details))
        for (col, native) in zip(columns, table.tableColumns) {
            guard let cell = native.headerCell as? WorkspaceSQLGridHeaderCell,
                  cell.comment == (details[col.id]?.comment ?? ""),
                  cell.columnType == (details[col.id]?.type ?? col.type ?? ""),
                  table.headerView?.frame.height == 64 else {
                throw MetadataCheckFailure(description: "Native three-line header metadata mismatch")
            }
        }
    }
}
