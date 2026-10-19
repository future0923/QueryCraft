import Foundation
import Testing
@testable import QueryCraftFeature

struct SchemaComparisonNativeEngineTests {
    private func column(_ name: String, _ type: String = "int", nullable: Bool = true, defaultValue: SchemaEngineJSON = .null) -> SchemaEngineJSON {
        .object(["name": .string(name), "data_type": .string(type), "is_nullable": .bool(nullable), "column_default": defaultValue,
                 "is_primary_key": .bool(false), "is_unique": .bool(false), "extra": .string(""), "comment": .string("")])
    }
    private func index(_ name: String, columns: [String], primary: Bool = false, unique: Bool = false) -> SchemaEngineJSON {
        .object(["name": .string(name), "columns": .array(columns.map(SchemaEngineJSON.string)), "is_primary": .bool(primary), "is_unique": .bool(primary || unique), "index_type": .string("BTREE")])
    }
    private func object(_ name: String, _ ddl: String, columns: [SchemaEngineJSON] = [], indexes: [SchemaEngineJSON] = [], foreignKeys: [SchemaEngineJSON] = [], triggers: [SchemaEngineJSON] = [], view: Bool = false) -> SchemaEngineJSON {
        .object(["name": .string(name), "ddl": .string(ddl), "columns": .array(columns), "indexes": .array(indexes), "foreignKeys": .array(foreignKeys), "triggers": .array(triggers), "kind": .string(view ? "VIEW" : "BASE TABLE")])
    }
    private func snapshot(_ objects: [SchemaEngineJSON], database: String, routines: [SchemaEngineJSON] = []) -> SchemaComparisonSnapshot {
        .init(database: database, serverID: "server", version: "8.4.11", sqlMode: "", lowerCaseTableNames: 0, objects: objects.map { .init(name: $0["name"].string, ddl: $0["ddl"].string, definition: nil, error: nil) }, capturedAt: .now,
            engineMetadata: .object(["tables": .array(objects.map { .object(["name": $0["name"], "table_type": $0["kind"], "comment": .string("")]) }), "details": .array(objects), "functions": .array(routines), "sequences": .array([]), "rules": .array([]), "owners": .array([])]))
    }
    private func compare(_ source: [SchemaEngineJSON], _ target: [SchemaEngineJSON], options: SchemaComparisonOptions = .init()) async throws -> SchemaComparisonNativeResult {
        try await SchemaComparisonNativeEngine().analyze(source: snapshot(source, database: "source"), target: snapshot(target, database: "target"), options: options)
    }
    @Test func selectionPreservesNewColumnPositionAndIndexDependencies() async throws {
        let s = object("items", "CREATE TABLE `items` (`id` int, `note` varchar(80), `rank` int, KEY `idx_rank` (`rank`))", columns: [column("id"), column("note", "varchar(80)"), column("rank")], indexes: [index("idx_rank", columns: ["rank"])])
        let t = object("items", "CREATE TABLE `items` (`id` int)", columns: [column("id")])
        let result = try await compare([s], [t])
        let rank = try #require(result.differences.first { $0.object == "column:rank" })
        let note = try #require(result.differences.first { $0.object == "column:note" })
        let idx = try #require(result.differences.first { $0.object == "index:idx_rank" })
        #expect(rank.requiredIDs.contains(note.id))
        #expect(idx.requiredIDs.contains(rank.id))
        await #expect(throws: (any Error).self) { try await SchemaComparisonNativeEngine().plan(result: result.raw, selectedIDs: [idx.id], ignoreForeignKeyChecks: false) }
        let plan = try await SchemaComparisonNativeEngine().plan(result: result.raw, selectedIDs: [note.id, rank.id, idx.id], ignoreForeignKeyChecks: false)
        #expect(plan.statements.count == 1)
        #expect(plan.sql.contains("AFTER `note`"))
        #expect(plan.sql.contains("ADD KEY `idx_rank`"))
    }
    @Test func autoIncrementColumnAndPrimaryKeyAreOneAlterStatement() async throws {
        var autoColumn = column("id", nullable: false); autoColumn["extra"] = .string("auto_increment")
        let s = object("items", "CREATE TABLE `items` (`id` int NOT NULL AUTO_INCREMENT, PRIMARY KEY (`id`))", columns: [autoColumn], indexes: [index("PRIMARY", columns: ["id"], primary: true)])
        let t = object("items", "CREATE TABLE `items` (`id` int)", columns: [column("id")])
        let result = try await compare([s], [t])
        #expect(result.plan.statements.count == 1)
        #expect(result.plan.sql.contains("AUTO_INCREMENT"))
        #expect(result.plan.sql.contains("ADD PRIMARY KEY"))
        let key = try #require(result.differences.first { $0.object == "index:PRIMARY" })
        #expect(result.differences.first { $0.object == "column:id" }?.requiredIDs.contains(key.id) == true)
    }
    @Test func primaryUniqueAndOrdinaryIndexOptionsAreIndependent() async throws {
        let s = object("items", "CREATE TABLE `items` (`id` int, PRIMARY KEY (`id`), UNIQUE KEY `ux` (`id`), KEY `ix` (`id`))", columns: [column("id")], indexes: [index("PRIMARY", columns: ["id"], primary: true), index("ux", columns: ["id"], unique: true), index("ix", columns: ["id"])])
        let t = object("items", "CREATE TABLE `items` (`id` int)", columns: [column("id")])
        var options = SchemaComparisonOptions(); options.primaryKeys = false; options.uniqueKeys = false
        let result = try await compare([s], [t], options: options)
        #expect(result.differences.filter { $0.status != .equal }.map(\.object) == ["index:ix"])
    }
    @Test func indexPrefixChangesAreNotLostInCatalogConversion() async throws {
        let s = object("items", "CREATE TABLE `items` (`note` varchar(80), KEY `ix` (`note`(12)))", columns: [column("note", "varchar(80)")], indexes: [index("ix", columns: ["note"])])
        let t = object("items", "CREATE TABLE `items` (`note` varchar(80), KEY `ix` (`note`(8)))", columns: [column("note", "varchar(80)")], indexes: [index("ix", columns: ["note"])])
        let result = try await compare([s], [t])
        #expect(result.differences.contains { $0.object == "index:ix" && $0.status == .modified })
        #expect(result.plan.sql.contains("DROP INDEX `ix`"))
        #expect(result.plan.sql.contains("`note`(12)"))
    }
    @Test func renameDetectionUsesTypesAndNullabilityAndIsOptIn() async throws {
        let s = object("items", "CREATE TABLE `items` (`new_label` varchar(80))", columns: [column("new_label", "varchar(80)")])
        let t = object("items", "CREATE TABLE `items` (`old_label` varchar(80))", columns: [column("old_label", "varchar(80)")])
        let ordinary = try await compare([s], [t])
        #expect(ordinary.differences.count == 2)
        var options = SchemaComparisonOptions(); options.detectRenames = true; options.enableRollback = true
        let result = try await compare([s], [t], options: options)
        #expect(result.differences.count == 1)
        #expect(result.plan.sql.contains("CHANGE COLUMN `old_label` `new_label`"))
        #expect(result.plan.rollbackSQL.contains("CHANGE COLUMN `new_label` `old_label`"))
    }
    @Test func tableRenameAlsoRetainsItsColumnChanges() async throws {
        let s = object("new_items", "CREATE TABLE `new_items` (`id` int, `label` varchar(80))", columns: [column("id"), column("label", "varchar(80)")])
        let t = object("old_items", "CREATE TABLE `old_items` (`id` int, `label` varchar(40))", columns: [column("id"), column("label", "varchar(40)")])
        var options = SchemaComparisonOptions(); options.detectRenames = true; options.detectTableRenames = true
        let result = try await compare([s], [t], options: options)
        #expect(result.plan.sql.contains("RENAME TABLE `target`.`old_items` TO `target`.`new_items`"))
        #expect(result.plan.sql.contains("ALTER TABLE `target`.`new_items`"))
        #expect(result.differences.contains { $0.object == "column:label" })
    }
    @Test func checksAndVersionCommentsRetainExpressionsAndLiteralContents() async throws {
        let ddl = "CREATE TABLE `items` (`id` int, `n` int GENERATED ALWAYS AS ((`id` + 1)) STORED, KEY `ix` (`id`) /*!80000 INVISIBLE */, CONSTRAINT `ck` CHECK ((`id` > 0)))"
        let result = try await compare([object("items", ddl, columns: [column("id"), column("n")])], [])
        #expect(result.plan.sql.contains("/*!80000 INVISIBLE */"))
        #expect(result.plan.sql.contains("GENERATED ALWAYS"))
        #expect(result.plan.sql.contains("CHECK ((`id` > 0))"))
        let s = object("items", "CREATE TABLE `items` (`id` int, CONSTRAINT `ck` CHECK ((`id` > 0)))", columns: [column("id")])
        let t = object("items", "CREATE TABLE `items` (`id` int, CONSTRAINT `ck` CHECK ((`id` > -1)))", columns: [column("id")])
        let changed = try await compare([s], [t])
        #expect(changed.plan.sql.contains("DROP CHECK `ck`"))
        var options = SchemaComparisonOptions(); options.checks = false
        #expect(try await compare([s], [t], options: options).differences.allSatisfy { $0.status == .equal })
    }
    @Test func viewDefinitionsRetargetIdentifiersWithoutChangingStringLiterals() async throws {
        let source = object("v", "CREATE ALGORITHM=UNDEFINED DEFINER=`source_user`@`%` SQL SECURITY DEFINER VIEW `source`.`v` AS select 'source.v  A  B' AS `label`", view: true)
        let target = object("v", "CREATE ALGORITHM=UNDEFINED DEFINER=`target_user`@`%` SQL SECURITY DEFINER VIEW `target`.`v` AS select 'source.v  A B' AS `label`", view: true)
        let result = try await compare([source], [target])
        #expect(result.differences.first?.status == .modified)
        #expect(result.plan.sql.contains("VIEW `target`.`v`"))
        #expect(result.plan.sql.contains("'source.v  A  B'"))
    }
    @Test func definerAloneDoesNotChangeAView() async throws {
        let s = object("v", "CREATE DEFINER=`a`@`%` VIEW `source`.`v` AS select 1", view: true)
        let t = object("v", "CREATE DEFINER=`b`@`%` VIEW `target`.`v` AS select 1", view: true)
        #expect(try await compare([s], [t]).plan.statements.isEmpty)
    }
    @Test func rollbackKeepsExternalDatabaseReferenceWhenRoutineTextMatches() async throws {
        let routine = SchemaEngineJSON.object(["name": .string("p"), "functionType": .string("PROCEDURE"), "dataType": .string(""), "arguments": .string(""), "definition": .string("CREATE PROCEDURE `p`() SELECT id FROM `source`.`items`")])
        var options = SchemaComparisonOptions(); options.enableRollback = true
        let result = try await SchemaComparisonNativeEngine().analyze(source: snapshot([], database: "source", routines: [routine]), target: snapshot([], database: "target", routines: [routine]), options: options)
        #expect(result.plan.sql.contains("FROM `target`.`items`"))
        #expect(result.plan.rollbackSQL.contains("FROM `source`.`items`"))
    }
    @Test func procedureBodyIsOneExecutionStatementAndExportGetsDelimiter() async throws {
        let routine = SchemaEngineJSON.object(["name": .string("p"), "functionType": .string("PROCEDURE"), "dataType": .string(""), "arguments": .string(""), "definition": .string("CREATE PROCEDURE `p`() BEGIN SELECT 'A; B'; SELECT 2; END")])
        let result = try await SchemaComparisonNativeEngine().analyze(source: snapshot([], database: "source", routines: [routine]), target: snapshot([], database: "target"), options: .init())
        #expect(result.plan.statements.count == 1)
        #expect(result.plan.statements[0].contains("SELECT 'A; B'; SELECT 2;"))
        #expect(result.plan.sql.contains("DELIMITER $$"))
    }
    @Test func foreignKeyPairsKeepOrdinalOrderAndRetargetOwnDatabase() async throws {
        let fks: [SchemaEngineJSON] = ["a", "b"].map { .object(["name": .string("fk"), "column": .string($0), "ref_schema": .string("source"), "ref_table": .string("parent"), "ref_column": .string($0), "on_delete": .string("CASCADE"), "on_update": .string("RESTRICT")]) }
        let parent = object("parent", "CREATE TABLE `parent` (`a` int, `b` int, PRIMARY KEY (`a`,`b`))", columns: [column("a"), column("b")], indexes: [index("PRIMARY", columns: ["a", "b"], primary: true)])
        let child = object("child", "CREATE TABLE `child` (`a` int, `b` int, CONSTRAINT `fk` FOREIGN KEY (`a`,`b`) REFERENCES `parent` (`a`,`b`))", columns: [column("a"), column("b")], foreignKeys: fks)
        let result = try await compare([child, parent], [])
        #expect(result.plan.statements.first?.contains("`target`.`parent`") == true)
        #expect(result.plan.statements.last?.contains("FOREIGN KEY (`a`, `b`) REFERENCES `target`.`parent` (`a`, `b`)") == true)
        let childChange = try #require(result.differences.first { $0.table == "child" })
        let parentChange = try #require(result.differences.first { $0.table == "parent" })
        #expect(childChange.requiredIDs.contains(parentChange.id))
    }
    @Test func preflightIgnoresOnlyRuntimeCounterAndRejectsStructuralChanges() {
        let a = snapshot([object("items", "CREATE TABLE `items` (`id` int) ENGINE=InnoDB AUTO_INCREMENT=10")], database: "target")
        let b = snapshot([object("items", "CREATE TABLE `items` (`id` int) ENGINE=InnoDB AUTO_INCREMENT=20")], database: "target")
        let c = snapshot([object("items", "CREATE TABLE `items` (`id` bigint) ENGINE=InnoDB AUTO_INCREMENT=20")], database: "target")
        #expect(SchemaComparisonDeployment.agrees(a, b))
        #expect(!SchemaComparisonDeployment.agrees(a, c))
    }
}

extension SchemaComparisonNativeEngineTests {
    @Test func changingBothEndsOfAnUnchangedForeignKeyRebuildsItAroundAlterations() async throws {
        func fk(_ db: String) -> SchemaEngineJSON {
            .object(["name": .string("fk"), "column": .string("parent_id"), "ref_schema": .string(db), "ref_table": .string("parents"), "ref_column": .string("id"), "on_delete": .string("RESTRICT"), "on_update": .string("RESTRICT")])
        }
        let sp = object("parents", "CREATE TABLE `parents` (`id` bigint, PRIMARY KEY (`id`))", columns: [column("id", "bigint")], indexes: [index("PRIMARY", columns: ["id"], primary: true)])
        let tp = object("parents", "CREATE TABLE `parents` (`id` int, PRIMARY KEY (`id`))", columns: [column("id")], indexes: [index("PRIMARY", columns: ["id"], primary: true)])
        let sc = object("children", "CREATE TABLE `children` (`parent_id` bigint, CONSTRAINT `fk` FOREIGN KEY (`parent_id`) REFERENCES `parents` (`id`))", columns: [column("parent_id", "bigint")], foreignKeys: [fk("source")])
        let tc = object("children", "CREATE TABLE `children` (`parent_id` int, CONSTRAINT `fk` FOREIGN KEY (`parent_id`) REFERENCES `parents` (`id`))", columns: [column("parent_id")], foreignKeys: [fk("target")])
        let result = try await compare([sp, sc], [tp, tc], options: .init(enableRollback: true))
        let constraint = try #require(result.differences.first { $0.object == "foreignKey:fk" })
        #expect(constraint.attributes.contains { $0.key == "dependency" })
        #expect(constraint.requiredIDs.count == 2)
        #expect(result.plan.statements.first?.contains("DROP FOREIGN KEY") == true)
        #expect(result.plan.statements.last?.contains("ADD CONSTRAINT") == true)
        #expect(result.plan.rollbackStatements.first?.contains("DROP FOREIGN KEY") == true)
        #expect(result.plan.rollbackStatements.last?.contains("ADD CONSTRAINT") == true)
    }
    @Test func lineDifferencesPreserveLiteralSpacesAndDoNotHighlightEqualLines() {
        let diff = SchemaComparisonDDLLineDiff.compare(source: "CREATE TABLE x\n  note DEFAULT 'A  B'\n);", target: "CREATE TABLE x\n  note DEFAULT 'A B'\n);")
        #expect(diff.source == [1] && diff.target == [1])
    }
}

extension SchemaComparisonNativeEngineTests {
    @Test func sameNamedFunctionAndProcedureHaveDifferentIdentityAndGroups() async throws {
        let function = SchemaEngineJSON.object(["name": .string("calculate"), "functionType": .string("FUNCTION"), "dataType": .string("int"), "arguments": .string("IN `n` int"), "definition": .string("CREATE FUNCTION `calculate`(n int) RETURNS int DETERMINISTIC RETURN n*2")])
        let procedure = SchemaEngineJSON.object(["name": .string("calculate"), "functionType": .string("PROCEDURE"), "dataType": .string(""), "arguments": .string("IN `n` int"), "definition": .string("CREATE PROCEDURE `calculate`(n int) SELECT n")])
        let result = try await SchemaComparisonNativeEngine().analyze(source: snapshot([], database: "source", routines: [function, procedure]), target: snapshot([], database: "target"), options: .init())
        #expect(Set(result.differences.map(\.id)).count == 2)
        #expect(Set(result.differences.map(\.groupKey)).count == 2)
        #expect(result.plan.sql.contains("CREATE FUNCTION") && result.plan.sql.contains("CREATE PROCEDURE"))
    }
}

extension SchemaComparisonNativeEngineTests {
    @Test func triggerGroupRebuildPreservesSourceOrderWhenOnlyFirstBodyChanged() async throws {
        func trigger(_ name: String, body: String, order: Int) -> SchemaEngineJSON { .object(["name": .string(name), "event": .string("INSERT"), "timing": .string("BEFORE"), "statement": .string(body), "action_order": .string(String(order))]) }
        let source = object("items", "CREATE TABLE `items` (`note` varchar(80))", columns: [column("note", "varchar(80)")], triggers: [trigger("first", body: "SET NEW.note=LOWER(NEW.note)", order: 1), trigger("second", body: "SET NEW.note=CONCAT(NEW.note,'A')", order: 2)])
        let target = object("items", "CREATE TABLE `items` (`note` varchar(80))", columns: [column("note", "varchar(80)")], triggers: [trigger("first", body: "SET NEW.note=UPPER(NEW.note)", order: 1), trigger("second", body: "SET NEW.note=CONCAT(NEW.note,'A')", order: 2)])
        let result = try await compare([source], [target], options: .init(enableRollback: true))
        #expect(result.differences.filter { $0.object.hasPrefix("trigger:") }.count == 2)
        #expect(result.differences.allSatisfy { $0.requiredIDs.count == 1 })
        let creates = result.plan.statements.filter { $0.hasPrefix("CREATE TRIGGER") }
        #expect(creates.count == 2 && creates[0].contains("`first`") && creates[1].contains("`second`"))
    }
}

extension SchemaComparisonNativeEngineTests {
    @Test func databaseNamedAliasIsPreservedWhileRealDatabaseReferencesMove() async throws {
        let source = object("v", "CREATE VIEW `source`.`v` AS SELECT `source`.`id`, 'source.users' AS `literal` FROM `source`.`users` AS `source`", view: true)
        let result = try await compare([source], [])
        #expect(result.plan.sql.contains("SELECT `source`.`id`"))
        #expect(result.plan.sql.contains("FROM `target`.`users` AS `source`"))
        #expect(result.plan.sql.contains("'source.users'"))
    }
}

extension SchemaComparisonNativeEngineTests {
    @Test func autoIncrementWithoutAnEnabledBackingKeyStaysComparisonOnly() async throws {
        var autoColumn = column("id", nullable: false); autoColumn["extra"] = .string("auto_increment")
        let s = object("items", "CREATE TABLE `items` (`id` int NOT NULL AUTO_INCREMENT, PRIMARY KEY (`id`))", columns: [autoColumn], indexes: [index("PRIMARY", columns: ["id"], primary: true)])
        let t = object("items", "CREATE TABLE `items` (`id` int)", columns: [column("id")])
        var options = SchemaComparisonOptions(); options.primaryKeys = false; options.uniqueKeys = false; options.indexes = false
        let result = try await compare([s], [t], options: options)
        #expect(result.differences.contains { $0.status == .unavailable && $0.object == "column:id" })
        #expect(result.plan.statements.isEmpty)
    }
}

extension SchemaComparisonNativeEngineTests {
    @Test func incompleteColumnCatalogCannotBecomeFalseDropStatements() async {
        let source = object("items", "CREATE TABLE `items` (`id` int, `note` varchar(80))", columns: [column("id")])
        let target = object("items", "CREATE TABLE `items` (`id` int, `note` varchar(80))", columns: [column("id"), column("note", "varchar(80)")])
        await #expect(throws: (any Error).self) { try await compare([source], [target]) }
    }
}
