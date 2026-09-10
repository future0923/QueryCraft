import Foundation
import Testing
import CodeEditLanguages
@testable import QueryCraftFeature

struct SQLStructuralParserTests {
    @Test
    func packagedSQLHighlightQueryIsAvailable() throws {
        let queryURL = try #require(CodeLanguage.sql.queryURL(for: "highlights"))

        #expect(FileManager.default.fileExists(atPath: queryURL.path))
        #expect(try String(contentsOf: queryURL, encoding: .utf8).isEmpty == false)
    }

    @Test
    func parsesReliableStatementsAndIncludesTheirSemicolons() async throws {
        let source = "SELECT 1;\n\nSELECT 'semi;colon';"
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )

        #expect(snapshot.isReliable)
        #expect(snapshot.statements.count == 2)
        #expect(snapshot.changedRanges == [SQLSourceRange(location: 0, length: (source as NSString).length)])
        #expect(statementText(snapshot.statements[0], in: source) == "SELECT 1;")
        #expect(statementText(snapshot.statements[1], in: source) == "SELECT 'semi;colon';")
    }

    @Test
    func resolvesSemicolonAndInterstitialWhitespacePredictably() async throws {
        let source = "SELECT 1;\n-- next\nSELECT 2;"
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )

        let firstEnd = try #require(source.range(of: ";"))
        let firstEndLocation = source.utf16.distance(
            from: source.utf16.startIndex,
            to: firstEnd.upperBound.samePosition(in: source.utf16)!
        )
        #expect(snapshot.statement(atUTF16Location: firstEndLocation, in: source) == snapshot.statements[0])

        let commentLocation = (source as NSString).range(of: "next").location
        #expect(snapshot.statement(atUTF16Location: commentLocation, in: source) == snapshot.statements[1])
    }

    @Test
    func retainsAStatementBoundaryAcrossPinnedGrammarDiagnostics() async throws {
        let source = "SELECT * FROM users LIMIT 10, 20;"
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )

        #expect(!snapshot.isReliable)
        #expect(snapshot.statements.map(\.kind) == [.read])
        #expect(snapshot.unreliableStatementRanges.isEmpty)
        #expect(snapshot.statement(atUTF16Location: 5, in: source)?.range ==
            SQLSourceRange(location: 0, length: (source as NSString).length))
    }

    @Test
    func appliesAValidatedIncrementalEdit() async throws {
        let parser = try SQLStructuralParser()
        let firstSource = "SELECT 1;"
        _ = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: firstSource)
        )

        let secondSource = "SELECT 12;"
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(2), text: secondSource),
            applying: SQLSourceEdit(
                baseRevision: SQLSourceRevision(1),
                replacedRange: SQLSourceRange(location: 8, length: 0),
                replacement: "2"
            )
        )

        #expect(snapshot.mode == .incremental)
        #expect(snapshot.isReliable)
        #expect(statementText(snapshot.statements[0], in: secondSource) == secondSource)
    }

    @Test
    func recognizesTransactionStatementsAfterIncrementalTyping() async throws {
        for expectedSource in [
            "BEGIN;", "COMMIT;", "ROLLBACK;", "START TRANSACTION;",
            "SAVEPOINT before_update;",
            "ROLLBACK TO SAVEPOINT before_update;",
            "RELEASE SAVEPOINT before_update;",
        ] {
            let parser = try SQLStructuralParser()
            var source = ""
            var revision = SQLSourceRevision(1)
            _ = try await parser.parse(
                SQLSourceSnapshot(revision: revision, text: source)
            )

            var finalSnapshot: SQLParseSnapshot?
            for character in expectedSource {
                let previousLength = (source as NSString).length
                source.append(character)
                let nextRevision = SQLSourceRevision(revision.rawValue + 1)
                finalSnapshot = try await parser.parse(
                    SQLSourceSnapshot(revision: nextRevision, text: source),
                    applying: SQLSourceEdit(
                        baseRevision: revision,
                        replacedRange: SQLSourceRange(
                            location: previousLength,
                            length: 0
                        ),
                        replacement: String(character)
                    )
                )
                revision = nextRevision
            }

            let snapshot = try #require(finalSnapshot)
            #expect(snapshot.mode == .incremental)
            #expect(snapshot.isReliable)
            #expect(snapshot.statements.count == 1)
            let statement = try #require(snapshot.statements.first)
            #expect(
                statementText(statement, in: source) == expectedSource
            )
        }
    }

    @Test
    func separatesAdjacentTransactionCommandsAtDirectSemicolonBoundaries() async throws {
        let source = "BEGIN;\n\nROLLBACK;"
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(
                revision: SQLSourceRevision(1),
                text: source
            )
        )
        #expect(snapshot.statements.map(\.kind) == [
            .transaction(.begin),
            .transaction(.rollback),
        ])
        #expect(snapshot.statements.map { statementText($0, in: source) } == [
            "BEGIN;",
            "\n\nROLLBACK;",
        ])
    }

    @Test
    func separatesSavepointsFromTheSurroundingTransactionBatch() async throws {
        let source = """
        START TRANSACTION;

        UPDATE admin_user
        SET user_phone = 'savepoint_test'
        WHERE id = 1;

        SAVEPOINT before_rollback;

        UPDATE admin_user
        SET user_phone = 'changed_again'
        WHERE id = 1;

        ROLLBACK TO SAVEPOINT before_rollback;

        SELECT id, user_phone
        FROM admin_user
        WHERE id = 1;

        ROLLBACK;
        """
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(
                revision: SQLSourceRevision(1),
                text: source
            )
        )

        #expect(snapshot.unreliableStatementRanges.isEmpty, "\(snapshot.syntaxTree)")
        #expect(snapshot.statements.map(\.kind) == [
            .transaction(.begin),
            .update(hasWhereClause: true),
            .transaction(.savepoint),
            .update(hasWhereClause: true),
            .transaction(.savepoint),
            .read,
            .transaction(.rollback),
        ])
        let savepoint = try #require(snapshot.statements.dropFirst(2).first)
        #expect(
            statementText(savepoint, in: source)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "SAVEPOINT before_rollback;"
        )
    }

    @Test
    func keepsUnknownTopLevelSemicolonSegmentsExecutable() async throws {
        let source = """
        SELECT 1;
        SERVER_SPECIFIC SYNTAX;
        SELECT 2;
        """
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(
                revision: SQLSourceRevision(1),
                text: source
            )
        )

        #expect(snapshot.statements.map(\.kind) == [.read, .unknown, .read])
        #expect(snapshot.unreliableStatementRanges.isEmpty)
        #expect(
            snapshot.statements.map {
                statementText($0, in: source)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } == [
                "SELECT 1;",
                "SERVER_SPECIFIC SYNTAX;",
                "SELECT 2;",
            ]
        )
    }

    @Test
    func separatesTransactionCommandsFromSurroundingDDLAndDML() async throws {
        let source = """
        DROP TEMPORARY TABLE IF EXISTS querycraft_tx_probe;

        CREATE TEMPORARY TABLE querycraft_tx_probe (
            id INT PRIMARY KEY,
            value VARCHAR(32)
        );

        BEGIN;

        INSERT INTO querycraft_tx_probe VALUES (1, 'pending');

        SELECT * FROM querycraft_tx_probe;

        ROLLBACK;

        SELECT * FROM querycraft_tx_probe;
        """
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(
                revision: SQLSourceRevision(1),
                text: source
            )
        )
        #expect(snapshot.statements.map {
            statementText($0, in: source)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } == [
            "DROP TEMPORARY TABLE IF EXISTS querycraft_tx_probe;",
            "CREATE TEMPORARY TABLE querycraft_tx_probe (\n    id INT PRIMARY KEY,\n    value VARCHAR(32)\n);",
            "BEGIN;",
            "INSERT INTO querycraft_tx_probe VALUES (1, 'pending');",
            "SELECT * FROM querycraft_tx_probe;",
            "ROLLBACK;",
            "SELECT * FROM querycraft_tx_probe;",
        ])
        #expect(snapshot.statements.map(\.kind) == [
            .ddl(.drop),
            .ddl(.create),
            .transaction(.begin),
            .insert,
            .read,
            .transaction(.rollback),
            .read,
        ])
        #expect(snapshot.unreliableStatementRanges.isEmpty)
    }

    @Test
    func leavesMalformedDropTemporaryTableValidationToMySQL() async throws {
        let source = "DROP TEMPORARY TABLE querycraft_tx_probe EXTRA;"
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(
                revision: SQLSourceRevision(1),
                text: source
            )
        )

        #expect(snapshot.statements.map(\.kind) == [.ddl(.drop)])
        #expect(snapshot.unreliableStatementRanges.isEmpty)
        #expect(!snapshot.diagnostics.isEmpty)
    }

    @Test
    func classifiesSyntaxWithinTheRequestedVisibleRange() async throws {
        let source = "SELECT COUNT(u.id), 42, 'name' FROM users AS u; -- note"
        let parser = try SQLStructuralParser()
        let revision = SQLSourceRevision(1)
        _ = try await parser.parse(
            SQLSourceSnapshot(revision: revision, text: source)
        )

        let semicolonRange = (source as NSString).range(of: ";")
        let visibleLength = try #require(
            semicolonRange.location == NSNotFound ? nil : NSMaxRange(semicolonRange)
        )
        let highlights = try await parser.highlights(
            in: SQLSourceRange(location: 0, length: visibleLength),
            revision: revision
        )

        #expect(try syntaxKind(at: "SELECT", in: source, highlights: highlights) == .keyword)
        #expect(try syntaxKind(at: "COUNT", in: source, highlights: highlights) == .function)
        #expect(try syntaxKind(at: "id", in: source, highlights: highlights) == .property)
        #expect(try syntaxKind(at: "42", in: source, highlights: highlights) == .number)
        #expect(try syntaxKind(at: "'name'", in: source, highlights: highlights) == .string)
        #expect(try syntaxKind(at: "users", in: source, highlights: highlights) == .type)
        #expect(!highlights.contains(where: { $0.kind == .comment }))
        #expect(highlights.allSatisfy { $0.range.upperBound <= visibleLength })

        let fullHighlights = try await parser.highlights(
            in: SQLSourceRange(location: 0, length: (source as NSString).length),
            revision: revision
        )
        #expect(try syntaxKind(at: "-- note", in: source, highlights: fullHighlights) == .comment)
    }

    @Test
    func highlightsRecoveredTransactionCommandsAsKeywords() async throws {
        let source = """
        BEGIN;
        SAVEPOINT before_update;
        ROLLBACK TO SAVEPOINT before_update;
        RELEASE SAVEPOINT before_update;
        ROLLBACK;
        COMMIT;
        """
        let parser = try SQLStructuralParser()
        let revision = SQLSourceRevision(1)
        _ = try await parser.parse(
            SQLSourceSnapshot(revision: revision, text: source)
        )

        let highlights = try await parser.highlights(
            in: SQLSourceRange(
                location: 0,
                length: (source as NSString).length
            ),
            revision: revision
        )

        #expect(try syntaxKind(at: "BEGIN", in: source, highlights: highlights) == .keyword)
        #expect(
            highlights.contains {
                $0.kind == .keyword
                    && (source as NSString).substring(with: $0.range.nsRange)
                        == "SAVEPOINT"
            }
        )
        #expect(
            highlights.contains {
                $0.kind == .keyword
                    && (source as NSString).substring(with: $0.range.nsRange)
                        == "ROLLBACK TO SAVEPOINT"
            }
        )
        #expect(
            highlights.contains {
                $0.kind == .keyword
                    && (source as NSString).substring(with: $0.range.nsRange)
                        == "RELEASE SAVEPOINT"
            }
        )
        let firstSavepointName = (source as NSString)
            .range(of: "before_update").location
        #expect(
            highlights.contains {
                $0.kind == .keyword
                    && $0.range.contains(firstSavepointName)
            } == false
        )
        #expect(try syntaxKind(at: "ROLLBACK", in: source, highlights: highlights) == .keyword)
        #expect(try syntaxKind(at: "COMMIT", in: source, highlights: highlights) == .keyword)
    }

    @Test
    func keepsInterleavedMySQLCommentsInsideOneReliableReadStatement() async throws {
        let source = """
        SELECT
            *
            -- dad
        FROM
            # DATE_SUB
            admin_user
        WHERE
            user_name = 'com.hz.zfb.common.exception.BusinessException';
        """
        let parser = try SQLStructuralParser()
        let revision = SQLSourceRevision(1)
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: revision, text: source)
        )

        #expect(snapshot.isReliable)
        #expect(snapshot.statements.map(\.kind) == [.read])
        #expect(statementText(try #require(snapshot.statements.first), in: source) == source)

        let highlights = try await parser.highlights(
            in: SQLSourceRange(location: 0, length: (source as NSString).length),
            revision: revision
        )
        #expect(try syntaxKind(at: "-- dad", in: source, highlights: highlights) == .comment)
        #expect(try syntaxKind(at: "# DATE_SUB", in: source, highlights: highlights) == .comment)
    }

    @Test(arguments: managedQueryFixtures)
    func parsesManagedQueryFormsAsOneReliableStatement(
        _ fixture: ManagedQueryFixture
    ) async throws {
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: fixture.source)
        )

        #expect(snapshot.isReliable)
        #expect(snapshot.statements.map(\.kind) == [fixture.kind])
        #expect(
            statementText(
                try #require(snapshot.statements.first),
                in: fixture.source
            ) == fixture.source
        )
    }

    @Test
    func distinguishesMySQLCommentKindsWithoutChangingExecutionText() async throws {
        let source = """
        SELECT /* ordinary */
               /*+ MAX_EXECUTION_TIME(1000) */ *
        FROM users
        WHERE /*!80000 users.is_active = 1 AND */ users.id > 0;
        """
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )

        #expect(snapshot.isReliable)
        #expect(snapshot.statements.map(\.kind) == [.unknown])
        #expect(statementText(try #require(snapshot.statements.first), in: source) == source)
        #expect(snapshot.syntaxTree.descendants(named: "comment").count == 1)
        #expect(snapshot.syntaxTree.descendants(named: "optimizer_hint").count == 1)
        #expect(snapshot.syntaxTree.descendants(named: "executable_comment").count == 1)
    }

    @Test
    func appliesMySQLDoubleHyphenCommentBoundaryExactly() async throws {
        let source = """
        SELECT 1-- comment
        ;
        SELECT 1--not_a_comment;
        SELECT 1----2;
        """
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )

        #expect(snapshot.statements.count == 3)
        #expect(snapshot.syntaxTree.descendants(named: "comment").count == 1)
        let comment = try #require(snapshot.syntaxTree.descendants(named: "comment").first)
        #expect(
            (source as NSString).substring(with: comment.range.nsRange)
                == "-- comment"
        )
    }

    @Test
    func capturesStandaloneExecutableCommentAsOneUnclassifiedStatement() async throws {
        let source = "/*!80000 SET SESSION sql_mode = 'STRICT_TRANS_TABLES' */;"
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )

        #expect(snapshot.isReliable)
        #expect(snapshot.statements.map(\.kind) == [.unknown])
        #expect(statementText(try #require(snapshot.statements.first), in: source) == source)
    }

    @Test
    func refusesStatementTargetsInsideDelimiterRoutineScripts() async throws {
        let source = try fixtureSource(named: "unsupported-routine")
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )

        #expect(snapshot.statements.isEmpty)
        #expect(!snapshot.isReliable)
        #expect(
            snapshot.statement(
                atUTF16Location: (source as NSString).range(of: "DELETE").location,
                in: source
            ) == nil
        )
    }

    @Test
    func buildsNestedQueryScopesWithoutLeakingSiblingRelations() async throws {
        let source = """
        SELECT u.id
        FROM app.users AS u
        WHERE EXISTS (
            SELECT 1
            FROM analytics.events AS e
            WHERE e.event_id = u.id
        )
        AND EXISTS (
            SELECT 1
            FROM audit_log AS a
            WHERE a.user_id = u.id
        );
        """
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )
        let innerLocation = (source as NSString).range(of: "e.event_id").location
        let path = snapshot.queryScopePath(atUTF16Location: innerLocation)

        #expect(path.count == 2)
        #expect(path.first?.relationReferences.map(\.objectName) == ["users"])
        #expect(path.last?.relationReferences.map(\.objectName) == ["events"])
        #expect(path.last?.canReferenceParentRelations == true)
        #expect(path.last?.relationReferences.contains {
            $0.objectName == "audit_log"
        } == false)
    }

    @Test
    func exposesCTEAndDerivedTableOutputsInTheirParentScopes() async throws {
        let source = """
        WITH recent (user_id) AS (
            SELECT event_id FROM analytics.events
        )
        SELECT r.user_id, d.event_id
        FROM recent AS r
        JOIN (
            SELECT event_id FROM analytics.events
        ) AS d ON d.event_id = r.user_id;
        """
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )
        let root = try #require(snapshot.queryScopes.first)
        let recent = try #require(root.syntheticRelations.first {
            $0.kind == .commonTableExpression && $0.name == "recent"
        })
        let derived = try #require(root.syntheticRelations.first {
            $0.kind == .derivedTable && $0.alias == "d"
        })

        #expect(recent.outputColumnNames == ["user_id"])
        #expect(derived.outputColumnNames == ["event_id"])
        #expect(root.children.contains {
            if case .commonTableExpression(name: "recent") = $0.kind {
                return true
            }
            return false
        })
        #expect(root.children.first {
            $0.kind == .subquery
        }?.canReferenceParentRelations == false)
    }

    @Test
    func exposesBareDerivedTableAliasAndAggregateOutputAlias() async throws {
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
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )
        let root = try #require(snapshot.queryScopes.first)
        let derived = try #require(root.syntheticRelations.first {
            $0.kind == .derivedTable && $0.alias == "a"
        })

        #expect(derived.outputColumnNames == ["user_phone", "c"])
    }

    @Test
    func exposesDerivedTableOutputWhenTheOuterProjectionIsIncomplete() async throws {
        let source = """
        SELECT d.
        FROM (
            SELECT user_phone AS phone
            FROM admin_user
        ) AS d;
        """
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )
        let cursorLocation = NSMaxRange((source as NSString).range(of: "SELECT d."))
        let path = snapshot.queryScopePath(atUTF16Location: cursorLocation)
        let root = try #require(snapshot.queryScopes.first)
        let derived = try #require(root.syntheticRelations.first {
            $0.kind == .derivedTable && $0.alias == "d"
        })

        #expect(path.map(\.kind) == [.statement])
        #expect(derived.outputColumnNames == ["phone"])
    }

    @Test
    func assignsASetOperationTailToTheCombinedOutputScope() async throws {
        let source = """
        SELECT name AS name_label
        FROM users
        UNION ALL
        SELECT name AS name_label
        FROM users
        ORDER BY na
        LIMIT 20;
        """
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )
        let location = NSMaxRange((source as NSString).range(of: "ORDER BY na"))
        let path = snapshot.queryScopePath(atUTF16Location: location)

        #expect(path.map(\.kind) == [.statement, .setOperation])
        #expect(path.last?.projectedColumnNames == ["name_label"])
    }

    @Test
    func permitsOuterReferencesForLateralDerivedTables() async throws {
        let source = """
        SELECT u.id, d.event_id
        FROM app.users AS u
        JOIN LATERAL (
            SELECT e.event_id
            FROM analytics.events AS e
            WHERE e.event_id = u.id
        ) AS d ON TRUE;
        """
        let snapshot = try await SQLStructuralParser().parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )
        let location = (source as NSString).range(of: "e.event_id =").location
        let path = snapshot.queryScopePath(atUTF16Location: location)

        #expect(path.last?.kind == .subquery)
        #expect(path.last?.canReferenceParentRelations == true)
    }

    @Test
    func rejectsHighlightQueriesForAnOldRevision() async throws {
        let source = "SELECT 1;"
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(2), text: source)
        )

        await #expect(throws: SQLStructuralParserError.staleRevision) {
            try await parser.highlights(
                in: SQLSourceRange(location: 0, length: (source as NSString).length),
                revision: SQLSourceRevision(1)
            )
        }
    }

    @Test
    func rejectsStaleRevisionsAndMismatchedEdits() async throws {
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(2), text: "SELECT 1;")
        )

        await #expect(throws: SQLStructuralParserError.staleRevision) {
            try await parser.parse(
                SQLSourceSnapshot(revision: SQLSourceRevision(1), text: "SELECT 2;")
            )
        }
        await #expect(throws: SQLStructuralParserError.invalidEdit) {
            try await parser.parse(
                SQLSourceSnapshot(revision: SQLSourceRevision(3), text: "SELECT 3;"),
                applying: SQLSourceEdit(
                    baseRevision: SQLSourceRevision(2),
                    replacedRange: SQLSourceRange(location: 7, length: 1),
                    replacement: "4"
                )
            )
        }
    }

    @Test(arguments: grammarFixtures)
    func recordsThePinnedGrammarStructuralExecutionBoundary(_ fixture: GrammarFixture) async throws {
        let source = try fixtureSource(named: fixture.name)
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
        )

        #expect(snapshot.statements.count == fixture.executableSegmentCount)
        #expect(snapshot.diagnostics.isEmpty == fixture.expectsReliableDocument)
    }

    @Test(.timeLimit(.minutes(1)))
    func parsesTenThousandLineDocumentWithoutLosingStatementRanges() async throws {
        let source = (0..<10_000)
            .map { "SELECT \($0);" }
            .joined(separator: "\n")
        let parser = try SQLStructuralParser()
        let clock = ContinuousClock()

        let elapsed = try await clock.measure {
            let snapshot = try await parser.parse(
                SQLSourceSnapshot(revision: SQLSourceRevision(1), text: source)
            )
            #expect(snapshot.isReliable)
            #expect(snapshot.statements.count == 10_000)
            #expect(statementText(snapshot.statements[9_999], in: source) == "SELECT 9999;")
        }

        #expect(elapsed < .seconds(5))
    }

    private static let grammarFixtures = [
        GrammarFixture(name: "mysql80-read", executableSegmentCount: 3, expectsReliableDocument: true),
        GrammarFixture(name: "mysql57-read", executableSegmentCount: 5, expectsReliableDocument: false),
        GrammarFixture(name: "mysql-writes", executableSegmentCount: 4, expectsReliableDocument: false),
        GrammarFixture(name: "mysql-ddl", executableSegmentCount: 4, expectsReliableDocument: false),
        GrammarFixture(name: "mysql-control", executableSegmentCount: 9, expectsReliableDocument: false),
        GrammarFixture(name: "mysql-comments", executableSegmentCount: 3, expectsReliableDocument: true),
        GrammarFixture(name: "incomplete-typing", executableSegmentCount: 1, expectsReliableDocument: false),
        GrammarFixture(name: "unsupported-routine", executableSegmentCount: 0, expectsReliableDocument: false),
    ]

    private static let managedQueryFixtures = [
        ManagedQueryFixture(
            name: "scalar and predicate subqueries",
            source: """
            SELECT u.id,
                   (SELECT MAX(a.created_at) FROM audit_log AS a WHERE a.user_id = u.id) AS latest_activity
            FROM users AS u
            WHERE EXISTS (SELECT 1 FROM roles AS r WHERE r.user_id = u.id)
              AND u.id IN (SELECT user_id FROM active_users);
            """,
            kind: .read
        ),
        ManagedQueryFixture(
            name: "derived and lateral tables",
            source: """
            SELECT u.id, activity.latest_at
            FROM users AS u
            JOIN LATERAL (
                SELECT MAX(a.created_at) AS latest_at
                FROM audit_log AS a
                WHERE a.user_id = u.id
            ) AS activity ON TRUE;
            """,
            kind: .read
        ),
        ManagedQueryFixture(
            name: "recursive CTE",
            source: """
            WITH RECURSIVE hierarchy (id, parent_id, depth) AS (
                SELECT id, parent_id, 0 FROM categories WHERE parent_id IS NULL
                UNION ALL
                SELECT c.id, c.parent_id, h.depth + 1
                FROM categories AS c
                JOIN hierarchy AS h ON c.parent_id = h.id
            )
            SELECT * FROM hierarchy ORDER BY depth, id;
            """,
            kind: .read
        ),
        ManagedQueryFixture(
            name: "mixed combined query",
            source: """
            (SELECT id FROM active_users ORDER BY id LIMIT 20)
            UNION ALL
            SELECT id FROM invited_users
            INTERSECT
            SELECT user_id FROM allowed_users
            EXCEPT
            SELECT user_id FROM blocked_users
            ORDER BY id LIMIT 50;
            """,
            kind: .read
        ),
        ManagedQueryFixture(
            name: "insert select",
            source: """
            INSERT INTO user_archive (id, name)
            SELECT id, name FROM users WHERE deleted_at IS NOT NULL;
            """,
            kind: .insert
        ),
        ManagedQueryFixture(
            name: "create table select",
            source: """
            CREATE TABLE active_user_snapshot AS
            SELECT id, name FROM users WHERE is_active = 1;
            """,
            kind: .ddl(.create)
        ),
        ManagedQueryFixture(
            name: "update correlated subquery",
            source: """
            UPDATE users AS u
            SET u.last_seen_at = (
                SELECT MAX(a.created_at) FROM audit_log AS a WHERE a.user_id = u.id
            )
            WHERE u.id IN (SELECT user_id FROM active_users);
            """,
            kind: .update(hasWhereClause: true)
        ),
    ]

    private func fixtureSource(named name: String) throws -> String {
        let fixturesURL = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let url = fixturesURL
            .appendingPathComponent("SQLGrammar")
            .appendingPathComponent("\(name).sql")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func statementText(_ statement: SQLStatement, in source: String) -> String {
        (source as NSString).substring(with: statement.range.nsRange)
    }

    private func syntaxKind(
        at token: String,
        in source: String,
        highlights: [SQLSyntaxHighlight]
    ) throws -> SQLSyntaxHighlight.Kind {
        let tokenRange = (source as NSString).range(of: token)
        let location = try #require(
            tokenRange.location == NSNotFound ? nil : tokenRange.location
        )
        return try #require(
            highlights.first(where: { $0.range.contains(location) })?.kind
        )
    }
}

struct GrammarFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let executableSegmentCount: Int
    let expectsReliableDocument: Bool

    var testDescription: String { name }
}

struct ManagedQueryFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let source: String
    let kind: SQLStatementKind

    var testDescription: String { name }
}
