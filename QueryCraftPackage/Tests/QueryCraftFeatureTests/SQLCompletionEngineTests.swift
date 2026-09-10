import Foundation
import Testing
@testable import QueryCraftFeature

struct SQLCompletionEngineTests {
    @Test
    func completesStaticKeywordsFromAnIncompleteStatement() async throws {
        let result = try await completions(for: "sel")

        #expect(result.items.first?.label == "SELECT")
        #expect(result.items.first?.replacementRange == SQLSourceRange(location: 0, length: 3))
    }

    @Test
    func keepsDialectFunctionsOutOfTheOtherDatabase() async throws {
        let mysqlResult = try await completions(
            for: "SELECT group_c",
            databaseType: .mysql
        )
        let postgresqlResult = try await completions(
            for: "SELECT string_a",
            databaseType: .postgresql
        )
        let mysqlForPostgreSQLPrefix = try await optionalCompletions(
            for: "SELECT string_a",
            databaseType: .mysql
        )
        let postgresqlForMySQLPrefix = try await optionalCompletions(
            for: "SELECT group_c",
            databaseType: .postgresql
        )

        #expect(mysqlResult.items.first?.label == "GROUP_CONCAT")
        #expect(postgresqlResult.items.first?.label == "STRING_AGG")
        #expect(mysqlForPostgreSQLPrefix?.items.contains { $0.label == "STRING_AGG" } != true)
        #expect(postgresqlForMySQLPrefix?.items.contains { $0.label == "GROUP_CONCAT" } != true)
    }

    @Test
    func usesPostgreSQLPredicateAndTypeCandidatesOnlyForPostgreSQL() async throws {
        let predicate = try await completions(
            for: "SELECT * FROM users WHERE ili",
            defaultDatabase: "app",
            databaseType: .postgresql
        )
        let type = try await completions(
            for: "CREATE TABLE samples (payload jsonb",
            databaseType: .postgresql
        )
        let mysqlPredicate = try await optionalCompletions(
            for: "SELECT * FROM users WHERE ili",
            defaultDatabase: "app",
            databaseType: .mysql
        )
        let mysqlType = try await optionalCompletions(
            for: "CREATE TABLE samples (payload jsonb",
            databaseType: .mysql
        )

        #expect(predicate.items.first?.label == "ILIKE")
        #expect(type.items.first?.label == "JSONB")
        #expect(mysqlPredicate?.items.contains { $0.label == "ILIKE" } != true)
        #expect(mysqlType?.items.contains { $0.label == "JSONB" } != true)
    }

    @Test(arguments: ["version", "SELECT ver"])
    func completesVersionAsAFunctionInExpressionContexts(_ source: String) async throws {
        let result = try await completions(for: source)
        let item = try #require(result.items.first)

        #expect(item.label == "VERSION")
        #expect(item.insertionText == "VERSION()")
        #expect(item.kind == .function)
        #expect(item.cursorOffset == -1)
    }

    @Test
    func narrowsFromContextToObjectsInTheDefaultDatabase() async throws {
        let result = try await completions(
            for: "SELECT * FROM us",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "users")
        #expect(result.items.first?.kind == .table)
        #expect(!result.items.contains { $0.label == "SELECT" })
    }

    @Test
    func recoversRelationCompletionWhenTheSelectListIsMissing() async throws {
        let result = try await completions(
            for: "SELECT FROM adm",
            defaultDatabase: "test_estate_bus"
        )

        #expect(result.items.first?.label == "admin_area")
        #expect(result.items.first?.kind == .table)
    }

    @Test
    func recoversColumnsWhenTheSelectListIsMissing() async throws {
        let result = try await completions(
            for: "SELECT FROM users WHERE na",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "name")
        #expect(result.items.first?.kind == .column)
    }

    @Test
    func recoversUnqualifiedColumnsFromTheSelectedDatabase() async throws {
        let result = try await completions(
            for: "SELECT FROM admin_user WHERE use",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "user_id")
        #expect(result.items.first?.kind == .column)
        #expect(result.items.contains { $0.label == "user_name" })
        #expect(result.items.contains { $0.label == "usage_flag" } == false)
    }

    @Test
    func omitsColumnsForAnUnqualifiedRelationWithoutADefaultDatabase() async throws {
        let result = try await completions(
            for: "SELECT FROM admin_user WHERE wh"
        )

        #expect(result.items.contains { $0.label == "WHERE" })
        #expect(result.items.contains { $0.kind == .column } == false)
        #expect(result.referencedSchemaObjects.isEmpty)
    }

    @Test(arguments: ["users u", "users AS u"])
    func recoversAliasColumnsWhenTheSelectListIsMissing(
        _ relation: String
    ) async throws {
        let result = try await completions(
            for: "SELECT FROM \(relation) WHERE u.na",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "name")
        #expect(result.items.first?.kind == .column)
        #expect(result.items.first?.detail.contains("u · users") == true)
    }

    @Test
    func recoversJoinedAliasColumnsFromIncompleteSyntax() async throws {
        let result = try await completions(
            for: "SELECT FROM users u JOIN analytics.events e ON e.eve",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "event_id")
        #expect(result.items.first?.kind == .column)
        #expect(result.items.first?.detail.contains("e · events") == true)
    }

    @Test
    func recoversCommaSeparatedAliasColumnsFromIncompleteSyntax() async throws {
        let result = try await completions(
            for: "SELECT FROM users u, analytics.events e WHERE e.",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "event_id")
        #expect(result.items.first?.kind == .column)
        #expect(result.items.first?.detail.contains("e · events") == true)
    }

    @Test
    func fallsBackToSchemaCandidatesWhenTheRecognizedContextDoesNotMatch() async throws {
        let result = try await completions(
            for: "SELECT adm",
            defaultDatabase: "test_estate_bus"
        )

        #expect(result.items.first?.label == "admin_area")
        #expect(result.items.first?.kind == .table)
    }

    @Test
    func fallsBackToSchemaCandidatesInUnknownIncompleteSyntax() async throws {
        let result = try await completions(
            for: "BROKEN adm",
            defaultDatabase: "test_estate_bus"
        )

        #expect(result.items.first?.label == "admin_area")
        #expect(result.items.first?.kind == .table)
    }

    @Test(arguments: [
        "SELECT * WHERE adm",
        "SELECT * GROUP BY adm",
        "SELECT * ORDER BY adm",
    ])
    func fallsBackAcrossIncompleteClauseContexts(_ source: String) async throws {
        let result = try await completions(
            for: source,
            defaultDatabase: "test_estate_bus"
        )

        #expect(result.items.first?.label == "admin_area")
        #expect(result.items.first?.kind == .table)
    }

    @Test
    func keepsRecognizedContextAheadOfMatchingFallbackCandidates() async throws {
        let result = try await completions(
            for: "SELECT * FROM users wh",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "WHERE")
        #expect(result.items.first?.kind == .keyword)
        #expect(result.items.contains { $0.label == "where_archive" })
    }

    @Test
    func prioritizesDatabasesOverQualifiedObjectsWithoutADefaultDatabase() async throws {
        let result = try await completions(for: "SELECT * FROM te")

        #expect(result.items.first?.label == "test_estate_bus")
        #expect(result.items.first?.kind == .database)
        let databaseIndex = try #require(
            result.items.firstIndex { $0.label == "test_estate_bus" }
        )
        let objectIndex = try #require(
            result.items.firstIndex {
                $0.label == "test_estate_bus.admin_area"
            }
        )
        #expect(databaseIndex < objectIndex)
    }

    @Test(arguments: ["tau", "tead", "tuser"])
    func fuzzyMatchesLongUnderscoredObjectNames(_ prefix: String) async throws {
        let result = try await completions(
            for: "SELECT * FROM \(prefix)",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "test_admin_user")
        #expect(result.items.first?.kind == .table)
        #expect(
            result.items.first?.replacementRange.length
                == (prefix as NSString).length
        )
    }

    @Test
    func prioritizesFromOverFunctionsInTheSelectList() async throws {
        let result = try await completions(for: "SELECT * f")

        #expect(result.items.first?.label == "FROM")
        #expect(result.items.first?.kind == .keyword)
    }

    @Test
    func offersClausesInsteadOfTablesAfterACompletedRelation() async throws {
        let result = try await completions(
            for: "SELECT * FROM users ",
            defaultDatabase: "app"
        )

        #expect(result.items.contains { $0.label == "WHERE" })
        #expect(result.items.contains { $0.label == "ORDER BY" })
        #expect(result.items.contains { $0.label == "LIMIT" })
        #expect(result.items.contains { $0.kind == .table } == false)
    }

    @Test
    func prioritizesLimitAfterACompletedRelation() async throws {
        let result = try await completions(
            for: "SELECT * FROM users limi",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "LIMIT")
        #expect(result.items.allSatisfy { $0.kind == .keyword })
    }

    @Test
    func keepsRelationCandidatesAfterJoin() async throws {
        let result = try await completions(
            for: "SELECT * FROM users JOIN us",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "users")
        #expect(result.items.first?.kind == .table)
    }

    @Test
    func completesObjectsAfterADatabaseQualifier() async throws {
        let result = try await completions(
            for: "SELECT * FROM analytics.",
            defaultDatabase: "app"
        )

        #expect(result.items.map(\.label) == ["admin_user", "events"])
        #expect(result.items.first?.kind == .table)
        #expect(result.items.last?.kind == .view)
        #expect(result.items.first?.replacementRange.length == 0)
    }

    @Test
    func completesObjectsAfterAnUnderscoredDatabaseQualifier() async throws {
        let result = try await completions(
            for: "SELECT * FROM test_estate_bus.",
            defaultDatabase: "app"
        )

        #expect(result.items.map(\.label) == ["admin_area"])
        #expect(result.items.first?.kind == .table)
    }

    @Test
    func resolvesAliasColumnsWithinTheCurrentStatement() async throws {
        let initialSource = "SELECT u.id FROM app.users AS u;"
        let source = "SELECT u. FROM app.users AS u;"
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: initialSource)
        )
        let removedRange = (initialSource as NSString).range(of: "id")
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(2), text: source),
            applying: SQLSourceEdit(
                baseRevision: SQLSourceRevision(1),
                replacedRange: SQLSourceRange(removedRange),
                replacement: ""
            )
        )
        let result = try #require(
            try SQLCompletionEngine.completions(
                for: SQLCompletionEngine.Request(
                    source: SQLSourceSnapshot(
                        revision: SQLSourceRevision(2),
                        text: source
                    ),
                    cursorLocation: NSMaxRange((source as NSString).range(of: "u.")),
                    parseSnapshot: snapshot,
                    schemaCatalog: Self.catalog,
                    defaultDatabase: nil
                )
            )
        )

        #expect(result.items.map(\.label) == ["id", "name"])
        #expect(result.items.allSatisfy { $0.kind == .column })
        #expect(result.items.allSatisfy { $0.detail.contains("u · users") })
    }

    @Test
    func doesNotRequestColumnsForAnAmbiguousRelationWithoutADefaultDatabase() async throws {
        let source = "SELECT FROM admin_user WHERE wh"
        let catalog = WorkspaceSchemaCatalogSnapshot(
            revision: 1,
            databases: ["app", "analytics"].map { databaseName in
                WorkspaceSchemaDatabase(
                    name: databaseName,
                    objects: [
                        WorkspaceSchemaObject(
                            name: "admin_user",
                            kind: .table,
                            columns: []
                        )
                    ]
                )
            }
        )
        let result = try await completions(for: source, catalog: catalog)

        #expect(result.referencedSchemaObjects.isEmpty)
    }

    @Test
    func requestsOnlyTheDefaultDatabaseRelationColumns() async throws {
        let source = "SELECT FROM admin_user WHERE use"
        let catalog = WorkspaceSchemaCatalogSnapshot(
            revision: 1,
            databases: ["app", "analytics"].map { databaseName in
                WorkspaceSchemaDatabase(
                    name: databaseName,
                    objects: [
                        WorkspaceSchemaObject(
                            name: "admin_user",
                            kind: .table,
                            columns: []
                        )
                    ]
                )
            }
        )
        let result = try await completions(
            for: source,
            catalog: catalog,
            defaultDatabase: "analytics"
        )

        #expect(
            result.referencedSchemaObjects == [
                WorkspaceSchemaObjectReference(
                    databaseName: "analytics",
                    objectName: "admin_user"
                )
            ]
        )
    }

    @Test
    func requestsOnlyAnExplicitlyQualifiedRelation() async throws {
        let source = "SELECT FROM analytics.admin_user WHERE use"
        let catalog = WorkspaceSchemaCatalogSnapshot(
            revision: 1,
            databases: ["app", "analytics"].map { databaseName in
                WorkspaceSchemaDatabase(
                    name: databaseName,
                    objects: [
                        WorkspaceSchemaObject(
                            name: "admin_user",
                            kind: .table,
                            columns: []
                        )
                    ]
                )
            }
        )
        let result = try await completions(
            for: source,
            catalog: catalog,
            defaultDatabase: "app"
        )

        #expect(
            result.referencedSchemaObjects == [
                WorkspaceSchemaObjectReference(
                    databaseName: "analytics",
                    objectName: "admin_user"
                )
            ]
        )
    }

    @Test
    func aliasColumnsRankBeforeGeneralKeywords() async throws {
        let result = try await completions(
            for: "SELECT * FROM app.users AS u WHERE na",
            cursorToken: "na"
        )

        #expect(result.items.first?.label == "name")
        #expect(result.items.first?.kind == .column)
    }

    @Test
    func keepsContextualColumnsAheadOfFallbackTables() async throws {
        let predicate = try await completions(
            for: "SELECT * FROM app.users AS u WHERE na",
            cursorToken: "na"
        )
        let ordering = try await completions(
            for: "SELECT * FROM app.users AS u ORDER BY na",
            cursorToken: "na"
        )

        #expect(predicate.items.first?.label == "name")
        #expect(ordering.items.first?.label == "name")
        let predicateTableIndex = try #require(
            predicate.items.firstIndex { $0.kind == .table }
        )
        let orderingTableIndex = try #require(
            ordering.items.firstIndex { $0.kind == .table }
        )
        #expect(predicateTableIndex > 0)
        #expect(orderingTableIndex > 0)
    }

    @Test
    func prefixKeywordRanksBeforeFuzzyColumnMatches() async throws {
        let catalog = WorkspaceSchemaCatalogSnapshot(
            revision: 1,
            databases: [
                WorkspaceSchemaDatabase(
                    name: "app",
                    objects: [
                        WorkspaceSchemaObject(
                            name: "admin_user",
                            kind: .table,
                            columns: [
                                WorkspaceSchemaColumn(
                                    name: "wechat_code",
                                    type: "varchar(255)",
                                    ordinalPosition: 1
                                ),
                                WorkspaceSchemaColumn(
                                    name: "new_house_bank",
                                    type: "varchar(255)",
                                    ordinalPosition: 2
                                ),
                            ]
                        )
                    ]
                )
            ]
        )
        let result = try await completions(
            for: "SELECT from admin_user wh",
            catalog: catalog,
            defaultDatabase: "app"
        )
        let whereIndex = try #require(
            result.items.firstIndex { $0.label == "WHERE" }
        )
        let firstColumnIndex = try #require(
            result.items.firstIndex { $0.kind == .column }
        )

        #expect(whereIndex < firstColumnIndex)
    }

    @Test
    func keepsShowingAfterAnUnambiguousExactIdentifierIsTyped() async throws {
        let result = try await completions(
            for: "SELECT * FROM app.users AS u ORDER BY id",
            cursorToken: "id"
        )

        #expect(result.items.first?.label == "id")
    }

    @Test
    func keepsShowingExactKeywordWhenAcceptanceNormalizesCase() async throws {
        let result = try await completions(for: "SELECT * from")
        let item = try #require(
            result.items.first { $0.label == "FROM" }
        )

        #expect(item.insertionText == "FROM")
        #expect(item.replacementRange.length == 4)
    }

    @Test
    func keepsShowingWhenAnExactIdentifierHasALongerPrefixCandidate() async throws {
        let result = try await completions(
            for: "SELECT * FROM test_admin_user",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "test_admin_user")
        #expect(result.items.contains { $0.label == "test_admin_users" })
    }

    @Test(arguments: [
        """
        SELECT user_phone
        FROM admin_user
        WHERE user_phone IS NOT NULL

        un
        """,
        """
        (
            SELECT 'VALUE' AS data_type, user_phone
            FROM admin_user
            WHERE user_phone IS NOT NULL
                AND user_phone <> ''
            LIMIT 10
        )
        un
        """,
    ])
    func prioritizesSetOperationsAfterACompleteQuery(
        _ source: String
    ) async throws {
        let result = try await completions(
            for: source,
            defaultDatabase: "test_estate_bus"
        )

        #expect(
            Array(result.items.prefix(2).map(\.label))
                == ["UNION", "UNION ALL"]
        )
    }

    @Test
    func keepsFunctionPriorityInsideASelectExpression() async throws {
        let result = try await completions(
            for: """
            SELECT un
            FROM admin_user
            WHERE user_phone IS NOT NULL

            un

            SELECT user_phone
            FROM admin_user
            WHERE user_phone IS NULL
            ORDER BY user_phone
            LIMIT 20;
            """,
            cursorToken: "un",
            defaultDatabase: "test_estate_bus"
        )

        #expect(result.items.first?.label == "UNCOMPRESS")
        #expect(result.items.first?.kind == .function)
    }

    @Test
    func prioritizesIntoAfterACompleteSelectExpression() async throws {
        let result = try await completions(
            for: """
            SELECT user_phone
            int
            """,
            defaultDatabase: "test_estate_bus"
        )

        #expect(result.items.first?.label == "INTO")
        #expect(result.items.first?.kind == .keyword)
    }

    @Test
    func completesSetOperationOutputColumnsInTheFinalOrderBy() async throws {
        let result = try await completions(
            for: """
            SELECT name AS name_label
            FROM users
            UNION ALL
            SELECT name AS name_label
            FROM users
            ORDER BY na
            LIMIT 20;
            """,
            cursorToken: "ORDER BY na",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "name_label")
        #expect(result.items.first?.kind == .queryOutput)
        #expect(result.items.contains { $0.label == "name" } == false)
    }

    @Test
    func catalogCoversMySQL57Through84WithoutDuplicateEntries() {
        #expect(SQLStaticCatalog.mysqlKeywords.count == 765)
        #expect(Set(SQLStaticCatalog.keywords).count == SQLStaticCatalog.keywords.count)
        #expect(
            Set(SQLStaticCatalog.builtInFunctions).count
                == SQLStaticCatalog.builtInFunctions.count
        )
        #expect(SQLStaticCatalog.builtInFunctions.contains("VERSION"))

        for keyword in [
            "SELECT", "INTO", "WITH", "RECURSIVE", "WINDOW", "OVER",
            "UNION", "SAVEPOINT", "CONSTRAINT", "REFERENCES", "FULLTEXT",
            "CALL", "LOAD", "GRANT", "OPTIMIZE", "SOURCE", "MASTER",
            "TEMPORARY", "JSON_TABLE", "QUALIFY",
        ] {
            #expect(SQLStaticCatalog.keywords.contains(keyword))
        }
        for phrase in [
            "START TRANSACTION", "UNION ALL", "FOREIGN KEY",
            "ON DUPLICATE KEY UPDATE", "LOCK IN SHARE MODE",
        ] {
            #expect(SQLStaticCatalog.keywords.contains(phrase))
        }
        let unionIndex = SQLStaticCatalog.keywords.firstIndex(of: "UNION")
        #expect(unionIndex != nil)
        if let unionIndex {
            #expect(SQLStaticCatalog.keywords[unionIndex + 1] == "UNION ALL")
        }

        let allKeywords = Set(SQLStaticCatalog.keywords)
        let contextualKeywords = [
            SQLStaticCatalog.statementKeywords,
            SQLStaticCatalog.insertKeywords,
            SQLStaticCatalog.insertBodyKeywords,
            SQLStaticCatalog.updateBodyKeywords,
            SQLStaticCatalog.assignmentKeywords,
            SQLStaticCatalog.deleteKeywords,
            SQLStaticCatalog.ddlObjectTypeKeywords,
            SQLStaticCatalog.ddlObjectTypeKeywordsWithTemporary,
            SQLStaticCatalog.ddlBodyKeywords,
            SQLStaticCatalog.selectListKeywords,
            SQLStaticCatalog.postRelationKeywords,
            SQLStaticCatalog.postJoinRelationKeywords,
            SQLStaticCatalog.setOperationKeywords,
            SQLStaticCatalog.predicateKeywords,
            SQLStaticCatalog.groupingKeywords,
            SQLStaticCatalog.orderingKeywords,
        ]
        #expect(contextualKeywords.allSatisfy { Set($0).isSubset(of: allKeywords) })
    }

    @Test
    func contextualRankingGroupPrecedesAStrongerFallbackMatch() throws {
        let contextual = SQLCompletionCandidate(
            label: "WHERE",
            insertionText: "WHERE",
            detail: "keyword",
            kind: .keyword,
            rankingGroup: 0,
            contextPriority: 0,
            cursorOffset: 0
        )
        let fallback = SQLCompletionCandidate(
            label: "WR",
            insertionText: "WR",
            detail: "keyword",
            kind: .keyword,
            rankingGroup: 1,
            contextPriority: 0,
            cursorOffset: 0
        )

        let items = try SQLCompletionRanker.rank(
            [fallback, contextual],
            prefix: "wr",
            replacementRange: SQLSourceRange(location: 0, length: 2),
            revision: SQLSourceRevision(1),
            limit: 10
        )

        #expect(items.map(\.label) == ["WHERE", "WR"])
    }

    @Test(arguments: [
        ("SELECT into", "INTO"),
        ("SELECT recur", "RECURSIVE"),
        ("SELECT savep", "SAVEPOINT"),
        ("SELECT json_t", "JSON_TABLE"),
    ])
    func keepsEveryMySQLKeywordInTheGeneralFallback(
        source: String,
        expected: String
    ) async throws {
        let result = try await completions(for: source)

        #expect(result.items.contains { item in
            item.label == expected && item.kind == .keyword
        })
    }

    @Test(arguments: [
        ("ins", "INSERT"),
        ("upd", "UPDATE"),
        ("del", "DELETE"),
        ("cre", "CREATE"),
        ("alt", "ALTER"),
        ("dro", "DROP"),
        ("tru", "TRUNCATE"),
    ])
    func completesWriteKeywordsAtStatementStart(
        source: String,
        expected: String
    ) async throws {
        let result = try await completions(for: source)

        #expect(result.items.first?.label == expected)
        #expect(result.items.first?.kind == .keyword)
    }

    @Test
    func completesInsertIntroducer() async throws {
        let result = try await completions(for: "INSERT ")

        #expect(result.items.first?.label == "INTO")
    }

    @Test
    func completesInsertTarget() async throws {
        let result = try await completions(
            for: "INSERT INTO us",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "users")
        #expect(result.items.first?.kind == .table)
    }

    @Test
    func completesInsertColumns() async throws {
        let result = try await completions(
            for: "INSERT INTO users (na",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "name")
        #expect(result.items.first?.kind == .column)
    }

    @Test
    func completesUpdateTargetAndAssignments() async throws {
        let table = try await completions(
            for: "UPDATE us",
            defaultDatabase: "app"
        )
        let set = try await completions(
            for: "UPDATE users SE",
            defaultDatabase: "app"
        )
        let column = try await completions(
            for: "UPDATE users SET na",
            defaultDatabase: "app"
        )

        #expect(table.items.first?.label == "users")
        #expect(table.items.first?.kind == .table)
        #expect(set.items.first?.label == "SET")
        #expect(column.items.first?.label == "name")
        #expect(column.items.first?.kind == .column)
    }

    @Test
    func completesDeleteIntroducer() async throws {
        let result = try await completions(for: "DELETE ")

        #expect(result.items.first?.label == "FROM")
    }

    @Test
    func completesDeletePredicateColumns() async throws {
        let result = try await completions(
            for: "DELETE FROM users WHERE na",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "name")
        #expect(result.items.first?.kind == .column)
    }

    @Test
    func completesDDLObjectType() async throws {
        let result = try await completions(for: "ALTER TA")

        #expect(result.items.first?.label == "TABLE")
    }

    @Test(arguments: ["CREATE tempo", "DROP tempo"])
    func completesTemporaryTableModifier(_ source: String) async throws {
        let result = try await completions(for: source)

        #expect(result.items.first?.label == "TEMPORARY")
        #expect(result.items.first?.kind == .keyword)
    }

    @Test(arguments: ["CREATE TEMPORARY ta", "DROP TEMPORARY ta"])
    func completesDDLObjectTypeAfterTemporary(_ source: String) async throws {
        let result = try await completions(for: source)

        #expect(result.items.first?.label == "TABLE")
        #expect(result.items.first?.kind == .keyword)
    }

    @Test
    func keepsTemporaryInTheGeneralKeywordFallback() async throws {
        let result = try await completions(for: "SELECT tempo")

        #expect(result.items.contains { item in
            item.label == "TEMPORARY" && item.kind == .keyword
        })
    }

    @Test(arguments: [
        "ALTER TABLE us",
        "DROP TABLE us",
        "TRUNCATE TABLE us",
    ])
    func completesExistingDDLObjectTargets(_ source: String) async throws {
        let result = try await completions(
            for: source,
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "users")
        #expect(result.items.first?.kind == .table)
    }

    @Test
    func aliasesDoNotLeakAcrossStatements() async throws {
        let source = "SELECT * FROM analytics.events AS e; SELECT na FROM app.users AS u;"
        let result = try await completions(
            for: source,
            cursorToken: "SELECT na"
        )

        #expect(result.items.first?.label == "name")
        #expect(result.items.contains { $0.label == "event_id" } == false)
    }

    @Test
    func resolvesCorrelatedAliasesWithoutLeakingSiblingSubqueries() async throws {
        let source = """
        SELECT u.id
        FROM app.users AS u
        WHERE EXISTS (
            SELECT 1 FROM analytics.events AS e
            WHERE e.event_id = u.na
        )
        AND EXISTS (
            SELECT 1 FROM analytics.admin_user AS other
            WHERE other.usage_flag = 1
        )
        """
        let result = try await completions(
            for: source,
            cursorToken: "u.na",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "name")
        #expect(result.items.contains { $0.label == "usage_flag" } == false)
    }

    @Test
    func onlyLateralDerivedTablesSeeOuterRelationAliases() async throws {
        let ordinary = try await completions(
            for: """
            SELECT *
            FROM app.users AS u
            JOIN (
                SELECT e.event_id FROM analytics.events AS e
                WHERE e.event_id = u.na
            ) AS d ON TRUE
            """,
            cursorToken: "u.na",
            defaultDatabase: "app"
        )
        let lateral = try await completions(
            for: """
            SELECT *
            FROM app.users AS u
            JOIN LATERAL (
                SELECT e.event_id FROM analytics.events AS e
                WHERE e.event_id = u.na
            ) AS d ON TRUE
            """,
            cursorToken: "u.na",
            defaultDatabase: "app"
        )

        #expect(ordinary.items.contains { $0.label == "name" } == false)
        #expect(lateral.items.first?.label == "name")
    }

    @Test
    func completesCTERelationsAndDeclaredOutputColumns() async throws {
        let relationSource = """
            WITH recent (user_id) AS (
                SELECT event_id FROM analytics.events
            )
            SELECT * FROM rec
            """
        let relationSnapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(
                revision: SQLSourceRevision(1),
                text: relationSource
            )
        )
        #expect(relationSnapshot.queryScopes.first?.syntheticRelations.contains {
            $0.name == "recent" && $0.outputColumnNames == ["user_id"]
        } == true)
        let relation = try await completions(
            for: relationSource,
            cursorToken: "SELECT * FROM rec",
            defaultDatabase: "app"
        )
        let column = try await completions(
            for: """
            WITH recent (user_id) AS (
                SELECT event_id FROM analytics.events
            )
            SELECT * FROM recent AS r WHERE r.us
            """,
            cursorToken: "r.us",
            defaultDatabase: "app"
        )

        #expect(relation.items.first?.label == "recent")
        #expect(column.items.first?.label == "user_id")
        #expect(column.referencedSchemaObjects.contains {
            $0.objectName == "recent"
        } == false)
    }

    @Test
    func completesDerivedTableProjectedColumns() async throws {
        let result = try await completions(
            for: """
            SELECT *
            FROM (
                SELECT event_id FROM analytics.events
            ) AS d
            WHERE d.ev
            """,
            cursorToken: "d.ev",
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "event_id")
        #expect(result.referencedSchemaObjects.contains {
            $0.objectName == "d"
        } == false)
    }

    @Test
    func completesCTEProjectedColumnsInTheSelectListBeforeFrom() async throws {
        let result = try await completions(
            for: """
            WITH u AS (
                SELECT user_phone AS phone
                FROM admin_user
            )
            SELECT u.
            FROM u;
            """,
            cursorToken: "SELECT u.",
            defaultDatabase: "app"
        )

        #expect(result.items.map(\.label) == ["phone"])
        #expect(result.items.allSatisfy { $0.kind == .column })
        #expect(result.items.allSatisfy { $0.detail == "query output · u" })
    }

    @Test
    func completesDerivedTableProjectedColumnsInTheSelectListBeforeFrom() async throws {
        let source = """
        SELECT d.
        FROM (
            SELECT user_phone AS phone
            FROM admin_user
        ) AS d;
        """
        let revision = SQLSourceRevision(1)
        let cursorLocation = NSMaxRange((source as NSString).range(of: "SELECT d."))
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: revision, text: source)
        )
        let path = snapshot.queryScopePath(atUTF16Location: cursorLocation)
        let optionalResult = try SQLCompletionEngine.completions(
            for: SQLCompletionEngine.Request(
                source: SQLSourceSnapshot(revision: revision, text: source),
                cursorLocation: cursorLocation,
                parseSnapshot: snapshot,
                schemaCatalog: Self.catalog,
                defaultDatabase: "app"
            )
        )
        let result = try #require(optionalResult)

        #expect(snapshot.statements.map(\.kind) == [.read])
        #expect(snapshot.queryScopes.count == 1)
        #expect(path.map(\.kind) == [.statement])
        let syntheticRelations = path.flatMap(\.syntheticRelations)
        #expect(syntheticRelations.count == 1)
        let derived = try #require(syntheticRelations.first)
        #expect(derived.kind == .derivedTable)
        #expect(derived.alias == "d")
        #expect(derived.outputColumnNames == ["phone"])
        #expect(result.items.map(\.label) == ["phone"])
        #expect(result.items.allSatisfy { $0.kind == .column })
        #expect(result.items.allSatisfy { $0.detail == "query output · d" })
    }

    @Test
    func completesBareDerivedTableColumnsFromTheScreenshotQuery() async throws {
        let source = """
            SELECT * FROM (
                SELECT
                    user_phone,
                    COUNT(1) AS c
                FROM admin_user
                GROUP BY user_phone
            ) a
            WHERE a.
            """
        let result = try await completions(
            for: source,
            cursorToken: "WHERE a.",
            defaultDatabase: "app"
        )

        #expect(Set(result.items.map(\.label)) == ["user_phone", "c"])
        #expect(result.items.allSatisfy { $0.kind == .column })
        #expect(result.referencedSchemaObjects.contains {
            $0.objectName == "a"
        } == false)
    }

    @Test
    func appliesCompletionPoliciesForEachMySQLCommentKind() async throws {
        #expect(
            try await optionalCompletions(
                for: "SELECT # sel\n* FROM users",
                cursorToken: "sel"
            ) == nil
        )
        let hint = try await completions(
            for: "SELECT /*+ MAX_ */ * FROM app.users AS u",
            cursorToken: "MAX_",
            defaultDatabase: "app"
        )
        let hintAlias = try await completions(
            for: "SELECT /*+ u */ * FROM app.users AS u",
            cursorToken: "/*+ u",
            defaultDatabase: "app"
        )
        let executable = try await completions(
            for: "/*!80000 SEL */;",
            cursorToken: "SEL"
        )

        #expect(hint.items.first?.label == "MAX_EXECUTION_TIME")
        #expect(hintAlias.items.first?.label == "u")
        #expect(executable.items.first?.label == "SELECT")
    }

    @Test
    func doesNotCompleteInsideStringsOrComments() async throws {
        #expect(try await optionalCompletions(for: "SELECT 'sel'") == nil)
        #expect(try await optionalCompletions(for: "SELECT 1 -- sel") == nil)
        #expect(try await optionalCompletions(for: "SELECT 1 /* sel */") == nil)
    }

    @Test
    func rejectsAMismatchedParseRevision() async throws {
        let source = "sel"
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )
        let result = try SQLCompletionEngine.completions(
            for: SQLCompletionEngine.Request(
                source: SQLSourceSnapshot(
                    revision: SQLSourceRevision(2),
                    text: source
                ),
                cursorLocation: (source as NSString).length,
                parseSnapshot: snapshot,
                schemaCatalog: Self.catalog,
                defaultDatabase: "app"
            )
        )

        #expect(result == nil)
    }

    @Test
    func capsLargeCatalogResultsAndCompletesOnTheWorker() async throws {
        let objectCount = 25_000
        let catalog = WorkspaceSchemaCatalogSnapshot(
            revision: 1,
            databases: [
                WorkspaceSchemaDatabase(
                    name: "app",
                    objects: (0..<objectCount).map { index in
                        WorkspaceSchemaObject(
                            name: "object_\(index)",
                            kind: .table,
                            columns: []
                        )
                    }
                )
            ]
        )
        let request = try await completionRequest(
            source: "SELECT * FROM object_",
            catalog: catalog,
            defaultDatabase: "app"
        )
        let worker = SQLCompletionWorker()
        let clock = ContinuousClock()
        let start = clock.now

        let result = try #require(try await worker.completions(for: request))
        let duration = start.duration(to: clock.now)

        #expect(result.items.count == 200)
        #expect(result.items.allSatisfy { $0.kind == .table })
        #expect(duration < .seconds(10))
    }

    @Test
    func cancelledLargeCatalogWorkStopsCooperatively() async throws {
        let catalog = WorkspaceSchemaCatalogSnapshot(
            revision: 1,
            databases: [
                WorkspaceSchemaDatabase(
                    name: "app",
                    objects: (0..<50_000).map { index in
                        WorkspaceSchemaObject(
                            name: "object_\(index)",
                            kind: .table,
                            columns: []
                        )
                    }
                )
            ]
        )
        let request = try await completionRequest(
            source: "SELECT * FROM object_",
            catalog: catalog,
            defaultDatabase: "app"
        )
        let worker = SQLCompletionWorker()
        let task = Task<SQLCompletionResult?, Error> {
            try await worker.completions(for: request)
        }

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled completion work unexpectedly returned a result")
        } catch is CancellationError {
            // Expected cooperative cancellation.
        }
    }

    private func completions(
        for source: String,
        cursorToken: String? = nil,
        catalog: WorkspaceSchemaCatalogSnapshot = Self.catalog,
        defaultDatabase: String? = nil,
        databaseType: DatabaseType = .mysql
    ) async throws -> SQLCompletionResult {
        try #require(
            await optionalCompletions(
                for: source,
                cursorToken: cursorToken,
                catalog: catalog,
                defaultDatabase: defaultDatabase,
                databaseType: databaseType
            )
        )
    }

    private func optionalCompletions(
        for source: String,
        cursorToken: String? = nil,
        catalog: WorkspaceSchemaCatalogSnapshot = Self.catalog,
        defaultDatabase: String? = nil,
        databaseType: DatabaseType = .mysql
    ) async throws -> SQLCompletionResult? {
        let revision = SQLSourceRevision(1)
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: revision, text: source)
        )
        let cursorLocation: Int
        if let cursorToken {
            let range = (source as NSString).range(of: cursorToken)
            cursorLocation = try #require(
                range.location == NSNotFound ? nil : NSMaxRange(range)
            )
        } else {
            cursorLocation = (source as NSString).length
        }
        let result = try SQLCompletionEngine.completions(
            for: SQLCompletionEngine.Request(
                source: SQLSourceSnapshot(revision: revision, text: source),
                cursorLocation: cursorLocation,
                parseSnapshot: snapshot,
                schemaCatalog: catalog,
                defaultDatabase: defaultDatabase,
                databaseType: databaseType
            )
        )
        return result
    }

    private func completionRequest(
        source: String,
        catalog: WorkspaceSchemaCatalogSnapshot,
        defaultDatabase: String?
    ) async throws -> SQLCompletionEngine.Request {
        let revision = SQLSourceRevision(1)
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: revision, text: source)
        )
        return SQLCompletionEngine.Request(
            source: SQLSourceSnapshot(revision: revision, text: source),
            cursorLocation: (source as NSString).length,
            parseSnapshot: snapshot,
            schemaCatalog: catalog,
            defaultDatabase: defaultDatabase
        )
    }

    private static let catalog = WorkspaceSchemaCatalogSnapshot(
        revision: 1,
        databases: [
            WorkspaceSchemaDatabase(
                name: "app",
                objects: [
                    WorkspaceSchemaObject(
                        name: "users",
                        kind: .table,
                        columns: [
                            WorkspaceSchemaColumn(
                                name: "id",
                                type: "bigint",
                                ordinalPosition: 1
                            ),
                            WorkspaceSchemaColumn(
                                name: "name",
                                type: "varchar(255)",
                                ordinalPosition: 2
                            ),
                        ]
                    ),
                    WorkspaceSchemaObject(
                        name: "admin_user",
                        kind: .table,
                        columns: [
                            WorkspaceSchemaColumn(
                                name: "user_id",
                                type: "bigint",
                                ordinalPosition: 1
                            ),
                            WorkspaceSchemaColumn(
                                name: "user_name",
                                type: "varchar(255)",
                                ordinalPosition: 2
                            ),
                        ]
                    ),
                    WorkspaceSchemaObject(
                        name: "test_admin_user",
                        kind: .table,
                        columns: []
                    ),
                    WorkspaceSchemaObject(
                        name: "test_admin_users",
                        kind: .table,
                        columns: []
                    ),
                    WorkspaceSchemaObject(
                        name: "where_archive",
                        kind: .table,
                        columns: []
                    ),
                ]
            ),
            WorkspaceSchemaDatabase(
                name: "analytics",
                objects: [
                    WorkspaceSchemaObject(
                        name: "events",
                        kind: .view,
                        columns: [
                            WorkspaceSchemaColumn(
                                name: "event_id",
                                type: "bigint",
                                ordinalPosition: 1
                            )
                        ]
                    ),
                    WorkspaceSchemaObject(
                        name: "admin_user",
                        kind: .table,
                        columns: [
                            WorkspaceSchemaColumn(
                                name: "usage_flag",
                                type: "tinyint",
                                ordinalPosition: 1
                            )
                        ]
                    )
                ]
            ),
            WorkspaceSchemaDatabase(
                name: "test_estate_bus",
                objects: [
                    WorkspaceSchemaObject(
                        name: "admin_area",
                        kind: .table,
                        columns: []
                    )
                ]
            ),
        ]
    )
}
