import AppKit
import Testing
@testable import QueryCraftFeature

struct WorkspaceQueryResultEditingTests {
    @MainActor
    @Test
    func queryResultUsesOneTemporaryInlineEditorForEditableCell() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("42"), .text("before"), .text("computed")]
            )
        ])
        let columns = [
            resultColumn(
                id: 0,
                name: "id",
                database: "app",
                table: "users",
                column: "id"
            ),
            resultColumn(
                id: 1,
                name: "name",
                database: "app",
                table: "users",
                column: "name"
            ),
            WorkspaceDatabaseDataColumn(id: 2, name: "computed"),
        ]
        let page = WorkspaceQueryResultPage(
            columns: columns,
            store: store,
            rowCount: 1
        )
        var stagedMutations: [WorkspaceDatabaseInspectorMutation] = []
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: page,
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
            }
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        #expect(tableView.canEditCellHandler?(0, 2) == true)
        tableView.cellEditHandler?(0, 2)
        #expect(
            tableView.subviews.compactMap { $0 as? NSTextField }.filter {
                $0.accessibilityIdentifier() == "dataCellInlineEditor"
            }.count == 1
        )

        let editor = try #require(
            tableView.subviews.compactMap { $0 as? NSTextField }.first {
                $0.accessibilityIdentifier() == "dataCellInlineEditor"
            }
        )
        let editorDelegate = try #require(
            editor.delegate as? WorkspaceDataCellInlineEditor
        )
        editor.stringValue = "3221"
        editorDelegate.controlTextDidEndEditing(
            Notification(
                name: NSControl.textDidEndEditingNotification,
                object: editor
            )
        )
        #expect(
            tableView.subviews.compactMap { $0 as? NSTextField }.contains {
                $0.accessibilityIdentifier() == "dataCellInlineEditor"
            } == false
        )
        #expect(stagedMutations.last == .value("3221"))

        #expect(tableView.canEditCellHandler?(0, 3) == false)
        tableView.cellEditHandler?(0, 3)
        #expect(
            tableView.subviews.compactMap { $0 as? NSTextField }.filter {
                $0.accessibilityIdentifier() == "dataCellInlineEditor"
            }.isEmpty
        )
    }

    @MainActor
    @Test
    func queryResultCellMenuOffersSupportedMutationsCopyRowAndUndo() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("42"), .text("before")]
            )
        ])
        let columns = [
            resultColumn(
                id: 0,
                name: "id",
                database: "app",
                table: "users",
                column: "id"
            ),
            resultColumn(
                id: 1,
                name: "display_name",
                database: "app",
                table: "users",
                column: "name"
            ),
        ]
        let page = WorkspaceQueryResultPage(
            columns: columns,
            store: store,
            rowCount: 1
        )
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let details = WorkspaceDatabaseObjectDetails(
            columns: [
                databaseColumn(name: "id", key: "PRI"),
                databaseColumn(
                    name: "name",
                    isNullable: true,
                    defaultValue: "guest"
                ),
            ],
            ddl: ""
        )
        let idUpdate = WorkspaceDatabaseInspectorPendingUpdate(
            update: WorkspaceDatabaseDataCellUpdate(
                selection: selection,
                columnName: "id",
                originalValue: .text("42"),
                newValue: .text("43"),
                primaryKey: [.init(columnName: "id", value: .text("42"))]
            )
        )
        let nameUpdate = WorkspaceDatabaseInspectorPendingUpdate(
            update: WorkspaceDatabaseDataCellUpdate(
                selection: selection,
                columnName: "name",
                originalValue: .text("before"),
                newValue: .text("after"),
                primaryKey: [.init(columnName: "id", value: .text("42"))]
            )
        )
        var stagedMutations: [WorkspaceDatabaseInspectorMutation] = []
        var discardedUpdates: [WorkspaceDatabaseInspectorPendingUpdate] = []
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: page,
            pendingUpdates: [idUpdate, nameUpdate],
            cellEditRequest: { target in
                try? WorkspaceDatabaseDataCellEditRequest.make(
                    selection: selection,
                    target: target,
                    details: details
                )
            },
            prepareCellEdit: { target in
                WorkspaceDatabaseDataCellInlineEditContext(
                    rowIndex: target.rowIndex,
                    dataColumnIndex: target.dataColumnIndex,
                    columnName: target.column?.sourceColumnName ?? "",
                    initialText: "before",
                    initialMutation: .value("before")
                )
            },
            updateCellEdit: { _, mutation in
                stagedMutations.append(mutation)
            },
            discardPendingUpdates: { updates in
                discardedUpdates = updates
            }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        tableView.copyPasteboard = NSPasteboard(
            name: NSPasteboard.Name(UUID().uuidString)
        )

        let mutationItems = try #require(
            tableView.cellValueMutationMenuItemsProvider?(0, 2)
        )
        #expect(mutationItems.map(\.title) == [
            AppCopy.current.text("设为 NULL", "Set to NULL"),
            AppCopy.current.text("使用默认值", "Use Default"),
            AppCopy.current.text("设为空字符串", "Set to Empty String"),
        ])
        #expect(mutationItems.compactMap(\.image).isEmpty)
        let mutationMenu = NSMenu()
        mutationItems.forEach(mutationMenu.addItem)
        mutationMenu.performActionForItem(at: 0)
        mutationMenu.performActionForItem(at: 1)
        mutationMenu.performActionForItem(at: 2)
        #expect(stagedMutations == [.null, .useDefault, .value("")])

        let additionalItems = try #require(
            tableView.additionalCellContextMenuItemsProvider?(0, 2)
        )
        #expect(additionalItems.filter { !$0.isSeparatorItem }.map(\.title) == [
            AppCopy.current.text("复制行", "Copy Row"),
            AppCopy.current.text("撤销单元格修改", "Undo Cell Change"),
            AppCopy.current.text("撤销此行全部修改", "Undo All Changes in Row"),
        ])
        #expect(additionalItems.compactMap(\.image).isEmpty)

        let additionalMenu = NSMenu()
        additionalItems.forEach(additionalMenu.addItem)
        additionalMenu.performActionForItem(at: 0)
        for _ in 0..<200 {
            if tableView.copyPasteboard.string(forType: .string) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            tableView.copyPasteboard.string(forType: .string)
                == "42\tbefore"
        )
        additionalMenu.performActionForItem(at: 2)
        #expect(discardedUpdates == [nameUpdate])
        additionalMenu.performActionForItem(at: 3)
        #expect(discardedUpdates == [idUpdate, nameUpdate])
    }

    @MainActor
    @Test
    func queryResultEditAvailabilityRequiresResolvedPrimaryKeyValues() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("before"), .text("computed")]
            )
        ])
        let page = WorkspaceQueryResultPage(
            columns: [
                resultColumn(
                    id: 0,
                    name: "display_name",
                    database: "app",
                    table: "users",
                    column: "name"
                ),
                WorkspaceDatabaseDataColumn(id: 1, name: "name"),
            ],
            store: store,
            rowCount: 1
        )
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let details = WorkspaceDatabaseObjectDetails(
            columns: [
                databaseColumn(name: "id", key: "PRI"),
                databaseColumn(name: "name"),
            ],
            ddl: ""
        )
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: page,
            cellEditRequest: { target in
                try? WorkspaceDatabaseDataCellEditRequest.make(
                    selection: selection,
                    target: target,
                    details: details
                )
            },
            prepareCellEdit: { _ in nil }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )

        #expect(tableView.canEditCellHandler?(0, 1) == false)
        let sourceItems = try #require(
            tableView.cellValueMutationMenuItemsProvider?(0, 1)
        )
        #expect(sourceItems.map(\.title) == [
            AppCopy.current.text("设为 NULL", "Set to NULL"),
            AppCopy.current.text("设为空字符串", "Set to Empty String"),
        ])
        #expect(sourceItems.map(\.isEnabled) == [false, false])
        #expect(tableView.canEditCellHandler?(0, 2) == false)
        let computedItems = try #require(
            tableView.cellValueMutationMenuItemsProvider?(0, 2)
        )
        #expect(computedItems.map(\.title) == [
            AppCopy.current.text("设为 NULL", "Set to NULL"),
            AppCopy.current.text("设为空字符串", "Set to Empty String"),
        ])
        #expect(computedItems.map(\.isEnabled) == [false, false])
    }

    @MainActor
    @Test
    func queryPendingUpdateImmediatelyRefreshesVisibleValueAndColor() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("2"), .text("")]
            )
        ])
        let columns = [
            resultColumn(
                id: 0,
                name: "id",
                database: "app",
                table: "users",
                column: "id"
            ),
            resultColumn(
                id: 1,
                name: "display_text",
                database: "app",
                table: "users",
                column: "required_text"
            ),
        ]
        let page = WorkspaceQueryResultPage(
            columns: columns,
            store: store,
            rowCount: 1
        )
        let coordinator = WorkspaceQueryResultTableCoordinator(page: page)
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        scrollView.layoutSubtreeIfNeeded()
        let rowView = try #require(
            tableView.rowView(atRow: 0, makeIfNecessary: true)
                as? WorkspaceDatabaseDataRowView
        )

        let update = WorkspaceDatabaseInspectorPendingUpdate(
            update: WorkspaceDatabaseDataCellUpdate(
                selection: WorkspaceDatabaseObjectSelection(
                    databaseName: "app",
                    objectName: "users",
                    kind: .table
                ),
                columnName: "required_text",
                originalValue: .text(""),
                newValue: .text("3221"),
                primaryKey: [
                    .init(columnName: "id", value: .text("2")),
                ]
            )
        )
        coordinator.update(page: page, pendingUpdates: [update])

        #expect(rowView.accessibilityValue() as? String == "2, 3221")
        #expect(rowView.pendingPresentationBackgroundColor == nil)
        #expect(rowView.pendingUpdateBackgroundColor(at: 0) == nil)
        let background = try #require(
            rowView.pendingUpdateBackgroundColor(at: 1)?.usingColorSpace(
                .deviceRGB
            )
        )
        #expect(background.redComponent > background.greenComponent)
        #expect(background.greenComponent > background.blueComponent)
    }

    @Test
    func resolvesOneBaseTableFromAliasedAndComputedResultColumns() throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        let page = WorkspaceQueryResultPage(
            columns: [
                resultColumn(
                    id: 0,
                    name: "user_id",
                    database: "app",
                    table: "users",
                    column: "id"
                ),
                resultColumn(
                    id: 1,
                    name: "display_name",
                    database: "app",
                    table: "users",
                    column: "name"
                ),
                WorkspaceDatabaseDataColumn(id: 2, name: "computed"),
            ],
            store: store,
            rowCount: 0
        )

        #expect(
            WorkspaceQueryResultEditing.selection(
                for: page,
                currentDatabase: nil
            ) == WorkspaceDatabaseObjectSelection(
                databaseName: "app",
                objectName: "users",
                kind: .table
            )
        )
    }

    @Test
    func rejectsColumnsFromMoreThanOneBaseTable() throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        let page = WorkspaceQueryResultPage(
            columns: [
                resultColumn(
                    id: 0,
                    name: "user_id",
                    database: "app",
                    table: "users",
                    column: "id"
                ),
                resultColumn(
                    id: 1,
                    name: "order_id",
                    database: "app",
                    table: "orders",
                    column: "id"
                ),
            ],
            store: store,
            rowCount: 0
        )

        #expect(
            WorkspaceQueryResultEditing.selection(
                for: page,
                currentDatabase: "app"
            ) == nil
        )
    }

    @Test
    func preparesAliasedResultUpdateWithSourceColumnAndPrimaryKey() throws {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let columns = [
            resultColumn(
                id: 0,
                name: "user_id",
                database: "app",
                table: "users",
                column: "id"
            ),
            resultColumn(
                id: 1,
                name: "display_name",
                database: "app",
                table: "users",
                column: "name"
            ),
        ]
        let request = try WorkspaceDatabaseDataCellEditRequest.make(
            selection: selection,
            target: WorkspaceDatabaseDataCellEditTarget(
                rowIndex: 0,
                dataColumnIndex: 1,
                columns: columns,
                row: WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [.text("42"), .text("before")]
                )
            ),
            details: WorkspaceDatabaseObjectDetails(
                columns: [
                    databaseColumn(name: "id", key: "PRI"),
                    databaseColumn(name: "name"),
                ],
                ddl: ""
            )
        )
        let update = try request.makeUpdate(text: "after", usesNull: false)

        #expect(update.columnName == "name")
        #expect(update.primaryKey == [
            WorkspaceDatabaseDataCellUpdateCondition(
                columnName: "id",
                value: .text("42")
            )
        ])
    }

    @Test
    func stagedRequestCanReturnToOriginalValue() throws {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let request = try WorkspaceDatabaseDataCellEditRequest.make(
            selection: selection,
            target: WorkspaceDatabaseDataCellEditTarget(
                rowIndex: 0,
                dataColumnIndex: 1,
                columns: [
                    WorkspaceDatabaseDataColumn(id: 0, name: "id"),
                    WorkspaceDatabaseDataColumn(id: 1, name: "name"),
                ],
                row: WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [.text("42"), .text("before")]
                )
            ),
            details: WorkspaceDatabaseObjectDetails(
                columns: [
                    databaseColumn(name: "id", key: "PRI"),
                    databaseColumn(name: "name"),
                ],
                ddl: ""
            )
        ).withInitialValue(.text("after"))

        let update = try request.makeUpdate(text: "before", usesNull: false)

        #expect(update.originalValue == .text("before"))
        #expect(update.newValue == .text("before"))
    }

    @Test
    func appliesCommittedValueToResidentResultStore() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("42"), .text("before")]
            )
        ])

        try await store.apply([
            WorkspaceQueryResultCellMutation(
                rowIndex: 0,
                dataColumnIndex: 1,
                value: .text("after")
            )
        ])

        #expect(store.row(at: 0)?.values == [.text("42"), .text("after")])
    }

    @Test
    func appliesCommittedValueToDiskBackedResultStore() async throws {
        let store = try WorkspaceQueryResultStore()
        let rows = (0...50_000).map { index in
            WorkspaceDatabaseDataRow(
                id: index,
                values: [.text(String(index)), .text("before")]
            )
        }
        try await store.append(rows)
        #expect(store.isDiskBacked)

        try await store.apply([
            WorkspaceQueryResultCellMutation(
                rowIndex: 25_600,
                dataColumnIndex: 1,
                value: .text("after")
            )
        ])

        #expect(
            store.row(at: 25_600)?.values
                == [.text("25600"), .text("after")]
        )
    }

    private func resultColumn(
        id: Int,
        name: String,
        database: String,
        table: String,
        column: String
    ) -> WorkspaceDatabaseDataColumn {
        WorkspaceDatabaseDataColumn(
            id: id,
            name: name,
            origin: WorkspaceDatabaseDataColumn.Origin(
                databaseName: database,
                tableName: table,
                columnName: column
            )
        )
    }

    private func databaseColumn(
        name: String,
        key: String = "",
        isNullable: Bool = false,
        defaultValue: String? = nil
    ) -> WorkspaceDatabaseColumn {
        WorkspaceDatabaseColumn(
            name: name,
            type: "varchar(255)",
            collation: nil,
            isNullable: isNullable,
            key: key,
            defaultValue: defaultValue,
            extra: "",
            comment: ""
        )
    }
}
