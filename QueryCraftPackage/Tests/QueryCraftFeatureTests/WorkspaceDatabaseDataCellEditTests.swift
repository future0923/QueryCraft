import Testing
@testable import QueryCraftFeature

struct WorkspaceDatabaseDataCellEditTests {
    @Test
    func preparesCompositePrimaryKeyUpdateFromLoadedRow() throws {
        let selection = makeSelection()
        let target = WorkspaceDatabaseDataCellEditTarget(
            rowIndex: 4,
            dataColumnIndex: 2,
            columns: dataColumns,
            row: WorkspaceDatabaseDataRow(
                id: 4,
                values: [.text("7"), .text("42"), .text("before")]
            )
        )
        let request = try WorkspaceDatabaseDataCellEditRequest.make(
            selection: selection,
            target: target,
            details: WorkspaceDatabaseObjectDetails(
                columns: [
                    makeColumn(name: "tenant_id", key: "PRI"),
                    makeColumn(name: "id", key: "PRI"),
                    makeColumn(name: "name", isNullable: true),
                ],
                ddl: ""
            )
        )

        #expect(request.column.name == "name")
        #expect(
            request.primaryKey == [
                WorkspaceDatabaseDataCellUpdateCondition(
                    columnName: "tenant_id",
                    value: .text("7")
                ),
                WorkspaceDatabaseDataCellUpdateCondition(
                    columnName: "id",
                    value: .text("42")
                ),
            ]
        )
        let update = try request.makeUpdate(text: "after", usesNull: false)
        #expect(update.originalValue == .text("before"))
        #expect(update.newValue == .text("after"))
    }

    @Test
    func buildsBoundUpdateUsingOnlyPrimaryKeyPredicate() throws {
        let update = WorkspaceDatabaseDataCellUpdate(
            selection: WorkspaceDatabaseObjectSelection(
                databaseName: "app`db",
                objectName: "user`data",
                kind: .table
            ),
            columnName: "display`name",
            originalValue: .text("before"),
            newValue: .text("after' value"),
            primaryKey: [
                WorkspaceDatabaseDataCellUpdateCondition(
                    columnName: "id",
                    value: .text("42")
                )
            ]
        )

        let statement = try MySQLWorkspaceDataCellUpdateStatement.make(
            update: update
        )

        #expect(
            statement.sql
                == "UPDATE `app``db`.`user``data` SET `display``name` = ? WHERE `id` = ?"
        )
        #expect(
            statement.bindings == [
                .text("after' value"),
                .text("42"),
            ]
        )
    }

    @Test
    func rejectsTablesWithoutPrimaryKeys() {
        expectPreparationError(.primaryKeyRequired) {
            try WorkspaceDatabaseDataCellEditRequest.make(
                selection: makeSelection(),
                target: makeTarget(),
                details: WorkspaceDatabaseObjectDetails(
                    columns: [makeColumn(name: "name")],
                    ddl: ""
                )
            )
        }
    }

    @Test
    func rejectsViewsAndGeneratedColumns() {
        expectPreparationError(.tableRequired) {
            try WorkspaceDatabaseDataCellEditRequest.make(
                selection: WorkspaceDatabaseObjectSelection(
                    databaseName: "app",
                    objectName: "users_view",
                    kind: .view
                ),
                target: makeTarget(),
                details: makeDetails()
            )
        }
        expectPreparationError(.generatedColumn) {
            try WorkspaceDatabaseDataCellEditRequest.make(
                selection: makeSelection(),
                target: makeTarget(),
                details: WorkspaceDatabaseObjectDetails(
                    columns: [
                        makeColumn(name: "id", key: "PRI"),
                        makeColumn(
                            name: "name",
                            extra: "VIRTUAL GENERATED"
                        ),
                    ],
                    ddl: ""
                )
            )
        }
    }

    @Test
    func rejectsUnavailableBinaryValues() {
        let target = WorkspaceDatabaseDataCellEditTarget(
            rowIndex: 0,
            dataColumnIndex: 2,
            columns: dataColumns,
            row: WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("7"), .text("42"), .binary(byteCount: 16)]
            )
        )
        expectPreparationError(.binaryValueUnavailable) {
            try WorkspaceDatabaseDataCellEditRequest.make(
                selection: makeSelection(),
                target: target,
                details: makeDetails()
            )
        }
    }

    @Test
    func rejectsNullForNonNullableColumnAndUnchangedValue() throws {
        let request = try WorkspaceDatabaseDataCellEditRequest.make(
            selection: makeSelection(),
            target: makeTarget(),
            details: makeDetails()
        )

        #expect(throws: WorkspaceDatabaseDataCellEditError.self) {
            try request.makeUpdate(text: "", usesNull: true)
        }
        #expect(throws: WorkspaceDatabaseDataCellEditError.self) {
            try request.makeUpdate(text: "before", usesNull: false)
        }
    }

    private var dataColumns: [WorkspaceDatabaseDataColumn] {
        [
            WorkspaceDatabaseDataColumn(id: 0, name: "tenant_id"),
            WorkspaceDatabaseDataColumn(id: 1, name: "id"),
            WorkspaceDatabaseDataColumn(id: 2, name: "name"),
        ]
    }

    private func makeSelection() -> WorkspaceDatabaseObjectSelection {
        WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
    }

    private func makeTarget() -> WorkspaceDatabaseDataCellEditTarget {
        WorkspaceDatabaseDataCellEditTarget(
            rowIndex: 0,
            dataColumnIndex: 2,
            columns: dataColumns,
            row: WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("7"), .text("42"), .text("before")]
            )
        )
    }

    private func makeDetails() -> WorkspaceDatabaseObjectDetails {
        WorkspaceDatabaseObjectDetails(
            columns: [
                makeColumn(name: "tenant_id", key: "PRI"),
                makeColumn(name: "id", key: "PRI"),
                makeColumn(name: "name"),
            ],
            ddl: ""
        )
    }

    private func makeColumn(
        name: String,
        key: String = "",
        isNullable: Bool = false,
        extra: String = ""
    ) -> WorkspaceDatabaseColumn {
        WorkspaceDatabaseColumn(
            name: name,
            type: "varchar(255)",
            collation: nil,
            isNullable: isNullable,
            key: key,
            defaultValue: nil,
            extra: extra,
            comment: ""
        )
    }

    private func expectPreparationError(
        _ expected: WorkspaceDatabaseDataCellEditError,
        operation: () throws -> WorkspaceDatabaseDataCellEditRequest
    ) {
        do {
            _ = try operation()
            Issue.record("Expected \(expected)")
        } catch let error as WorkspaceDatabaseDataCellEditError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
