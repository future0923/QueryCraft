import AppKit
import Testing

@testable import QueryCraftFeature

struct WorkspaceDatabaseDataRowInsertTests {
    @Test
    func preparesElasticsearchDocumentColumnsForGridCreation() throws {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "Elasticsearch",
            objectName: "logs-write",
            kind: .elasticsearchAlias
        )
        let request = WorkspaceDatabaseDataRowInsertRequest
            .makeElasticsearchDocument(
                selection: selection,
                pageColumns: [
                    WorkspaceDatabaseDataColumn(id: 0, name: "_id"),
                    WorkspaceDatabaseDataColumn(id: 1, name: "_index"),
                    WorkspaceDatabaseDataColumn(id: 2, name: "_score"),
                    WorkspaceDatabaseDataColumn(id: 3, name: "_routing"),
                    WorkspaceDatabaseDataColumn(id: 4, name: "name"),
                    WorkspaceDatabaseDataColumn(id: 5, name: "profile"),
                ]
            )

        #expect(request.columns.map(\.id) == [
            "name", "profile", "_id", "_routing",
        ])
        #expect(request.columns[0].initialDraft.mode == .null)
        #expect(request.columns[1].initialDraft.mode == .null)
        #expect(request.columns[2].initialDraft.mode == .unfilled)
        #expect(request.columns[3].initialDraft.mode == .unfilled)

        var editor = WorkspaceDatabaseDataRowInsertEditorState()
        editor.present(request)
        let rowID = try #require(editor.rowID(at: 0))
        editor.replaceDraftRow(
            id: rowID,
            drafts: [
                "name": .init(mode: .value, text: "Ada"),
                "_id": .init(mode: .value, text: "manual-1"),
            ],
            editedColumnNames: ["name", "_id", "unknown"]
        )

        #expect(editor.draft(rowID: rowID, for: "name")?.text == "Ada")
        #expect(editor.draft(rowID: rowID, for: "profile")?.mode == .null)
        #expect(editor.hasEditedColumn(rowID: rowID, columnName: "name"))
        #expect(editor.hasEditedColumn(rowID: rowID, columnName: "_id"))
        #expect(!editor.hasEditedColumn(rowID: rowID, columnName: "unknown"))
    }

    @Test
    func preparesEditableColumnsAndChoosesSafeInitialModes() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: makeSelection(),
            details: WorkspaceDatabaseObjectDetails(
                columns: [
                    makeColumn(name: "id", extra: "auto_increment"),
                    makeColumn(name: "name"),
                    makeColumn(name: "nickname", isNullable: true),
                    makeColumn(name: "state", defaultValue: "active"),
                    makeColumn(
                        name: "created_at",
                        type: "timestamp",
                        isNullable: true,
                        defaultValue: "CURRENT_TIMESTAMP",
                        extra: "DEFAULT_GENERATED"
                    ),
                    makeColumn(name: "slug", extra: "STORED GENERATED"),
                ],
                ddl: ""
            )
        )

        #expect(
            request.columns.map(\.id)
                == ["id", "name", "nickname", "state", "created_at"]
        )
        #expect(request.columns[0].initialDraft.mode == .useDefault)
        #expect(request.columns[1].initialDraft.mode == .unfilled)
        #expect(request.columns[2].initialDraft.mode == .null)
        #expect(request.columns[3].initialDraft.mode == .useDefault)
        #expect(request.columns[4].initialDraft.mode == .useDefault)
    }

    @Test
    func treatsPostgreSQLIdentityAsGeneratedDuringInsertAndDuplication() throws {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "audit.events",
            kind: .table
        )
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: selection,
            details: WorkspaceDatabaseObjectDetails(
                columns: [
                    makeColumn(name: "id", type: "bigint", extra: "IDENTITY"),
                    makeColumn(name: "label", type: "text"),
                    makeColumn(
                        name: "generated_label",
                        type: "text",
                        extra: "STORED GENERATED"
                    ),
                ],
                ddl: ""
            )
        )

        #expect(request.columns.map(\.id) == ["id", "label"])
        #expect(request.columns[0].initialDraft.mode == .useDefault)
        #expect(request.columns[0].isAutoIncrement)

        var editor = WorkspaceDatabaseDataRowInsertEditorState()
        try editor.present(
            request,
            duplicating: WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("42"), .text("original"), .text("derived")]
            ),
            pageColumns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "id"),
                WorkspaceDatabaseDataColumn(id: 1, name: "label"),
                WorkspaceDatabaseDataColumn(id: 2, name: "generated_label"),
            ]
        )

        #expect(
            try editor.makeInsert().values == [
                .init(columnName: "label", value: .text("original")),
            ]
        )
    }

    @Test
    func omitsDefaultsAndBindsEverySuppliedValue() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: makeSelection(),
            details: WorkspaceDatabaseObjectDetails(
                columns: [
                    makeColumn(name: "id", extra: "auto_increment"),
                    makeColumn(name: "display`name"),
                    makeColumn(name: "nickname", isNullable: true),
                ],
                ddl: ""
            )
        )
        let insert = request.makeInsert(
            drafts: [
                "id": .init(mode: .useDefault, text: ""),
                "display`name": .init(mode: .value, text: "O'Brien"),
                "nickname": .init(mode: .null, text: "ignored"),
            ]
        )

        let statement = try MySQLWorkspaceDataRowInsertStatement.make(
            insert: insert
        )

        #expect(
            statement.sql
                == "INSERT INTO `app``db`.`user``data` (`display``name`, `nickname`) VALUES (?, ?)"
        )
        #expect(statement.bindings == [.text("O'Brien"), .null])
        #expect(
            statement.previewSQL
                == """
                INSERT INTO `app``db`.`user``data` (
                    `display``name`,
                    `nickname`
                )
                VALUES (
                    'O''Brien',
                    NULL
                );
                """
        )
    }

    @Test
    func omitsUnsetColumnsAndDefersConstraintsToTheDatabase() throws {
        let selection = makeSelection()
        let defaultRequest = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: selection,
            details: WorkspaceDatabaseObjectDetails(
                columns: [makeColumn(name: "id", extra: "auto_increment")],
                ddl: ""
            )
        )
        let defaultInsert = defaultRequest.makeInsert(drafts: [:])
        let statement = try MySQLWorkspaceDataRowInsertStatement.make(
            insert: defaultInsert
        )
        #expect(statement.sql == "INSERT INTO `app``db`.`user``data` () VALUES ()")
        #expect(statement.bindings.isEmpty)
        #expect(
            statement.previewSQL
                == """
                INSERT INTO `app``db`.`user``data` ()
                VALUES ();
                """
        )

        let requiredRequest = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: selection,
            details: WorkspaceDatabaseObjectDetails(
                columns: [makeColumn(name: "name")],
                ddl: ""
            )
        )
        #expect(requiredRequest.makeInsert(drafts: [:]).values.isEmpty)
        #expect(
            requiredRequest.makeInsert(
                drafts: ["name": .init(mode: .useDefault, text: "")]
            ).values.isEmpty
        )
        #expect(
            requiredRequest.makeInsert(
                drafts: ["name": .init(mode: .null, text: "")]
            ).values == [
                .init(columnName: "name", value: .null),
            ]
        )
    }

    @Test
    func distinguishesEmptyStringsFromDefaultsAndNulls() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: makeSelection(),
            details: WorkspaceDatabaseObjectDetails(
                columns: [
                    makeColumn(name: "name"),
                    makeColumn(
                        name: "updated_at",
                        type: "timestamp",
                        isNullable: true,
                        defaultValue: "CURRENT_TIMESTAMP",
                        extra: "DEFAULT_GENERATED"
                    ),
                ],
                ddl: ""
            )
        )

        let insert = request.makeInsert(
            drafts: [
                "name": .init(mode: .value, text: ""),
                "updated_at": .init(mode: .useDefault, text: ""),
            ]
        )
        #expect(
            insert.values == [
                .init(columnName: "name", value: .text("")),
            ]
        )
        let explicitEmptyInsert = request.makeInsert(
            drafts: [
                "name": .init(mode: .value, text: "Alice"),
                "updated_at": .init(mode: .value, text: ""),
            ]
        )
        let explicitEmptyStatement = try MySQLWorkspaceDataRowInsertStatement
            .make(insert: explicitEmptyInsert)
        #expect(
            explicitEmptyStatement.bindings == [
                .text("Alice"),
                .text(""),
            ]
        )
        #expect(
            explicitEmptyStatement.previewSQL
                == """
                INSERT INTO `app``db`.`user``data` (
                    `name`,
                    `updated_at`
                )
                VALUES (
                    'Alice',
                    ''
                );
                """
        )
    }

    @Test
    func rejectsViews() {
        #expect(throws: WorkspaceDatabaseDataRowInsertError.self) {
            try WorkspaceDatabaseDataRowInsertRequest.make(
                selection: WorkspaceDatabaseObjectSelection(
                    databaseName: "app",
                    objectName: "users_view",
                    kind: .view
                ),
                details: WorkspaceDatabaseObjectDetails(columns: [], ddl: "")
            )
        }
    }

    @Test
    func inlineEditorPreservesDraftValuesUntilDismissed() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: makeSelection(),
            details: WorkspaceDatabaseObjectDetails(
                columns: [
                    makeColumn(name: "id", extra: "auto_increment"),
                    makeColumn(name: "name"),
                    makeColumn(name: "note", isNullable: true),
                ],
                ddl: ""
            )
        )
        var editor = WorkspaceDatabaseDataRowInsertEditorState()
        editor.present(request)
        editor.update(
            columnName: "name",
            draft: .init(mode: .value, text: "Alice")
        )
        editor.update(
            columnName: "note",
            draft: .init(mode: .null, text: "ignored")
        )

        let insert = try editor.makeInsert()
        #expect(
            insert.values == [
                .init(columnName: "name", value: .text("Alice")),
                .init(columnName: "note", value: .null),
            ]
        )
        #expect(editor.isPresented)

        editor.setSubmitting(true)
        #expect(editor.isSubmitting)
        editor.setSubmitting(false)
        #expect(editor.draft(for: "name")?.text == "Alice")

        editor.dismiss()
        #expect(!editor.isPresented)
        #expect(editor.draft(for: "name") == nil)
    }

    @Test
    func includesOnlyColumnsExplicitlyEditedInTheDraftRow() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: makeSelection(),
            details: WorkspaceDatabaseObjectDetails(
                columns: [
                    makeColumn(name: "name"),
                    makeColumn(name: "note", isNullable: true),
                    makeColumn(name: "state", defaultValue: "active"),
                ],
                ddl: ""
            )
        )
        var editor = WorkspaceDatabaseDataRowInsertEditorState()
        editor.present(request)

        #expect(try editor.makeInsert().values.isEmpty)

        editor.update(
            columnName: "name",
            draft: .init(mode: .value, text: "Alice")
        )
        #expect(
            try editor.makeInsert().values == [
                .init(columnName: "name", value: .text("Alice")),
            ]
        )

        editor.update(
            columnName: "note",
            draft: .init(mode: .null, text: "")
        )
        #expect(
            try editor.makeInsert().values == [
                .init(columnName: "name", value: .text("Alice")),
                .init(columnName: "note", value: .null),
            ]
        )
    }

    @Test
    func keepsMultipleDraftRowsIndependentAndIncludesBlankRows() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: makeSelection(),
            details: WorkspaceDatabaseObjectDetails(
                columns: [makeColumn(name: "name")],
                ddl: ""
            )
        )
        var editor = WorkspaceDatabaseDataRowInsertEditorState()
        editor.present(request)
        let firstRowID = try #require(editor.rowID(at: 0))
        editor.update(
            rowID: firstRowID,
            columnName: "name",
            draft: .init(mode: .value, text: "Alice")
        )

        editor.appendRow()
        let secondRowID = try #require(editor.rowID(at: 1))
        #expect(editor.rowCount == 2)
        #expect(editor.draft(rowID: secondRowID, for: "name")?.mode == .unfilled)
        let insertsWithBlankRow = try editor.makeInserts()
        #expect(insertsWithBlankRow.count == 2)
        #expect(insertsWithBlankRow[1].values.isEmpty)

        editor.update(
            rowID: secondRowID,
            columnName: "name",
            draft: .init(mode: .value, text: "Bob")
        )
        #expect(
            try editor.makeInserts().map { $0.values.first?.value }
                == [.text("Alice"), .text("Bob")]
        )

        editor.duplicateRow(id: secondRowID)
        #expect(editor.rowCount == 3)
        #expect(try editor.makeInserts().count == 3)

        editor.removeRow(id: firstRowID)
        #expect(editor.rowCount == 2)
        #expect(editor.draft(rowID: secondRowID, for: "name")?.text == "Bob")
    }

    @MainActor
    @Test
    func restoringBlankRequiredCellDoesNotMarkItEdited() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: makeSelection(),
            details: WorkspaceDatabaseObjectDetails(
                columns: [makeColumn(name: "name")],
                ddl: ""
            )
        )
        var editorState = WorkspaceDatabaseDataRowInsertEditorState()
        editorState.present(request)
        let page = WorkspaceDatabaseDataPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "name")],
            rows: [],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
        var committedDraft: WorkspaceDatabaseDataRowInsertDraft?
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            rowInsertEditor: editorState,
            updateRowInsertDraft: { _, _, draft in committedDraft = draft }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )

        #expect(tableView.singleClickCellHandler?(0, 1) == true)
        let field = try #require(
            tableView.subviews.compactMap { $0 as? NSTextField }.first
        )
        field.stringValue = "temporary"
        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
        field.stringValue = ""
        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
        let fieldEditor = NSTextView()
        _ = coordinator.control(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        )

        #expect(committedDraft == nil)
    }

    @MainActor
    @Test
    func clearingAnExistingValueProducesAnEmptyString() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: makeSelection(),
            details: WorkspaceDatabaseObjectDetails(
                columns: [makeColumn(name: "name")],
                ddl: ""
            )
        )
        var editorState = WorkspaceDatabaseDataRowInsertEditorState()
        editorState.present(request)
        editorState.update(
            columnName: "name",
            draft: .init(mode: .value, text: "Alice")
        )
        let page = WorkspaceDatabaseDataPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "name")],
            rows: [],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
        var committedDraft: WorkspaceDatabaseDataRowInsertDraft?
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            rowInsertEditor: editorState,
            updateRowInsertDraft: { _, _, draft in committedDraft = draft }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )

        #expect(tableView.singleClickCellHandler?(0, 1) == true)
        let field = try #require(
            tableView.subviews.compactMap { $0 as? NSTextField }.first
        )
        let fieldEditor = NSTextView()
        fieldEditor.string = ""
        _ = coordinator.control(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        )

        #expect(committedDraft == .init(mode: .value, text: ""))
    }

    @MainActor
    @Test
    func leavingUntouchedDefaultAndNullCellsDoesNotMarkThemEdited() throws {
        let cases: [(WorkspaceDatabaseColumn, WorkspaceDatabaseDataRowInsertMode)] = [
            (
                makeColumn(
                    name: "updated_at",
                    type: "timestamp",
                    isNullable: true,
                    defaultValue: "CURRENT_TIMESTAMP",
                    extra: "DEFAULT_GENERATED"
                ),
                .useDefault
            ),
            (makeColumn(name: "note", isNullable: true), .null),
        ]

        for (column, expectedMode) in cases {
            let request = try WorkspaceDatabaseDataRowInsertRequest.make(
                selection: makeSelection(),
                details: WorkspaceDatabaseObjectDetails(
                    columns: [column],
                    ddl: ""
                )
            )
            var editorState = WorkspaceDatabaseDataRowInsertEditorState()
            editorState.present(request)
            let page = WorkspaceDatabaseDataPage(
                columns: [
                    WorkspaceDatabaseDataColumn(id: 0, name: column.name),
                ],
                rows: [],
                offset: 0,
                limit: 200,
                hasNextPage: false
            )
            var committedDraft: WorkspaceDatabaseDataRowInsertDraft?
            let coordinator = WorkspaceDatabaseDataTableCoordinator(
                page: page,
                isFetching: false,
                sortData: { _ in },
                rowInsertEditor: editorState,
                updateRowInsertDraft: { _, _, draft in committedDraft = draft }
            )
            let tableView = try #require(
                coordinator.makeScrollView().documentView
                    as? WorkspaceDirectDrawTableView
            )

            #expect(tableView.singleClickCellHandler?(0, 1) == true)
            let field = try #require(
                tableView.subviews.compactMap { $0 as? NSTextField }.first
            )
            let fieldEditor = NSTextView()
            _ = coordinator.control(
                field,
                textView: fieldEditor,
                doCommandBy: #selector(NSResponder.insertTab(_:))
            )

            #expect(editorState.draft(for: column.name)?.mode == expectedMode)
            #expect(committedDraft == nil)
        }
    }

    @MainActor
    @Test
    func inlineGridEditorCommitsTheLiveFieldValueBeforeMoving() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: makeSelection(),
            details: WorkspaceDatabaseObjectDetails(
                columns: [makeColumn(name: "name")],
                ddl: ""
            )
        )
        var editorState = WorkspaceDatabaseDataRowInsertEditorState()
        editorState.present(request)
        let page = WorkspaceDatabaseDataPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "name")],
            rows: [],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
        var committedDraft: WorkspaceDatabaseDataRowInsertDraft?
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            rowInsertEditor: editorState,
            updateRowInsertDraft: { _, _, draft in
                committedDraft = draft
            }
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        scrollView.layoutSubtreeIfNeeded()
        let draftRowView = try #require(
            tableView.rowView(atRow: 0, makeIfNecessary: true)
                as? WorkspaceDatabaseDataRowView
        )

        #expect(tableView.singleClickCellHandler?(0, 1) == true)
        #expect(tableView.selectedRowIndexes == IndexSet(integer: 0))
        let field = try #require(
            tableView.subviews.compactMap { $0 as? NSTextField }.first
        )
        let fieldEditor = NSTextView()
        fieldEditor.string = "Alice"
        _ = coordinator.control(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        )

        #expect(committedDraft == .init(mode: .value, text: "Alice"))
        #expect(draftRowView.accessibilityValue() as? String == "Alice")
    }

    @MainActor
    @Test
    func discardingDraftWhileEditingRemovesTheNativeInlineEditor() throws {
        let request = try WorkspaceDatabaseDataRowInsertRequest.make(
            selection: makeSelection(),
            details: WorkspaceDatabaseObjectDetails(
                columns: [makeColumn(name: "name")],
                ddl: ""
            )
        )
        var editorState = WorkspaceDatabaseDataRowInsertEditorState()
        editorState.present(request)
        let page = WorkspaceDatabaseDataPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "name")],
            rows: [],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            rowInsertEditor: editorState
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        scrollView.layoutSubtreeIfNeeded()

        #expect(tableView.singleClickCellHandler?(0, 1) == true)
        #expect(tableView.subviews.contains { $0 is NSTextField })

        editorState.dismiss()
        coordinator.update(
            page: page,
            isFetching: false,
            sortData: { _ in },
            rowInsertEditor: editorState
        )

        #expect(!tableView.subviews.contains { $0 is NSTextField })
        #expect(tableView.numberOfRows == 0)
    }

    private func makeSelection() -> WorkspaceDatabaseObjectSelection {
        WorkspaceDatabaseObjectSelection(
            databaseName: "app`db",
            objectName: "user`data",
            kind: .table
        )
    }

    private func makeColumn(
        name: String,
        type: String = "varchar(255)",
        isNullable: Bool = false,
        defaultValue: String? = nil,
        extra: String = ""
    ) -> WorkspaceDatabaseColumn {
        WorkspaceDatabaseColumn(
            name: name,
            type: type,
            collation: nil,
            isNullable: isNullable,
            key: "",
            defaultValue: defaultValue,
            extra: extra,
            comment: ""
        )
    }
}
