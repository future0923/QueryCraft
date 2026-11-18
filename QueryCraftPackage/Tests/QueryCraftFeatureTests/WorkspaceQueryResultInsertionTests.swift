import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

struct WorkspaceQueryResultInsertionTests {
    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka])
    func enablesInsertionOnlyForSupportedSQLDrivers(_ type: DatabaseType) async throws {
        let syntax = try await parse("SELECT name AS display_name FROM users WHERE 1 = 0")
        let selection = WorkspaceQueryResultInsertion.selection(
            columns: columns, currentDatabase: "app", databaseType: type,
            supportsDataEditing: true, syntax: syntax
        )
        #expect((selection != nil) == (type == .mysql || type == .postgresql))
        #expect(WorkspaceQueryResultInsertion.selection(
            columns: columns, currentDatabase: "app", databaseType: type,
            supportsDataEditing: false, syntax: syntax
        ) == nil)
    }

    @Test(arguments: [
        "SELECT a.name FROM users a JOIN users b ON a.id=b.id",
        "SELECT name FROM users UNION ALL SELECT name FROM users",
        "SELECT name FROM users WHERE id IN (SELECT id FROM users)",
        "SELECT name FROM other_table",
        "SELECT name FROM users; SELECT name FROM users;",
        "SELECT FROM",
    ])
    func rejectsAmbiguousOrUnreliableSources(_ sql: String) async throws {
        #expect(WorkspaceQueryResultInsertion.selection(
            columns: columns, currentDatabase: "app", databaseType: .mysql,
            supportsDataEditing: true, syntax: try await parse(sql)
        ) == nil)
    }

    @Test
    func resolvesQualifiedPostgreSQLSourceWithoutGuessingFromAlias() async throws {
        let projected = [WorkspaceDatabaseDataColumn(id: 0, name: "display_name", origin: .init(
            databaseName: "app", schemaName: "audit", tableName: "users", columnName: "name"
        ))]
        let selection = WorkspaceQueryResultInsertion.selection(
            columns: projected, currentDatabase: "app", databaseType: .postgresql,
            supportsDataEditing: true, syntax: try await parse("SELECT name AS display_name FROM audit.users")
        )
        #expect(selection?.databaseName == "app")
        #expect(selection?.objectName == "audit.users")
        #expect(WorkspaceQueryResultInsertion.selection(
            columns: [.init(id: 0, name: "name")], currentDatabase: "app", databaseType: .postgresql,
            supportsDataEditing: true, syntax: try await parse("SELECT 'name' AS name FROM audit.users")
        ) == nil)
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql])
    func partialAndEmptyResultUsesFullMetadataAndServerDefaults(_ type: DatabaseType) async throws {
        let selection = try #require(WorkspaceQueryResultInsertion.selection(
            columns: columns, currentDatabase: "app", databaseType: type,
            supportsDataEditing: true, syntax: try await parse("SELECT name AS display_name FROM users WHERE 1 = 0")
        ))
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(selection: selection, columns: [
            column("id", extra: type == .mysql ? "auto_increment" : "IDENTITY"),
            column("name"), column("required_not_projected"),
            column("optional", nullable: true), column("state", defaultValue: "ready"),
            column("computed", extra: "STORED GENERATED"),
        ])
        #expect(request.columns.map(\.id) == ["id", "name", "required_not_projected", "optional", "state"])
        var editor = WorkspaceDatabaseDataRowInsertEditorState()
        editor.present(request)
        editor.update(columnName: "name", draft: .init(mode: .value, text: "O'Reilly"))
        editor.update(columnName: "required_not_projected", draft: .init(mode: .value, text: ""))
        editor.update(columnName: "optional", draft: .init(mode: .null, text: ""))
        let insert = try editor.makeInsert()
        #expect(insert.values.map(\.columnName) == ["name", "required_not_projected", "optional"])
        #expect(insert.values.map(\.value) == [.text("O'Reilly"), .text(""), .null])
        let preview = try WorkspaceSQLPreviewStatement.make(rowInsert: insert, databaseType: type)
        #expect(preview.sql.contains("INSERT INTO"))
        #expect(preview.sql.contains("NULL"))
        #expect(preview.sql.contains("display_name") == false)
        let changes = WorkspaceDatabaseDataChangeSet(updates: [], inserts: try editor.makeInserts(), deletes: [])
        #expect(changes.hasConsistentSelection)
        #expect(changes.isEmpty == false)
    }

    @MainActor @Test
    func sharedDraftGridStagesValuesByStableIDAndDoesNotWriteToResultStore() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: .init(databaseName: "app", objectName: "users", kind: .table),
            columns: [column("name")]
        )
        var editor = WorkspaceDatabaseDataRowInsertEditorState()
        editor.present(request)
        editor.appendRow()
        let firstID = try #require(editor.rowID(at: 0))
        let secondID = try #require(editor.rowID(at: 1))
        let page = WorkspaceDatabaseDataPage(columns: [.init(id: 0, name: "name")], rows: [], offset: 0, limit: 200, hasNextPage: false)
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page, isFetching: false, sortData: { _ in },
            databaseColumns: request.columns.map(\.column), rowInsertEditor: editor,
            updateRowInsertDraft: { id, name, draft in
                editor.update(rowID: id, columnName: name, draft: draft)
            }
        )
        let table = try #require(coordinator.makeScrollView().documentView as? WorkspaceDirectDrawTableView)
        #expect(table.canEditCellHandler?(1, 1) == true)
        #expect(table.singleClickCellHandler?(1, 1) == true)
        let field = try #require(table.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "staged"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(editor.draft(rowID: secondID, for: "name")?.text == "staged")
        editor.removeRow(id: firstID)
        editor.update(rowID: firstID, columnName: "name", draft: .init(mode: .value, text: "late callback"))
        #expect(try editor.makeInsert().values.first?.value == .text("staged"))
        #expect(page.rowCount == 0)
        editor.dismiss()
        #expect(editor.isPresented == false)
    }

    private var columns: [WorkspaceDatabaseDataColumn] {
        [.init(id: 0, name: "display_name", origin: .init(databaseName: "app", tableName: "users", columnName: "name"))]
    }

    @MainActor @Test
    func insertSheetMountsAllFieldsInLightDarkAndNarrowWindows() async throws {
        var editor = WorkspaceDatabaseDataRowInsertEditorState()
        editor.present(try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: .init(databaseName: "app", objectName: "users", kind: .table),
            columns: [column("name"), column("required_not_projected"), column("optional", nullable: true)]
        ))
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: WorkspaceQueryResultInsertSheet(editor: editor, stage: { _ in })
                .environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 600, height: 480),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.close() }
            for size in [CGSize(width: 600, height: 480), .init(width: 900, height: 600)] {
                window.setContentSize(size)
                host.layoutSubtreeIfNeeded()
                await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
                host.layoutSubtreeIfNeeded()
                let table = try #require(descendants(host).compactMap { $0 as? WorkspaceDirectDrawTableView }.first)
                #expect(table.numberOfRows == 1)
                #expect(table.tableColumns.count == 4)
                #expect(table.bounds.height >= 200)
                #expect(host.frame.size == size)
                if scheme == .dark {
                    window.appearance?.performAsCurrentDrawingAppearance {
                        let color = table.backgroundColor.usingColorSpace(.deviceRGB)
                        // macOS dark base background is the opaque soft gray #181818.
                        let base = CGFloat(0x18) / 255
                        #expect(abs((color?.redComponent ?? -1) - base) < 0.002)
                        #expect(abs((color?.greenComponent ?? -1) - base) < 0.002)
                        #expect(abs((color?.blueComponent ?? -1) - base) < 0.002)
                        #expect(color?.alphaComponent == 1)
                    }
                }
            }
        }
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func column(_ name: String, nullable: Bool = false, defaultValue: String? = nil, extra: String = "") -> WorkspaceDatabaseColumn {
        .init(name: name, type: "text", collation: nil, isNullable: nullable, key: "", defaultValue: defaultValue, extra: extra, comment: "")
    }

    private func parse(_ sql: String) async throws -> SQLParseSnapshot {
        let parser = try SQLStructuralParser()
        return try await parser.parse(.init(revision: .init(1), text: sql))
    }
}
