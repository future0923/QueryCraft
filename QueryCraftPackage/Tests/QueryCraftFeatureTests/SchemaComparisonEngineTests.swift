import Foundation
import Testing
@testable import QueryCraftFeature

struct SchemaComparisonEngineTests {
    @Test(arguments: [("5.7.35-log", "8.0.46"), ("5.7.44", "8.4.11"), ("8.0.46", "8.4.11")])
    func forwardVersionComparisonOffersOnlyCompatibleAdditions(_ versions: (String, String)) throws {
        let source = try object("CREATE TABLE `orders` (`id` int(11), `note` varchar(100) DEFAULT NULL, KEY `idx_id` (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
        let target = try object("CREATE TABLE `orders` (`id` int) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci")
        let sourceDDL = versions.0.hasPrefix("5.7") ? source : try object("CREATE TABLE `orders` (`id` int(11), `note` varchar(100) DEFAULT NULL, KEY `idx_id` (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci")
        let result = try SchemaComparisonEngine.compare(
            source: snapshot([sourceDDL], database: "source", version: versions.0, sqlMode: "STRICT_TRANS_TABLES,NO_AUTO_CREATE_USER"),
            target: snapshot([target], database: "target", version: versions.1, sqlMode: "STRICT_TRANS_TABLES"))
        #expect(result.first { $0.object == "column:id" }?.status == .equal)
        #expect(result.compactMap(\.sql).count == 2)
    }

    @Test func implicitCollationDoesNotHideActualCrossVersionCollationChanges() throws {
        let source = try object("CREATE TABLE `orders` (`id` int, `note` varchar(20) DEFAULT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
        let target = try object("CREATE TABLE `orders` (`id` int) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "source", version: "5.7.44"),
            target: snapshot([target], database: "target", version: "8.0.46"))
        #expect(result.contains { $0.object == "options" && $0.status == .modified })
        #expect(result.compactMap(\.sql).isEmpty)
    }

    @Test func metadataSupportsMySQL57AndSourceDistributionWithoutAcceptingMariaDB() {
        #expect(MySQLSchemaCompatibility.supportsMetadata(version: "5.7.35-log", comment: "MySQL Community Server (GPL)"))
        #expect(MySQLSchemaCompatibility.supportsMetadata(version: "8.0.46", comment: "Source distribution"))
        #expect(!MySQLSchemaCompatibility.supportsMetadata(version: "5.5.5-10.11-MariaDB", comment: "mariadb.org"))
        #expect(!MySQLSchemaCompatibility.supportsMetadata(version: "8.0.46", comment: "MariaDB"))
        #expect(!MySQLSchemaCompatibility.canExportAdditions(from: "8.4.11", to: "5.7.44"))
    }

    @Test func integerDisplayWidthNormalizationPreservesActualTypeAndZerofillDifferences() throws {
        let options = SchemaComparisonOptions()
        func tokens(_ definition: String) throws -> [String] {
            options.comparableTokens(try MySQLSchemaDefinition(ddl: "CREATE TABLE `x` (\(definition))").parts[0].tokens)
        }
        #expect(try tokens("`id` bigint(20) UNSIGNED") == tokens("`id` bigint UNSIGNED"))
        #expect(try tokens("`id` int(8) ZEROFILL") != tokens("`id` int(12) ZEROFILL"))
        #expect(try tokens("`id` varchar(8)") != tokens("`id` varchar(12)"))
        #expect(try tokens("`id` decimal(8,2)") != tokens("`id` decimal(12,2)"))
    }

    @Test func crossVersionFloatingPointPrecisionIsNotExported() throws {
        let source = try object("CREATE TABLE `orders` (`id` int, `amount` double(10,2) DEFAULT NULL)")
        let target = try object("CREATE TABLE `orders` (`id` int)")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "source", version: "5.7.44"),
            target: snapshot([target], database: "target", version: "8.4.11"))
        #expect(result.first { $0.object == "column:amount" }?.status == .added)
        #expect(result.compactMap(\.sql).isEmpty)
    }

    @Test func presentationRetainsOriginalIdentifierCaseAndEscapes() throws {
        let source = try object("CREATE TABLE `orders` (`Buyer``Note` varchar(255) DEFAULT NULL, KEY `IdxBuyer` (`Buyer``Note`))")
        let target = try object("CREATE TABLE `orders` (`Buyer``Note` varchar(100) DEFAULT NULL)")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "dev"), target: snapshot([target], database: "test"))
        #expect(result.first { $0.object == "column:buyer`note" }?.objectName == "Buyer`Note")
        #expect(result.first { $0.object == "index:idxbuyer" }?.objectName == "IdxBuyer")
    }

    private func object(_ ddl: String, name: String = "orders") throws -> SchemaComparisonSnapshot.Object {
        .init(name: name, ddl: ddl, definition: try MySQLSchemaDefinition(ddl: ddl), error: nil)
    }

    private func snapshot(
        _ objects: [SchemaComparisonSnapshot.Object], database: String,
        serverID: String = "server", version: String = "8.0.40", caseMode: Int = 0, sqlMode: String = ""
    ) -> SchemaComparisonSnapshot {
        .init(database: database, serverID: serverID, version: version, sqlMode: sqlMode,
              lowerCaseTableNames: caseMode, objects: objects, capturedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func formattingAndAutoIncrementCountersDoNotCreateDifferences() throws {
        let source = try object("CREATE TABLE `orders` (`id` bigint NOT NULL AUTO_INCREMENT, PRIMARY KEY (`id`)) ENGINE=InnoDB AUTO_INCREMENT=82")
        let target = try object("CREATE TABLE `orders` (\n`id` BIGINT NOT NULL AUTO_INCREMENT,\nPRIMARY KEY (`id`)\n) ENGINE = InnoDB AUTO_INCREMENT = 4;")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "dev"), target: snapshot([target], database: "test"))
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.status == .equal })
    }

    @Test func literalsRetainWhitespaceCaseAndPunctuation() throws {
        let source = try object("CREATE TABLE `orders` (`note` varchar(20) DEFAULT 'A, (x)  b')")
        let target = try object("CREATE TABLE `orders` (`note` varchar(20) DEFAULT 'a, (x) b')")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "dev"), target: snapshot([target], database: "test"))
        #expect(result.count == 1)
        #expect(result.first?.status == .modified)
        #expect(result.first?.sql == nil)
    }

    @Test func safeAdditionsUseActualTargetIdentity() throws {
        let source = try object("CREATE TABLE `Orders` (`id` int, `note` varchar(255) DEFAULT NULL COMMENT 'buyer note', KEY `idx_id` (`id`))", name: "Orders")
        let target = try object("CREATE TABLE `orders` (`id` int)", name: "orders")
        let result = try SchemaComparisonEngine.compare(
            source: snapshot([source], database: "dev", caseMode: 1),
            target: snapshot([target], database: "test`db", caseMode: 1)
        )
        let sql = result.compactMap(\.sql)
        #expect(sql.count == 2)
        #expect(sql.allSatisfy { $0.hasPrefix("ALTER TABLE `test``db`.`orders`") })
        #expect(sql.contains { $0.contains("COMMENT 'buyer note'") })
        #expect(sql.contains { $0.contains("ADD KEY `idx_id`") })
    }

    @Test(arguments: [
        "`x` int NOT NULL", "`x` int AUTO_INCREMENT", "`x` int GENERATED ALWAYS AS (`id` + 1) STORED",
        "`x` timestamp DEFAULT CURRENT_TIMESTAMP", "`x` int DEFAULT (rand())", "`x` varchar(5) DEFAULT 'NULL'",
        "`x` varchar(5) COLLATE utf8mb4_bin", "`x` geometry", "`x` int INVISIBLE", "`x` int PRIMARY KEY"
    ])
    func nonAdditiveOrDependentColumnsAreCompareOnly(_ definition: String) throws {
        let source = try object("CREATE TABLE `orders` (`id` int, \(definition))")
        let target = try object("CREATE TABLE `orders` (`id` int)")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "dev"), target: snapshot([target], database: "test"))
        #expect(result.filter { $0.status == .added }.count == 1)
        #expect(result.compactMap(\.sql).isEmpty)
    }

    @Test func indexDependingOnMissingColumnIsNotOfferedIndependently() throws {
        let source = try object("CREATE TABLE `orders` (`id` int, `note` varchar(20), KEY `idx_note` (`note`))")
        let target = try object("CREATE TABLE `orders` (`id` int)")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "dev"), target: snapshot([target], database: "test"))
        #expect(result.first { $0.object == "column:note" }?.sql != nil)
        #expect(result.first { $0.object == "index:idx_note" }?.sql == nil)
    }

    @Test func replacingAUniqueIndexWithANonUniqueIndexIsNotAnAddition() throws {
        let source = try object("CREATE TABLE `orders` (`id` int, KEY `idx` (`id`))")
        let target = try object("CREATE TABLE `orders` (`id` int, UNIQUE KEY `idx` (`id`))")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "dev"), target: snapshot([target], database: "test"))
        #expect(result.compactMap(\.sql).isEmpty)
    }

    @Test(arguments: ["KEY `idx` (`id` DESC)", "KEY `idx` (`id`(4))", "KEY `idx` ((abs(`id`)))", "UNIQUE KEY `idx` (`id`)"])
    func specialIndexesAreCompareOnly(_ definition: String) throws {
        let source = try object("CREATE TABLE `orders` (`id` int, \(definition))")
        let target = try object("CREATE TABLE `orders` (`id` int)")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "dev"), target: snapshot([target], database: "test"))
        #expect(result.compactMap(\.sql).isEmpty)
    }

    @Test func versionModeAndOptionDifferencesBlockExport() throws {
        let source = try object("CREATE TABLE `orders` (`id` int, `x` int) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
        let target = try object("CREATE TABLE `orders` (`id` int) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
        for t in [snapshot([target], database: "test", version: "5.7.44"),
                  snapshot([target], database: "test", sqlMode: "NO_BACKSLASH_ESCAPES"),
                  snapshot([target], database: "test", caseMode: 1)] {
            let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "dev"), target: t)
            #expect(result.compactMap(\.sql).isEmpty)
        }
        let otherCharset = try object("CREATE TABLE `orders` (`id` int) ENGINE=InnoDB DEFAULT CHARSET=latin1")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "dev"), target: snapshot([otherCharset], database: "test"))
        #expect(result.compactMap(\.sql).isEmpty)
        #expect(result.contains { $0.object == "options" })
    }

    @Test func failedMetadataIsNeverInterpretedAsDeletion() throws {
        let broken = SchemaComparisonSnapshot.Object(name: "orders", ddl: "", definition: nil, error: "permission denied")
        let valid = try object("CREATE TABLE `orders` (`id` int)")
        let result = try SchemaComparisonEngine.compare(source: snapshot([broken], database: "dev"), target: snapshot([valid], database: "test"))
        #expect(result.count == 1)
        #expect(result.first?.status == .unavailable)
        #expect(result.first?.explanation == "permission denied")
        #expect(result.first?.sql == nil)
    }

    @Test func partialFailureBlocksAllExportAndNewOrExtraTablesRemainVisible() throws {
        let source = try object("CREATE TABLE `orders` (`id` int, `x` int)")
        let target = try object("CREATE TABLE `orders` (`id` int)")
        let broken = SchemaComparisonSnapshot.Object(name: "unreadable", ddl: "", definition: nil, error: "denied")
        let extra = try object("CREATE TABLE `legacy` (`id` int)", name: "legacy")
        let added = try object("CREATE TABLE `new_table` (`id` int)", name: "new_table")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source, broken, added], database: "dev"), target: snapshot([target, extra], database: "test"))
        #expect(result.compactMap(\.sql).isEmpty)
        #expect(result.contains { $0.table == "legacy" && $0.status == .targetOnly })
        #expect(result.contains { $0.table == "new_table" && $0.status == .added })
    }

    @Test func sameDatabaseAcrossConnectionAliasesIsRejected() throws {
        #expect(throws: SchemaComparisonError.self) {
            try SchemaComparisonEngine.compare(source: snapshot([], database: "shop"), target: snapshot([], database: "shop"))
        }
    }

    @Test func caseSensitiveTablesRemainDistinct() throws {
        let source = try object("CREATE TABLE `Orders` (`id` int)", name: "Orders")
        let target = try object("CREATE TABLE `orders` (`id` int)", name: "orders")
        let result = try SchemaComparisonEngine.compare(source: snapshot([source], database: "dev"), target: snapshot([target], database: "test"))
        #expect(result.map(\.status).contains(.added))
        #expect(result.map(\.status).contains(.targetOnly))
        #expect(result.compactMap(\.sql).isEmpty)
    }

    @Test func quotedIdentifiersAndEscapedLiteralsAreNotSplit() throws {
        let definition = try MySQLSchemaDefinition(ddl: "CREATE TABLE `a.b` (`a``b` varchar(10) COMMENT 'it''s, (fine)', `c` int)")
        #expect(definition.parts.count == 2)
        #expect(definition.parts[0].name == "a`b")
        #expect(definition.parts[0].tokens.last == "'it''s, (fine)'")
    }

    @Test(arguments: ["CREATE VIEW x AS SELECT 1", "CREATE TABLE `x` (`a` int", "CREATE TABLE `x` (`a` text DEFAULT 'oops)", "CREATE TABLE `x` (`a` int /*!80023 INVISIBLE */)"])
    func incompleteOrUnknownDefinitionsCannotGenerateSQL(_ ddl: String) {
        #expect(throws: SchemaComparisonError.self) { try MySQLSchemaDefinition(ddl: ddl) }
    }

    @Test func anEmptyScopeIsSuccessfulAndHasNoStatements() throws {
        let result = try SchemaComparisonEngine.compare(source: snapshot([], database: "dev"), target: snapshot([], database: "test"))
        #expect(result.isEmpty)
    }
}


struct SchemaComparisonReviewGroupsTests {
    @Test func reviewGroupsTableChangesAndKeepsRoutineKindsSeparate() throws {
        func difference(_ id: String, _ name: String, _ object: String, _ status: SchemaComparisonDifference.Status, container: String? = nil, routine: String? = nil) -> SchemaComparisonDifference {
            .init(id: id, table: name, object: object, status: status, source: "source", target: "target", sourceDDL: "", targetDDL: "", sql: "SQL", explanation: "", routineType: routine, containerID: container)
        }
        let changes = [
            difference("email", "users", "column:email", .modified),
            difference("obsolete", "users", "column:obsolete", .targetOnly),
            difference("new_index", "users", "index:ux_email", .added),
            difference("create", "new_table", "table", .added),
            difference("drop", "old_table", "table", .targetOnly),
            difference("fn", "double_id", "function", .modified, container: "routine:FUNCTION:double_id", routine: "FUNCTION"),
            difference("proc", "double_id", "function", .modified, container: "routine:PROCEDURE:double_id", routine: "PROCEDURE")
        ]
        let groups = SchemaComparisonReviewGroup.groups(changes)
        #expect(groups.count == 5)
        let users = try #require(groups.first { $0.title == "users" })
        #expect(users.ids == ["email", "obsolete", "new_index"])
        #expect(users.status == .modified && users.symbol == "tablecells")
        #expect(groups.first?.status == .added && groups.last?.status == .targetOnly)
        let routines = groups.filter { $0.title == "double_id" }
        #expect(routines.count == 2 && Set(routines.compactMap(\.routineKind)).count == 2)
    }
}
