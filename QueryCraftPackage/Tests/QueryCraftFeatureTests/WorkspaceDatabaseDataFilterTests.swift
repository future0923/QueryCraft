import AppKit
import Testing
@testable import QueryCraftFeature

struct WorkspaceDatabaseDataFilterTests {
    @Test
    func classifiesMySQLColumnTypesAndOffersTypedOperators() {
        #expect(WorkspaceDatabaseDataFilterColumnKind(mysqlType: "varchar(255)") == .text)
        #expect(WorkspaceDatabaseDataFilterColumnKind(mysqlType: "BIGINT UNSIGNED") == .number)
        #expect(WorkspaceDatabaseDataFilterColumnKind(mysqlType: "datetime(6)") == .date)
        #expect(
            WorkspaceDatabaseDataFilterColumnKind(mysqlType: "enum('new','done')")
                == .enumeration
        )
        #expect(WorkspaceDatabaseDataFilterColumnKind(mysqlType: "tinyint(1)") == .boolean)
        #expect(WorkspaceDatabaseDataFilterColumnKind(mysqlType: "longblob") == .binary)
        #expect(WorkspaceDatabaseDataFilterColumnKind(mysqlType: "bytea") == .binary)
        #expect(WorkspaceDatabaseDataFilterColumnKind(mysqlType: "bigserial") == .number)

        #expect(
            WorkspaceDatabaseDataFilterOperator.available(for: .text)
                .contains(.contains)
        )
        #expect(
            WorkspaceDatabaseDataFilterOperator.available(for: .number)
                .contains(.between)
        )
        #expect(
            !WorkspaceDatabaseDataFilterOperator.available(for: .binary)
                .contains(.contains)
        )
    }

    @Test
    func offersMappingSpecificElasticsearchOperators() throws {
        let keyword = try #require(
            WorkspaceDatabaseDataFilterColumnKind(
                elasticsearchType: "keyword",
                hasKeywordSubfield: false
            )
        )
        let text = try #require(
            WorkspaceDatabaseDataFilterColumnKind(
                elasticsearchType: "text",
                hasKeywordSubfield: false
            )
        )
        let textWithKeyword = try #require(
            WorkspaceDatabaseDataFilterColumnKind(
                elasticsearchType: "text",
                hasKeywordSubfield: true
            )
        )

        #expect(
            WorkspaceDatabaseDataFilterOperator.available(for: keyword)
                == [.term, .terms, .wildcard, .exists]
        )
        #expect(
            WorkspaceDatabaseDataFilterOperator.available(for: text)
                == [
                    .match, .matchPhrase, .term, .wildcard, .exists,
                ]
        )
        let combined = WorkspaceDatabaseDataFilterOperator.available(
            for: textWithKeyword
        )
        #expect(combined.contains(.match))
        #expect(combined.contains(.term))
        #expect(combined.contains(.wildcard))
        #expect(!combined.contains(.terms))
        #expect(
            WorkspaceDatabaseDataFilterOperator.available(
                for: .elasticsearchNumber
            ) == [
                .term, .terms, .rangeGreaterThan,
                .rangeGreaterThanOrEqual, .rangeLessThan,
                .rangeLessThanOrEqual, .exists,
            ]
        )
        #expect(
            WorkspaceDatabaseDataFilterOperator.available(
                for: .elasticsearchBoolean
            ) == [.term, .exists]
        )
        #expect(
            WorkspaceDatabaseDataFilterColumnKind(
                elasticsearchType: "ip",
                hasKeywordSubfield: false
            ) == .elasticsearchIP
        )
        #expect(
            WorkspaceDatabaseDataFilterColumnKind(
                elasticsearchType: "object",
                hasKeywordSubfield: false
            ) == nil
        )
    }

    @Test
    func defaultsElasticsearchConditionsToTheFilterClause() {
        let condition = WorkspaceDatabaseDataFilterCondition(
            columnName: "status",
            columnKind: .elasticsearchKeyword,
            operation: .term,
            value: "open"
        )

        #expect(condition.elasticsearchClause == .filter)
    }

    @Test
    func validatesElasticsearchTermsAndExistsValues() {
        for value in ["open, closed", #"["open", "closed"]"#] {
            #expect(
                WorkspaceDatabaseDataFilterCondition(
                    columnName: "status",
                    columnKind: .elasticsearchKeyword,
                    operation: .terms,
                    value: value
                ).isValid
            )
        }
        #expect(
            WorkspaceDatabaseDataFilterCondition(
                columnName: "age",
                columnKind: .elasticsearchNumber,
                operation: .terms,
                value: "[18, 30]"
            ).isValid
        )
        for value in [
            "[]", "{}", "[[]]", "[true]", #"["18", {}]"#, "nope, 3",
        ] {
            #expect(
                !WorkspaceDatabaseDataFilterCondition(
                    columnName: "age",
                    columnKind: .elasticsearchNumber,
                    operation: .terms,
                    value: value
                ).isValid
            )
        }
        #expect(
            WorkspaceDatabaseDataFilterCondition(
                columnName: "status",
                columnKind: .elasticsearchKeyword,
                operation: .exists
            ).isValid
        )
    }

    @Test
    func changingElasticsearchFieldsFallsBackAndClearsTheValue() {
        var condition = WorkspaceDatabaseDataFilterCondition(
            isEnabled: false,
            columnName: "message",
            columnKind: .elasticsearchText,
            elasticsearchClause: .mustNot,
            operation: .matchPhrase,
            value: "old value"
        )

        condition.selectElasticsearchField(
            name: "age",
            kind: .elasticsearchNumber
        )

        #expect(condition.columnName == "age")
        #expect(condition.operation == .term)
        #expect(condition.value.isEmpty)
        #expect(condition.isEnabled)
        #expect(condition.elasticsearchClause == .mustNot)
    }

    @Test
    func parsesEnumerationMenuValues() {
        let column = makeColumn(type: "enum('new','in\\'progress','done')")
        #expect(column.dataFilterMenuValues == ["new", "in'progress", "done"])
        #expect(makeColumn(type: "boolean").dataFilterMenuValues == ["0", "1"])
    }

    @Test
    func validatesTheEntireNumericFilterValue() {
        for value in ["0", "-12.50", ".5", "5.", "1e3", "-2.5E-4"] {
            #expect(
                WorkspaceDatabaseDataFilterCondition(
                    columnName: "score",
                    columnKind: .number,
                    operation: .equal,
                    value: value
                ).isValid
            )
        }
        for value in ["", "+", ".", "0 OR true", "12 trailing"] {
            #expect(
                !WorkspaceDatabaseDataFilterCondition(
                    columnName: "score",
                    columnKind: .number,
                    operation: .equal,
                    value: value
                ).isValid
            )
        }
    }

    @Test
    func valueOperatorsMoveFocusToTheFirstValueEditor() {
        let conditionID = UUID()

        #expect(
            WorkspaceDatabaseDataFilterFocus.preferredAfterSelecting(
                .between,
                conditionID: conditionID
            ) == .value(conditionID)
        )
        #expect(
            WorkspaceDatabaseDataFilterFocus.preferredAfterSelecting(
                .isNull,
                conditionID: conditionID
            ) == nil
        )
    }

    @Test @MainActor
    func nativeValueEditorAppliesRequestedFocus() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let textField = WorkspaceDatabaseDataFilterNativeTextField(
            frame: NSRect(x: 20, y: 40, width: 200, height: 24)
        )
        window.contentView?.addSubview(textField)

        textField.requestFocus(1)
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                continuation.resume()
            }
        }

        #expect(textField.currentEditor() != nil)
        #expect(window.firstResponder === textField.currentEditor())
        window.makeFirstResponder(nil)
        textField.removeFromSuperview()
        window.close()
    }

    @Test @MainActor
    func editorInstallsDefaultConditionBeforePresenting() {
        let defaultCondition = makeColumn(type: "varchar(255)")
            .defaultDataFilterCondition
        let editor = WorkspaceDatabaseDataFilterEditor()

        editor.present(
            appliedFilter: .empty,
            defaultCondition: defaultCondition
        )

        #expect(editor.isPresented)
        #expect(editor.draft.conditions == [defaultCondition])
    }

    @Test @MainActor
    func editorPreservesAppliedConditionsWhenPresenting() {
        let appliedCondition = WorkspaceDatabaseDataFilterCondition(
            columnName: "status",
            columnKind: .text,
            operation: .equal,
            value: "active"
        )
        let appliedFilter = WorkspaceDatabaseDataFilter(
            conditions: [appliedCondition]
        )
        let editor = WorkspaceDatabaseDataFilterEditor()

        editor.present(
            appliedFilter: appliedFilter,
            defaultCondition: makeColumn(type: "varchar(255)")
                .defaultDataFilterCondition
        )

        #expect(editor.isPresented)
        #expect(editor.draft == appliedFilter)
    }

    @Test @MainActor
    func editorDoesNotCarryAFilterIntoAnotherObject() {
        let editor = WorkspaceDatabaseDataFilterEditor()
        editor.present(
            appliedFilter: WorkspaceDatabaseDataFilter(conditions: [
                WorkspaceDatabaseDataFilterCondition(
                    columnName: "address",
                    columnKind: .elasticsearchKeyword,
                    operation: .term,
                    value: "Shanghai"
                ),
            ]),
            defaultCondition: nil
        )

        editor.resetForSelectionChange()

        #expect(!editor.isPresented)
        #expect(editor.draft == .empty)
    }

    @Test @MainActor
    func operatorPickerRespectsTheWidthAssignedBySwiftUI() {
        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
        popUpButton.addItems(withTitles: [
            "term",
            "match_phrase",
            "wildcard",
        ])

        WorkspaceDatabaseDataFilterOperatorPicker.configureLayout(popUpButton)

        #expect(
            popUpButton.contentCompressionResistancePriority(
                for: .horizontal
            ) == .defaultLow
        )
        #expect(popUpButton.cell?.lineBreakMode == .byTruncatingTail)
    }

    @Test @MainActor
    func elasticsearchClausePickerUsesFlexibleNativePopupLayout() {
        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)

        WorkspaceElasticsearchBoolClausePicker.configureLayout(popUpButton)

        #expect(
            popUpButton.contentCompressionResistancePriority(
                for: .horizontal
            ) == .defaultLow
        )
        #expect(popUpButton.cell?.lineBreakMode == .byTruncatingTail)
    }

    @Test @MainActor
    func shiftCommandFUsesPhysicalKeyWithChineseInputSource() async throws {
        var toggleCount = 0
        let coordinator = WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator(
            actions: nil,
            filterPresentationActions:
                WorkspaceDatabaseDataFilterPresentationActions {
                    toggleCount += 1
                },
            objectDetailTabActions: nil,
            isSuspended: false
        )
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "中",
                charactersIgnoringModifiers: "中",
                isARepeat: false,
                keyCode: 3
            )
        )

        #expect(coordinator.handle(event))
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                continuation.resume()
            }
        }
        #expect(toggleCount == 1)
    }

    @Test
    func inMemoryPagingAndCountUseTheSameFilter() async throws {
        let object = WorkspaceDatabaseObject(name: "users", kind: .table)
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: object.name,
            kind: object.kind
        )
        let columns = [
            WorkspaceDatabaseDataColumn(id: 0, name: "id"),
            WorkspaceDatabaseDataColumn(id: 1, name: "name"),
        ]
        let page = WorkspaceDatabaseDataPage(
            columns: columns,
            rows: [
                WorkspaceDatabaseDataRow(id: 0, values: [.text("1"), .text("Alice")]),
                WorkspaceDatabaseDataRow(id: 1, values: [.text("2"), .text("Bob")]),
                WorkspaceDatabaseDataRow(id: 2, values: [.text("3"), .null]),
                WorkspaceDatabaseDataRow(id: 3, values: [.text("4"), .text("Bobby")]),
            ],
            offset: 0,
            limit: 4,
            hasNextPage: false
        )
        let session = InMemoryWorkspaceSession(
            databases: ["app"],
            objectsByDatabase: ["app": [object]],
            dataByObject: [selection: page]
        )
        try await session.connect()

        let filter = WorkspaceDatabaseDataFilter(
            logic: .matchAny,
            conditions: [
                WorkspaceDatabaseDataFilterCondition(
                    columnName: "name",
                    columnKind: .text,
                    operation: .startsWith,
                    value: "Bob"
                ),
                WorkspaceDatabaseDataFilterCondition(
                    columnName: "name",
                    columnKind: .text,
                    operation: .isNull
                ),
            ]
        )
        let collector = FilteredRowsCollector()
        let result = try await session.fetchDataPage(
            for: object,
            in: "app",
            offset: 0,
            limit: 2,
            sort: .ascending(columnName: "id"),
            filter: filter
        ) { batch in
            await collector.append(batch.rows)
        }
        let count = try await session.fetchDataCount(
            for: object,
            in: "app",
            filter: filter
        )

        #expect(await collector.values == [[.text("2"), .text("Bob")], [.text("3"), .null]])
        #expect(result.hasNextPage)
        #expect(count == 3)
    }

    @Test
    func allRowsExportSourceUsesTheAppliedFilter() async throws {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "events",
            kind: .table
        )
        let page = WorkspaceDatabaseDataPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "status")],
            rows: [
                WorkspaceDatabaseDataRow(id: 0, values: [.text("open")]),
                WorkspaceDatabaseDataRow(id: 1, values: [.text("closed")]),
                WorkspaceDatabaseDataRow(id: 2, values: [.text("open")]),
            ],
            offset: 0,
            limit: 3,
            hasNextPage: false
        )
        let source = WorkspaceTableDataExportRowSource(
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app"],
                dataByObject: [selection: page]
            ),
            configuration: DatabaseConnectionConfiguration(
                host: "localhost",
                port: 3306,
                username: "test",
                password: nil,
                database: "app",
                tlsMode: .disabled
            ),
            selection: selection,
            sort: .none,
            filter: WorkspaceDatabaseDataFilter(
                conditions: [
                    WorkspaceDatabaseDataFilterCondition(
                        columnName: "status",
                        columnKind: .enumeration,
                        operation: .equal,
                        value: "open"
                    )
                ]
            )
        )

        #expect(try await source.nextBatch()?.map(\.values) == [[.text("open")], [.text("open")]])
        #expect(try await source.nextBatch() == nil)
        await source.finish()
    }

    private func makeColumn(type: String) -> WorkspaceDatabaseColumn {
        WorkspaceDatabaseColumn(
            name: "value",
            type: type,
            collation: nil,
            isNullable: true,
            key: "",
            defaultValue: nil,
            extra: "",
            comment: ""
        )
    }
}

private actor FilteredRowsCollector {
    private var rows: [WorkspaceDatabaseDataRow] = []

    var values: [[WorkspaceDatabaseDataCell]] {
        rows.map(\.values)
    }

    func append(_ newRows: [WorkspaceDatabaseDataRow]) {
        rows.append(contentsOf: newRows)
    }
}
