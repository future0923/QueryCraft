import AppKit
import Testing

@testable import QueryCraftFeature

struct WorkspaceDatabaseDataChangeSetTests {
    @Test
    func deleteRequestUsesOnlyCompositePrimaryKeyColumns() throws {
        let selection = makeSelection(objectName: "users")
        let page = WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "tenant_id"),
                WorkspaceDatabaseDataColumn(id: 1, name: "id"),
                WorkspaceDatabaseDataColumn(id: 2, name: "name"),
            ],
            rows: [
                WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [.text("7"), .text("42"), .text("before")]
                ),
            ],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
        let details = WorkspaceDatabaseObjectDetails(
            columns: [
                makeColumn(name: "tenant_id", key: "PRI"),
                makeColumn(name: "id", key: "PRI"),
                makeColumn(name: "name"),
            ],
            ddl: ""
        )

        let delete = try WorkspaceDatabaseDataRowDeleteRequest.make(
            selection: selection,
            rowIndex: 0,
            page: page,
            details: details
        )

        #expect(delete.conditions == [
            .init(columnName: "tenant_id", value: .text("7")),
            .init(columnName: "id", value: .text("42")),
        ])
        let statement = try MySQLWorkspaceDataRowDeleteStatement.make(
            delete: delete
        )
        #expect(
            statement.sql
                == "DELETE FROM `querycraft_test`.`users` WHERE `tenant_id` = ? AND `id` = ? LIMIT 1"
        )
        #expect(statement.bindings == [.text("7"), .text("42")])
    }

    @Test
    func requiresEveryPendingChangeToTargetTheSameTable() {
        let users = makeSelection(objectName: "users")
        let auditLog = makeSelection(objectName: "audit_log")
        let update = makeUpdate(selection: users)
        let insert = WorkspaceDatabaseDataRowInsert(
            selection: users,
            values: [.init(columnName: "name", value: .text("new"))]
        )
        let delete = WorkspaceDatabaseDataRowDelete(
            selection: users,
            conditions: [.init(columnName: "id", value: .text("2"))]
        )

        let consistent = WorkspaceDatabaseDataChangeSet(
            updates: [update],
            inserts: [insert],
            deletes: [delete]
        )
        #expect(consistent.selection == users)
        #expect(consistent.hasConsistentSelection)

        let inconsistent = WorkspaceDatabaseDataChangeSet(
            updates: [update],
            inserts: [
                WorkspaceDatabaseDataRowInsert(
                    selection: auditLog,
                    values: []
                ),
            ],
            deletes: [delete]
        )
        #expect(!inconsistent.hasConsistentSelection)
    }

    @Test
    func pendingDeleteRetainsTheUpdatesItTemporarilyReplaces() {
        let selection = makeSelection(objectName: "users")
        let pendingUpdate = WorkspaceDatabaseInspectorPendingUpdate(
            update: makeUpdate(selection: selection)
        )
        let rowDelete = WorkspaceDatabaseDataRowDelete(
            selection: selection,
            conditions: [
                .init(columnName: "id", value: .text("1")),
                .init(columnName: "name", value: .text("before")),
            ]
        )
        let pendingDelete = WorkspaceDatabaseInspectorPendingDelete(
            rowDelete: rowDelete,
            replacedUpdates: [pendingUpdate]
        )
        let columns = [
            WorkspaceDatabaseDataColumn(id: 0, name: "id"),
            WorkspaceDatabaseDataColumn(id: 1, name: "name"),
        ]
        let originalRow = WorkspaceDatabaseDataRow(
            id: 0,
            values: [.text("1"), .text("before")]
        )
        let otherRow = WorkspaceDatabaseDataRow(
            id: 1,
            values: [.text("2"), .text("before")]
        )

        #expect(pendingDelete.replacedUpdates == [pendingUpdate])
        #expect(pendingDelete.matches(rowDelete))
        #expect(pendingDelete.applies(to: originalRow, columns: columns))
        #expect(!pendingDelete.applies(to: otherRow, columns: columns))
    }

    @Test
    func buildsMixedSQLPreviewInTransactionExecutionOrder() throws {
        let selection = makeSelection(objectName: "users")
        let delete = WorkspaceDatabaseDataRowDelete(
            selection: selection,
            conditions: [.init(columnName: "id", value: .text("2"))]
        )
        let update = makeUpdate(selection: selection)
        let insert = WorkspaceDatabaseDataRowInsert(
            selection: selection,
            values: [.init(columnName: "name", value: .text("new"))]
        )

        let statements = [
            try WorkspaceSQLPreviewStatement.make(rowDelete: delete),
            try WorkspaceSQLPreviewStatement.make(cellUpdate: update),
            try WorkspaceSQLPreviewStatement.make(rowInsert: insert),
        ]

        #expect(statements.map(\.sql) == [
            """
            DELETE FROM `querycraft_test`.`users`
            WHERE `id` = '2'
            LIMIT 1;
            """,
            "UPDATE `querycraft_test`.`users` SET `name` = 'after' WHERE `id` = '1';",
            """
            INSERT INTO `querycraft_test`.`users` (
                `name`
            )
            VALUES (
                'new'
            );
            """,
        ])
    }

    @Test
    func buildsPostgreSQLPreviewWithConventionalPrimaryKeyPredicates() throws {
        let selection = makeSelection(objectName: "public.users")
        let delete = WorkspaceDatabaseDataRowDelete(
            selection: selection,
            conditions: [.init(columnName: "id", value: .text("2"))]
        )
        let update = makeUpdate(selection: selection)
        let insert = WorkspaceDatabaseDataRowInsert(
            selection: selection,
            values: [.init(columnName: "name", value: .text("new"))]
        )

        let statements = [
            try WorkspaceSQLPreviewStatement.make(
                rowDelete: delete,
                databaseType: .postgresql
            ),
            try WorkspaceSQLPreviewStatement.make(
                cellUpdate: update,
                databaseType: .postgresql
            ),
            try WorkspaceSQLPreviewStatement.make(
                rowInsert: insert,
                databaseType: .postgresql
            ),
        ]

        #expect(statements.map(\.sql) == [
            """
            DELETE FROM "public"."users"
            WHERE "id" = '2';
            """,
            """
            UPDATE "public"."users"
            SET "name" = 'after'
            WHERE "id" = '1';
            """,
            """
            INSERT INTO "public"."users" (
                "name"
            )
            VALUES (
                'new'
            );
            """,
        ])
    }

    @Test
    func groupsCellChangesByLoadedRowInStableAssignmentOrder() throws {
        let selection = makeSelection(objectName: "users")
        let primaryKey = [
            WorkspaceDatabaseDataCellUpdateCondition(
                columnName: "tenant_id",
                value: .text("7")
            ),
            WorkspaceDatabaseDataCellUpdateCondition(
                columnName: "id",
                value: .text("42")
            ),
        ]
        let nameUpdate = WorkspaceDatabaseDataCellUpdate(
            selection: selection,
            columnName: "name",
            originalValue: .text("before"),
            newValue: .text("after"),
            primaryKey: primaryKey
        )
        let noteUpdate = WorkspaceDatabaseDataCellUpdate(
            selection: selection,
            columnName: "note",
            originalValue: .null,
            newValue: .text("memo"),
            primaryKey: primaryKey
        )
        let replacementNameUpdate = WorkspaceDatabaseDataCellUpdate(
            selection: selection,
            columnName: "name",
            originalValue: .text("before"),
            newValue: .text("final"),
            primaryKey: primaryKey
        )
        let otherRowUpdate = WorkspaceDatabaseDataCellUpdate(
            selection: selection,
            columnName: "name",
            originalValue: .text("other"),
            newValue: .text("changed"),
            primaryKey: [
                .init(columnName: "tenant_id", value: .text("7")),
                .init(columnName: "id", value: .text("43")),
            ]
        )
        let changes = WorkspaceDatabaseDataChangeSet(
            updates: [
                nameUpdate,
                noteUpdate,
                replacementNameUpdate,
                otherRowUpdate,
            ],
            inserts: [],
            deletes: []
        )

        #expect(changes.rowUpdates.count == 2)
        #expect(
            changes.rowUpdates[0].assignments.map(\.columnName)
                == ["name", "note"]
        )
        #expect(
            changes.rowUpdates[0].assignments.map(\.newValue)
                == [.text("final"), .text("memo")]
        )
        #expect(changes.rowUpdates[1].assignments == [otherRowUpdate])
    }

    @Test
    func buildsOneUpdateStatementForEveryChangedRow() throws {
        let selection = makeSelection(objectName: "users")
        let primaryKey = [
            WorkspaceDatabaseDataCellUpdateCondition(
                columnName: "id",
                value: .text("42")
            ),
        ]
        let changes = WorkspaceDatabaseDataChangeSet(
            updates: [
                WorkspaceDatabaseDataCellUpdate(
                    selection: selection,
                    columnName: "name",
                    originalValue: .text("before"),
                    newValue: .text("after"),
                    primaryKey: primaryKey
                ),
                WorkspaceDatabaseDataCellUpdate(
                    selection: selection,
                    columnName: "note",
                    originalValue: .text("old"),
                    newValue: .text("ignored for DEFAULT"),
                    primaryKey: primaryKey,
                    assignment: .useDefault
                ),
            ],
            inserts: [],
            deletes: []
        )
        let rowUpdate = try #require(changes.rowUpdates.first)
        let statement = try MySQLWorkspaceDataCellUpdateStatement.make(
            rowUpdate: rowUpdate
        )
        let preview = try WorkspaceSQLPreviewStatement.make(
            rowUpdate: rowUpdate
        )

        #expect(
            statement.sql
                == "UPDATE `querycraft_test`.`users` SET `name` = ?, `note` = DEFAULT WHERE `id` = ?"
        )
        #expect(statement.bindings == [.text("after"), .text("42")])
        #expect(
            preview.sql
                == "UPDATE `querycraft_test`.`users` SET `name` = 'after', `note` = DEFAULT WHERE `id` = '42';"
        )
    }

    @MainActor
    @Test
    func deleteKeyForwardsEveryNoncontiguousSelectedRow() throws {
        let page = WorkspaceDatabaseDataPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "id")],
            rows: [
                WorkspaceDatabaseDataRow(id: 0, values: [.text("1")]),
                WorkspaceDatabaseDataRow(id: 1, values: [.text("2")]),
                WorkspaceDatabaseDataRow(id: 2, values: [.text("3")]),
            ],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
        var deletedRows = IndexSet()
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            deleteRows: { deletedRows = $0 }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        let selectedRows = IndexSet([0, 2])
        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        let deleteEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: String(UnicodeScalar(0x7f)),
                charactersIgnoringModifiers: String(UnicodeScalar(0x7f)),
                isARepeat: false,
                keyCode: 51
            )
        )

        tableView.keyDown(with: deleteEvent)

        #expect(tableView.selectedDataRowIndexesForActions == selectedRows)
        #expect(deletedRows == selectedRows)
    }

    @MainActor
    @Test
    func loadedCellMenuUsesColumnCapabilitiesAndStagesMutations() throws {
        let page = WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "id"),
                WorkspaceDatabaseDataColumn(id: 1, name: "name"),
            ],
            rows: [
                WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [.text("1"), .text("before")]
                ),
            ],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
        var stagedMutations: [WorkspaceDatabaseInspectorMutation] = []
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            prepareCellEdit: { target in
                WorkspaceDatabaseDataCellInlineEditContext(
                    rowIndex: target.rowIndex,
                    dataColumnIndex: target.dataColumnIndex,
                    columnName: target.column?.name ?? "",
                    initialText: "before",
                    initialMutation: .value("before")
                )
            },
            updateCellEdit: { _, mutation in
                stagedMutations.append(mutation)
            },
            databaseColumns: [
                makeColumn(name: "id", key: "PRI"),
                WorkspaceDatabaseColumn(
                    name: "name",
                    type: "varchar(255)",
                    collation: nil,
                    isNullable: true,
                    key: "",
                    defaultValue: "guest",
                    extra: "",
                    comment: ""
                ),
            ]
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        let items = try #require(
            tableView.cellValueMutationMenuItemsProvider?(0, 2)
        )

        #expect(items.map(\.title) == [
            AppCopy.current.text("设为 NULL", "Set to NULL"),
            AppCopy.current.text("使用默认值", "Use Default"),
            AppCopy.current.text("设为空字符串", "Set to Empty String"),
        ])
        #expect(items.map(\.isEnabled) == [true, true, true])
        #expect(items.compactMap(\.image).isEmpty)

        let menu = NSMenu()
        items.forEach(menu.addItem)
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 2)
        #expect(stagedMutations == [.null, .useDefault, .value("")])
    }

    @MainActor
    @Test
    func loadedCellMenuDisablesUnsupportedNullAndDefaultMutations() throws {
        let page = WorkspaceDatabaseDataPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "name")],
            rows: [WorkspaceDatabaseDataRow(id: 0, values: [.text("before")])],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            prepareCellEdit: { target in
                WorkspaceDatabaseDataCellInlineEditContext(
                    rowIndex: target.rowIndex,
                    dataColumnIndex: target.dataColumnIndex,
                    columnName: "name",
                    initialText: "before",
                    initialMutation: .value("before")
                )
            },
            databaseColumns: [makeColumn(name: "name")]
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        let items = try #require(
            tableView.cellValueMutationMenuItemsProvider?(0, 1)
        )

        #expect(items.map(\.title) == [
            AppCopy.current.text("设为空字符串", "Set to Empty String"),
        ])
        #expect(items.map(\.isEnabled) == [true])
    }

    private func makeSelection(
        objectName: String
    ) -> WorkspaceDatabaseObjectSelection {
        WorkspaceDatabaseObjectSelection(
            databaseName: "querycraft_test",
            objectName: objectName,
            kind: .table
        )
    }

    private func makeUpdate(
        selection: WorkspaceDatabaseObjectSelection
    ) -> WorkspaceDatabaseDataCellUpdate {
        WorkspaceDatabaseDataCellUpdate(
            selection: selection,
            columnName: "name",
            originalValue: .text("before"),
            newValue: .text("after"),
            primaryKey: [
                .init(columnName: "id", value: .text("1")),
            ]
        )
    }

    private func makeColumn(
        name: String,
        key: String = ""
    ) -> WorkspaceDatabaseColumn {
        WorkspaceDatabaseColumn(
            name: name,
            type: "varchar(255)",
            collation: nil,
            isNullable: false,
            key: key,
            defaultValue: nil,
            extra: "",
            comment: ""
        )
    }
}
