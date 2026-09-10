import Testing

@testable import QueryCraftFeature
@testable import QueryCraftMySQLDriver

struct WorkspaceDatabaseSchemaChangeTests {
    @Test
    func emptyDefaultOmitsNullableAndDefaultClauses() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let columnID = editor.addColumn()
        var definition = try #require(editor.columns.first?.definition)
        definition.name = "name"
        definition.type = "VARCHAR(255)"
        definition.isNullable = true
        definition.defaultMode = .none
        editor.updateColumn(id: columnID, definition: definition)

        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` ADD COLUMN `name` VARCHAR(255)",
        ])
    }

    @Test
    func nonCharacterTypeClearsCharacterSetAndCollation() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([
            makeColumn(name: "value", type: "varchar(255)"),
        ])
        let columnID = try #require(editor.columns.first?.id)
        var definition = try #require(editor.columns.first?.definition)
        #expect(definition.supportsCharacterSetAndCollation)
        #expect(definition.characterSet == "utf8mb4")
        #expect(definition.collation == "utf8mb4_0900_ai_ci")

        definition.type = "BIGINT UNSIGNED"
        editor.updateColumn(id: columnID, definition: definition)

        let updated = try #require(editor.columns.first?.definition)
        #expect(!updated.supportsCharacterSetAndCollation)
        #expect(updated.characterSet.isEmpty)
        #expect(updated.collation.isEmpty)
        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` MODIFY COLUMN `value` BIGINT UNSIGNED DEFAULT NULL",
        ])

        definition = updated
        definition.type = "ENUM('one','two')"
        editor.updateColumn(id: columnID, definition: definition)
        #expect(
            try #require(editor.columns.first?.definition)
                .supportsCharacterSetAndCollation
        )
    }

    @Test
    func primaryKeyNormalizesAndLocksOutNullSemantics() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let columnID = editor.addColumn()
        var definition = try #require(editor.columns.first?.definition)
        definition.name = "id"
        #expect(definition.isNullable)
        #expect(definition.defaultMode == .null)

        editor.setPrimaryKey(columnID: columnID, isEnabled: true)

        definition = try #require(editor.columns.first?.definition)
        #expect(!definition.isNullable)
        #expect(definition.defaultMode == .none)

        definition.isNullable = true
        definition.defaultMode = .null
        editor.updateColumn(id: columnID, definition: definition)

        let normalized = try #require(editor.columns.first?.definition)
        #expect(!normalized.isNullable)
        #expect(normalized.defaultMode == .none)
        #expect(
            WorkspaceDatabaseSchemaChoiceCatalog.defaultPresets(
                allowsNull: false
            ).contains {
                $0.value
                    == WorkspaceDatabaseSchemaEditorState.DefaultPreset.null
                        .rawValue
            } == false
        )
    }

    @Test
    func explicitlyMarkedPrimaryIndexDoesNotRequireMySQLIndexName() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([
            makeColumn(name: "id", type: "integer"),
        ])
        editor.loadIndexesIfNeeded([
            WorkspaceDatabaseIndex(
                name: "driver_probe_pkey",
                columns: [
                    WorkspaceDatabaseIndexColumn(
                        sequence: 1,
                        name: "id",
                        prefixLength: nil,
                        direction: "A",
                        isExpression: false
                    ),
                ],
                isUnique: true,
                isPrimary: true,
                type: "BTREE",
                cardinality: nil,
                isVisible: true,
                comment: ""
            ),
        ])

        let columnID = try #require(editor.columns.first?.id)
        #expect(editor.isPrimaryKey(columnID: columnID))
        #expect(editor.indexes.first?.definition.kind == .primary)
    }

    @Test
    func unchangedMetadataProducesNoDDL() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([makeColumn(name: "id", type: "int")])
        editor.loadIndexesIfNeeded([makePrimaryIndex()])

        let statements = MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        )

        #expect(statements.isEmpty)
        #expect(!editor.hasChanges)
    }

    @Test
    func buildsOneFormattedAlterStatementForEditedTableOptions() {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let original = WorkspaceDatabaseTableOptions(
            engine: "InnoDB",
            characterSet: "utf8mb4",
            collation: "utf8mb4_0900_ai_ci",
            rowFormat: "DYNAMIC",
            autoIncrement: "100",
            comment: "legacy",
            averageRowLength: "128",
            minimumRows: "10",
            maximumRows: "100000",
            keyBlockSize: "8"
        )
        editor.loadTableOptionsIfNeeded(original)
        editor.tableOptions.engine = "MyISAM"
        editor.tableOptions.characterSet = "latin1"
        editor.tableOptions.collation = "latin1_swedish_ci"
        editor.tableOptions.rowFormat = "COMPACT"
        editor.tableOptions.autoIncrement = ""
        editor.tableOptions.comment = ""
        editor.tableOptions.averageRowLength = ""
        editor.tableOptions.minimumRows = ""
        editor.tableOptions.maximumRows = ""
        editor.tableOptions.keyBlockSize = ""

        let changeSet = WorkspaceDatabaseSchemaChangeSet(
            selection: WorkspaceDatabaseObjectSelection(
                databaseName: "querycraft_test",
                objectName: "users",
                kind: .table
            ),
            columns: editor.columns,
            indexes: editor.indexes,
            tableOptionsChange: editor.tableOptionsChange
        )
        let statement = MySQLWorkspaceSchemaStatement.make(
            changes: changeSet
        ).first

        #expect(
            statement?.sql
                == "ALTER TABLE `querycraft_test`.`users` ENGINE=MyISAM, DEFAULT CHARACTER SET=latin1, COLLATE=latin1_swedish_ci, ROW_FORMAT=COMPACT, AUTO_INCREMENT=1, COMMENT='', AVG_ROW_LENGTH=0, MIN_ROWS=0, MAX_ROWS=0, KEY_BLOCK_SIZE=0"
        )
        #expect(
            statement?.previewTokens.map(\.text).joined()
                == """
                ALTER TABLE `querycraft_test`.`users`
                    ENGINE=MyISAM,
                    DEFAULT CHARACTER SET=latin1,
                    COLLATE=latin1_swedish_ci,
                    ROW_FORMAT=COMPACT,
                    AUTO_INCREMENT=1,
                    COMMENT='',
                    AVG_ROW_LENGTH=0,
                    MIN_ROWS=0,
                    MAX_ROWS=0,
                    KEY_BLOCK_SIZE=0;
                """
        )

        editor.discardChanges()
        #expect(editor.tableOptions == original)
        #expect(!editor.hasChanges)
    }

    @Test
    func buildsColumnAddRenameAndDeleteStatements() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([
            makeColumn(name: "legacy", type: "varchar(20)"),
            makeColumn(name: "obsolete", type: "int"),
        ])

        let legacyID = try #require(editor.columns.first?.id)
        var renamed = try #require(editor.columns.first?.definition)
        renamed.name = "display_name"
        renamed.type = "varchar(80)"
        renamed.isNullable = false
        renamed.defaultMode = .value
        renamed.defaultValue = "guest"
        editor.updateColumn(id: legacyID, definition: renamed)

        let obsoleteID = try #require(editor.columns.last?.id)
        editor.deleteColumn(id: obsoleteID)

        let scoreID = editor.addColumn()
        var score = try #require(
            editor.columns.first(where: { $0.id == scoreID })?.definition
        )
        score.name = "score"
        score.type = "BIGINT"
        score.isNullable = false
        score.defaultMode = .value
        score.defaultValue = "0"
        editor.updateColumn(id: scoreID, definition: score)

        let statements = MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        )

        #expect(statements.map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` DROP COLUMN `obsolete`",
            "ALTER TABLE `querycraft_test`.`users` CHANGE COLUMN `legacy` `display_name` varchar(80) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci NOT NULL DEFAULT 'guest'",
            "ALTER TABLE `querycraft_test`.`users` ADD COLUMN `score` BIGINT NOT NULL DEFAULT 0",
        ])
    }

    @Test
    func schemaPreviewPreservesSQLAndUsesSemanticTokenKinds() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let scoreID = editor.addColumn()
        var score = try #require(
            editor.columns.first(where: { $0.id == scoreID })?.definition
        )
        score.name = "score"
        score.type = "BIGINT"
        score.isNullable = false
        score.defaultMode = .value
        score.defaultValue = "0"
        score.comment = "ranking"
        editor.updateColumn(id: scoreID, definition: score)

        let statement = try #require(
            MySQLWorkspaceSchemaStatement.make(
                changes: changeSet(editor)
            ).first
        )

        #expect(
            statement.previewTokens.map(\.text).joined()
                == """
                ALTER TABLE `querycraft_test`.`users`
                    ADD COLUMN `score` BIGINT NOT NULL DEFAULT 0 COMMENT 'ranking';
                """
        )
        #expect(statement.previewTokens.contains {
            $0.kind == .keyword && $0.text == "ALTER TABLE"
        })
        #expect(statement.previewTokens.contains {
            $0.kind == .identifier && $0.text == "`score`"
        })
        #expect(statement.previewTokens.contains {
            $0.kind == .numericLiteral && $0.text == "0"
        })
        #expect(statement.previewTokens.contains {
            $0.kind == .stringLiteral && $0.text == "'ranking'"
        })
    }

    @Test
    func indexEditDropsOldDefinitionBeforeAddingNewDefinition() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([
            makeColumn(name: "email", type: "varchar(255)"),
        ])
        editor.loadIndexesIfNeeded([
            WorkspaceDatabaseIndex(
                name: "idx_email",
                columns: [
                    WorkspaceDatabaseIndexColumn(
                        sequence: 1,
                        name: "email",
                        prefixLength: nil,
                        direction: "A",
                        isExpression: false
                    ),
                ],
                isUnique: false,
                type: "BTREE",
                cardinality: 3,
                isVisible: true,
                comment: ""
            ),
        ])
        let indexID = try #require(editor.indexes.first?.id)
        var definition = try #require(editor.indexes.first?.definition)
        definition.kind = .unique
        definition.columns[0].prefixLength = "120"
        definition.columns[0].isDescending = true
        definition.comment = "login lookup"
        editor.updateIndex(id: indexID, definition: definition)

        let statements = MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        )

        #expect(statements.map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` DROP INDEX `idx_email`",
            "ALTER TABLE `querycraft_test`.`users` ADD UNIQUE INDEX `idx_email` (`email`(120) DESC) USING BTREE COMMENT 'login lookup'",
        ])
    }

    @Test
    func addingThenDeletingDraftCancelsTheChange() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let columnID = editor.addColumn()
        let indexID = editor.addIndex()

        editor.deleteColumn(id: columnID)
        editor.deleteIndex(id: indexID)

        #expect(!editor.hasChanges)
        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).isEmpty)
    }

    @Test
    func deletingColumnsSelectsTheNearestRemainingColumn() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([
            makeColumn(name: "first", type: "int"),
            makeColumn(name: "middle", type: "int"),
            makeColumn(name: "last", type: "int"),
        ])
        let firstID = try #require(editor.columns.first?.id)
        let middleID = try #require(editor.columns.dropFirst().first?.id)
        let lastID = try #require(editor.columns.last?.id)

        #expect(editor.deleteColumn(id: middleID) == lastID)
        #expect(editor.deleteColumn(id: lastID) == firstID)

        let draftID = editor.addColumn()
        #expect(editor.deleteColumn(id: draftID) == firstID)
    }

    @Test
    func deletingIndexesSelectsTheNearestRemainingIndex() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadIndexesIfNeeded([
            makePrimaryIndex(),
            makeIndex(name: "idx_middle", columnName: "middle"),
            makeIndex(name: "idx_last", columnName: "last"),
        ])
        let firstID = try #require(editor.indexes.first?.id)
        let middleID = try #require(editor.indexes.dropFirst().first?.id)
        let lastID = try #require(editor.indexes.last?.id)

        #expect(editor.deleteIndex(id: middleID) == lastID)
        #expect(editor.deleteIndex(id: lastID) == firstID)
    }

    @Test
    func duplicateColumnPreservesParameterizedTypeAndUsesUniqueName() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([
            makeColumn(name: "amount", type: "DECIMAL(10,6)"),
            makeColumn(name: "amount_copy", type: "INT"),
        ])
        let sourceID = try #require(editor.columns.first?.id)

        let duplicatedID = editor.duplicateColumn(id: sourceID)
        let duplicateID = try #require(duplicatedID)
        let duplicate = try #require(
            editor.columns.first(where: { $0.id == duplicateID })
        )

        #expect(duplicate.isNew)
        #expect(duplicate.definition.name == "amount_copy2")
        #expect(duplicate.definition.type == "DECIMAL(10,6)")
    }

    @Test
    func duplicatePrimaryIndexBecomesNamedNormalIndex() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadIndexesIfNeeded([makePrimaryIndex()])
        let primaryID = try #require(editor.indexes.first?.id)

        let duplicatedID = editor.duplicateIndex(id: primaryID)
        let duplicateID = try #require(duplicatedID)
        let duplicate = try #require(
            editor.indexes.first(where: { $0.id == duplicateID })
        )

        #expect(duplicate.isNew)
        #expect(duplicate.definition.name == "index_copy")
        #expect(duplicate.definition.kind == .normal)
        #expect(duplicate.definition.columns.map(\.name) == ["id"])
    }

    @Test
    func preservesOnUpdateAndBuildsSpecialIndexes() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([
            WorkspaceDatabaseColumn(
                name: "updated_at",
                type: "timestamp",
                collation: nil,
                isNullable: false,
                key: "",
                defaultValue: "CURRENT_TIMESTAMP",
                extra: "DEFAULT_GENERATED on update CURRENT_TIMESTAMP INVISIBLE",
                comment: ""
            ),
        ])
        let columnID = try #require(editor.columns.first?.id)
        var column = try #require(editor.columns.first?.definition)
        column.comment = "last update"
        editor.updateColumn(id: columnID, definition: column)

        let indexID = editor.addIndex()
        var index = try #require(
            editor.indexes.first(where: { $0.id == indexID })?.definition
        )
        index.name = "idx_updated_at_spatial"
        index.kind = .spatial
        index.columns = [.init(name: "updated_at")]
        editor.updateIndex(id: indexID, definition: index)

        let statements = MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        )

        #expect(statements.map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` MODIFY COLUMN `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP INVISIBLE COMMENT 'last update'",
            "ALTER TABLE `querycraft_test`.`users` ADD SPATIAL INDEX `idx_updated_at_spatial` (`updated_at`)",
        ])
    }

    @Test
    func characterSetCollationAndExtraProduceOneColumnDefinition() throws {
        let choices = WorkspaceDatabaseSchemaChoices(
            characterSets: ["utf8mb4", "latin1"],
            collations: [
                .init(
                    name: "utf8mb4_0900_ai_ci",
                    characterSet: "utf8mb4",
                    isDefault: true
                ),
                .init(
                    name: "utf8mb4_bin",
                    characterSet: "utf8mb4",
                    isDefault: false
                ),
            ]
        )
        var editor = WorkspaceDatabaseSchemaEditorState()
        let columnID = editor.addColumn()
        var column = try #require(editor.columns.first?.definition)
        column.name = "slug"
        column.applyCollation("utf8mb4_bin", choices: choices)
        column.applyExtraDisplayValue("invisible")
        editor.updateColumn(id: columnID, definition: column)

        let statements = MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        )

        #expect(column.characterSet == "utf8mb4")
        #expect(!column.isVisible)
        #expect(statements.map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` ADD COLUMN `slug` VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL INVISIBLE",
        ])
    }

    @Test
    func emptyDefaultExpressionRemainsPreviewableForDatabaseValidation() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let columnID = editor.addColumn()
        var column = try #require(editor.columns.first?.definition)
        column.name = "created_at"
        column.type = "timestamp"
        column.defaultMode = .expression
        column.defaultValue = "  "
        editor.updateColumn(id: columnID, definition: column)

        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` ADD COLUMN `created_at` timestamp DEFAULT ",
        ])
    }

    @Test
    func primaryKeySwitchAddsPrimaryIndex() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([makeColumn(name: "id", type: "bigint")])
        editor.loadIndexesIfNeeded([])
        let columnID = try #require(editor.columns.first?.id)

        editor.setPrimaryKey(columnID: columnID, isEnabled: true)

        #expect(editor.isPrimaryKey(columnID: columnID))
        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` MODIFY COLUMN `id` bigint NOT NULL",
            "ALTER TABLE `querycraft_test`.`users` ADD PRIMARY KEY (`id`) USING BTREE",
        ])
    }

    @Test
    func blankDraftPrimaryKeyUsesColumnIdentity() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let columnIDs = (0..<4).map { _ in editor.addColumn() }
        let selectedID = try #require(columnIDs.last)

        editor.setPrimaryKey(columnID: selectedID, isEnabled: true)

        #expect(editor.isPrimaryKey(columnID: selectedID))
        for columnID in columnIDs.dropLast() {
            #expect(!editor.isPrimaryKey(columnID: columnID))
        }
        let primary = try #require(
            editor.indexes.first(where: { $0.definition.kind == .primary })
        )
        #expect(primary.definition.columns.count == 1)
        #expect(primary.definition.columns.first?.sourceColumnID == selectedID)

        var renamed = try #require(
            editor.columns.first(where: { $0.id == selectedID })?.definition
        )
        renamed.name = "selected_column"
        editor.updateColumn(id: selectedID, definition: renamed)

        #expect(editor.indexes.first?.definition.columns.first?.name
            == "selected_column")
        #expect(editor.columns.dropLast().allSatisfy {
            $0.definition.name.isEmpty
        })
    }

    @Test
    func primaryKeySwitchDropsExistingPrimaryIndex() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([makeColumn(name: "id", type: "bigint")])
        editor.loadIndexesIfNeeded([makePrimaryIndex()])
        let columnID = try #require(editor.columns.first?.id)

        editor.setPrimaryKey(columnID: columnID, isEnabled: false)

        #expect(!editor.isPrimaryKey(columnID: columnID))
        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` DROP PRIMARY KEY",
        ])
    }

    @Test
    func primaryKeySwitchPreservesOtherCompositeColumns() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([
            makeColumn(name: "tenant_id", type: "bigint"),
            makeColumn(name: "id", type: "bigint"),
        ])
        editor.loadIndexesIfNeeded([
            makePrimaryIndex(columnNames: ["tenant_id", "id"]),
        ])
        let id = try #require(
            editor.columns.first(where: { $0.definition.name == "id" })?.id
        )

        editor.setPrimaryKey(columnID: id, isEnabled: false)

        #expect(!editor.isPrimaryKey(columnID: id))
        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` DROP PRIMARY KEY",
            "ALTER TABLE `querycraft_test`.`users` ADD PRIMARY KEY (`tenant_id`) USING BTREE",
        ])
    }

    @Test
    func renamingPrimaryColumnUpdatesIndexReference() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([makeColumn(name: "id", type: "bigint")])
        editor.loadIndexesIfNeeded([makePrimaryIndex()])
        let columnID = try #require(editor.columns.first?.id)
        var definition = try #require(editor.columns.first?.definition)
        definition.name = "record_id"

        editor.updateColumn(id: columnID, definition: definition)

        #expect(editor.isPrimaryKey(columnID: columnID))
        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` DROP PRIMARY KEY",
            "ALTER TABLE `querycraft_test`.`users` CHANGE COLUMN `id` `record_id` bigint NOT NULL",
            "ALTER TABLE `querycraft_test`.`users` ADD PRIMARY KEY (`record_id`) USING BTREE",
        ])
    }

    @Test
    func defaultPresetsProduceExpectedColumnDDL() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let columnID = editor.addColumn()
        var definition = try #require(editor.columns.first?.definition)
        definition.name = "created_at"
        definition.type = "TIMESTAMP"
        definition.applyDefaultPreset(.currentTimestamp)
        editor.updateColumn(id: columnID, definition: definition)

        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` ADD COLUMN `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP",
        ])
    }

    @Test
    func defaultGeneratedMetadataDoesNotLockSchemaEditing() throws {
        let defaultGenerated = WorkspaceDatabaseColumn(
            name: "updated_at",
            type: "timestamp",
            collation: nil,
            isNullable: false,
            key: "",
            defaultValue: "CURRENT_TIMESTAMP",
            extra: "DEFAULT_GENERATED on update CURRENT_TIMESTAMP",
            comment: ""
        )
        let virtualGenerated = WorkspaceDatabaseColumn(
            name: "computed_value",
            type: "int",
            collation: nil,
            isNullable: true,
            key: "",
            defaultValue: nil,
            extra: "VIRTUAL GENERATED",
            comment: "",
            generationExpression: "`source_value` + 1"
        )

        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([defaultGenerated, virtualGenerated])

        #expect(editor.columns[0].isEditable)
        #expect(editor.columns[1].isEditable)
        #expect(editor.columns[1].definition.generatedStorage == .virtual)
        #expect(
            editor.columns[1].definition.generationExpression
                == "`source_value` + 1"
        )
    }

    @Test
    func generatedColumnsBuildVirtualAndStoredDDLWithoutConflictingClauses() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let virtualID = editor.addColumn()
        var virtual = try #require(
            editor.columns.first(where: { $0.id == virtualID })?.definition
        )
        virtual.name = "line_total"
        virtual.type = "DECIMAL(10,2)"
        virtual.defaultMode = .value
        virtual.defaultValue = "1"
        virtual.isAutoIncrement = true
        virtual.onUpdateExpression = "CURRENT_TIMESTAMP"
        virtual.applyGeneratedStorage(.virtual)
        virtual.generationExpression = "`price` * `quantity`"
        editor.updateColumn(id: virtualID, definition: virtual)

        let storedID = editor.addColumn()
        var stored = try #require(
            editor.columns.first(where: { $0.id == storedID })?.definition
        )
        stored.name = "normalized_email"
        stored.type = "VARCHAR(255)"
        stored.applyGeneratedStorage(.stored)
        stored.generationExpression = "lower(`email`)"
        editor.updateColumn(id: storedID, definition: stored)

        #expect(virtual.defaultMode == .none)
        #expect(!virtual.isAutoIncrement)
        #expect(virtual.onUpdateExpression.isEmpty)
        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` ADD COLUMN `line_total` DECIMAL(10,2) GENERATED ALWAYS AS (`price` * `quantity`) VIRTUAL",
            "ALTER TABLE `querycraft_test`.`users` ADD COLUMN `normalized_email` VARCHAR(255) GENERATED ALWAYS AS (lower(`email`)) STORED",
        ])
    }

    @Test
    func existingPrimaryKeyDoesNotBlockNewGeneratedColumnPreview() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([
            makeColumn(name: "id", type: "bigint"),
            makeColumn(name: "price", type: "decimal(10,2)"),
        ])
        editor.loadIndexesIfNeeded([makePrimaryIndex()])

        let amountID = editor.addColumn()
        var amount = try #require(
            editor.columns.first(where: { $0.id == amountID })?.definition
        )
        amount.name = "qc_tmp_amount"
        amount.type = "decimal(10,2)"
        amount.isNullable = false
        amount.defaultMode = .value
        amount.defaultValue = "0.00"
        editor.updateColumn(id: amountID, definition: amount)

        let totalID = editor.addColumn()
        var total = try #require(
            editor.columns.first(where: { $0.id == totalID })?.definition
        )
        total.name = "qc_tmp_total"
        total.type = "decimal(10,2)"
        total.applyGeneratedStorage(.virtual)
        total.generationExpression = "`price` * 2"
        editor.updateColumn(id: totalID, definition: total)

        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` ADD COLUMN `qc_tmp_amount` decimal(10,2) NOT NULL DEFAULT 0.00",
            "ALTER TABLE `querycraft_test`.`users` ADD COLUMN `qc_tmp_total` decimal(10,2) GENERATED ALWAYS AS (`price` * 2) VIRTUAL",
        ])
    }

    @Test
    func emptyGeneratedExpressionRemainsPreviewableForDatabaseValidation() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let id = editor.addColumn()
        var definition = try #require(editor.columns.first?.definition)
        definition.name = "computed"
        definition.applyGeneratedStorage(.stored)
        editor.updateColumn(id: id, definition: definition)

        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` ADD COLUMN `computed` VARCHAR(255) GENERATED ALWAYS AS () STORED",
        ])
    }

    @Test
    func incompleteIndexRemainsPreviewableForDatabaseValidation() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let id = editor.addIndex()
        var definition = try #require(editor.indexes.first?.definition)
        definition.columns[0].name = ""
        definition.columns[0].prefixLength = "invalid"
        editor.updateIndex(id: id, definition: definition)

        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` ADD INDEX `` (``(invalid)) USING BTREE",
        ])
    }

    @Test
    func compositeIndexPreservesOrderPrefixDirectionAndVisibility() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        editor.loadColumnsIfNeeded([
            makeColumn(name: "tenant_id", type: "bigint"),
            makeColumn(name: "email", type: "varchar(255)"),
            makeColumn(name: "created_at", type: "timestamp"),
        ])
        let id = editor.addIndex()
        var definition = try #require(editor.indexes.first?.definition)
        definition.name = "idx_tenant_email_created"
        definition.columns = [
            .init(name: "tenant_id"),
            .init(name: "email"),
            .init(name: "created_at"),
        ]
        definition.columns[1].prefixLength = "120"
        definition.columns[2].isDescending = true
        definition.isVisible = false
        editor.updateIndex(id: id, definition: definition)

        #expect(MySQLWorkspaceSchemaStatement.make(
            changes: changeSet(editor)
        ).map(\.sql) == [
            "ALTER TABLE `querycraft_test`.`users` ADD INDEX `idx_tenant_email_created` (`tenant_id`, `email`(120), `created_at` DESC) USING BTREE INVISIBLE",
        ])
    }

    private func changeSet(
        _ editor: WorkspaceDatabaseSchemaEditorState
    ) -> WorkspaceDatabaseSchemaChangeSet {
        WorkspaceDatabaseSchemaChangeSet(
            selection: WorkspaceDatabaseObjectSelection(
                databaseName: "querycraft_test",
                objectName: "users",
                kind: .table
            ),
            columns: editor.columns,
            indexes: editor.indexes
        )
    }

    private func makeColumn(name: String, type: String) -> WorkspaceDatabaseColumn {
        WorkspaceDatabaseColumn(
            name: name,
            type: type,
            collation: type.contains("char") ? "utf8mb4_0900_ai_ci" : nil,
            isNullable: true,
            key: "",
            defaultValue: nil,
            extra: "",
            comment: ""
        )
    }

    private func makePrimaryIndex(
        columnNames: [String] = ["id"]
    ) -> WorkspaceDatabaseIndex {
        WorkspaceDatabaseIndex(
            name: "PRIMARY",
            columns: columnNames.enumerated().map { offset, name in
                WorkspaceDatabaseIndexColumn(
                    sequence: Int64(offset + 1),
                    name: name,
                    prefixLength: nil,
                    direction: "A",
                    isExpression: false
                )
            },
            isUnique: true,
            type: "BTREE",
            cardinality: 1,
            isVisible: true,
            comment: ""
        )
    }

    private func makeIndex(
        name: String,
        columnName: String
    ) -> WorkspaceDatabaseIndex {
        WorkspaceDatabaseIndex(
            name: name,
            columns: [
                WorkspaceDatabaseIndexColumn(
                    sequence: 1,
                    name: columnName,
                    prefixLength: nil,
                    direction: "A",
                    isExpression: false
                ),
            ],
            isUnique: false,
            type: "BTREE",
            cardinality: 1,
            isVisible: true,
            comment: ""
        )
    }
}
