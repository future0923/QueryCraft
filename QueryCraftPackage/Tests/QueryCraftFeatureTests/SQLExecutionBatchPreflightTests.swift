import Foundation
import Testing
@testable import QueryCraftFeature

struct SQLExecutionBatchPreflightTests {
    @Test
    func classifiesReliableStatementsAndRequiresWriteAccess() async throws {
        let text = """
        SELECT 1;
        INSERT INTO users (id) VALUES (1);
        UPDATE users SET active = 0;
        DELETE FROM users WHERE id = 1;
        DROP TABLE old_users;
        TRUNCATE TABLE audit_log;
        """
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )

        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(
            plan.statements.map(\.kind) == [
                .read,
                .insert,
                .update(hasWhereClause: false),
                .delete(hasWhereClause: true),
                .ddl(.drop),
                .ddl(.truncate),
            ]
        )
        #expect(plan.requiresWriteAccess)
        #expect(plan.requiresDangerousSQLConfirmation)
    }

    @Test
    func classifiesSupportedReadsAndSafeDDL() async throws {
        let text = """
        SHOW TABLES;
        EXPLAIN SELECT * FROM users;
        CREATE TABLE archived_users (id INT);
        ALTER TABLE archived_users ADD COLUMN name VARCHAR(255);
        """
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )

        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(
            plan.statements.map(\.kind) == [
                .read,
                .read,
                .ddl(.create),
                .ddl(.alter),
            ]
        )
        #expect(plan.requiresWriteAccess)
        #expect(!plan.requiresDangerousSQLConfirmation)
    }

    @Test
    func keepsAnExactDescribeGrammarGapExecutableForMySQL() async throws {
        let text = "DESCRIBE users;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: NSRange(location: 5, length: 0),
            parseSnapshot: snapshot
        )
        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(snapshot.statements.map(\.kind) == [.unknown])
        #expect(snapshot.unreliableStatementRanges.isEmpty)
        #expect(plan.statements.map(\.sql) == [text])
    }

    @Test
    func aNestedWhereDoesNotMakeAnUnboundedUpdateSafe() async throws {
        let text = """
        UPDATE users
        SET active = (SELECT MAX(active) FROM archived_users WHERE id > 0);
        """
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )

        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(plan.statements.map(\.kind) == [.update(hasWhereClause: false)])
        #expect(plan.requiresWriteAccess)
    }

    @Test
    func permitsASelectionContainingOnlyCompleteStatements() async throws {
        let text = "SELECT 1;\nSELECT 2;\nSELECT 3;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let selectedRange = (text as NSString).range(of: "SELECT 2;\nSELECT 3;")
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: selectedRange,
            parseSnapshot: snapshot
        )

        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(plan.statements.map(\.sql) == ["SELECT 2;", "SELECT 3;"])
        #expect(!plan.requiresWriteAccess)
    }

    @Test
    func permitsExactSelectionWithoutBoundaryWhitespaceOrFinalSemicolon() async throws {
        let text = "BEGIN;\n\nROLLBACK;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let selectedRange = (text as NSString).range(of: "ROLLBACK")
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: selectedRange,
            parseSnapshot: snapshot
        )

        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(plan.statements.count == 1)
        #expect(plan.statements.first?.sql == "ROLLBACK")
        #expect(plan.statements.first?.kind == .transaction(.rollback))
    }

    @Test
    func permitsACompleteSelectedBranchOfASetQuery() async throws {
        let text = """
        SELECT user_phone
        FROM admin_user
        WHERE user_phone IS NOT NULL

        UNION ALL

        SELECT user_phone
        FROM admin_user
        WHERE user_phone IS NULL

        ORDER BY user_phone
        LIMIT 20;
        """
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let selectedRange = (text as NSString).range(
            of: """
            SELECT user_phone
            FROM admin_user
            WHERE user_phone IS NOT NULL
            """
        )
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: selectedRange,
            parseSnapshot: snapshot
        )

        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(plan.statements.map(\.sql) == [
            """
            SELECT user_phone
            FROM admin_user
            WHERE user_phone IS NOT NULL
            """,
        ])
        #expect(plan.statements.map(\.kind) == [.read])
        #expect(!plan.requiresWriteAccess)
    }

    @Test
    func preservesAPartialSelectionAsOneUnclassifiedRequest() async throws {
        let text = "SELECT 1;\nSELECT 2;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let selectedRange = (text as NSString).range(of: "LECT 1")
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: selectedRange,
            parseSnapshot: snapshot
        )

        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(plan.statements.map(\.sql) == ["LECT 1"])
        #expect(plan.statements.map(\.kind) == [.unknown])
        #expect(plan.requiresWriteAccess)
    }

    @Test
    func preservesStructurallyBoundedGrammarGapsForServerValidation() async throws {
        let text = "SELECT * FROM users LIMIT 10, 20;\nSELECT 2;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )

        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(plan.statements.map(\.kind) == [.read, .read])
        #expect(
            plan.statements.map(\.sql)
                == ["SELECT * FROM users LIMIT 10, 20;", "SELECT 2;"]
        )
        #expect(!plan.requiresWriteAccess)
    }

    @Test
    func preservesInterleavedCommentsInOneReadStatement() async throws {
        let text = """
        SELECT
            *
            -- select note
        FROM
            # relation note
            users;
        """
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: NSRange(location: 2, length: 0),
            parseSnapshot: snapshot
        )
        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(plan.statements.map(\.kind) == [.read])
        #expect(plan.statements.map(\.sql) == [text])
        #expect(!plan.requiresWriteAccess)
    }

    @Test
    func classifiesExecutableCommentsAsUncertainWithoutChangingTheirText() async throws {
        let text = "SELECT 1 /*!80000 SQL_NO_CACHE */;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )
        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(plan.statements.map(\.kind) == [.unknown])
        #expect(plan.statements.map(\.sql) == [text])
        #expect(plan.requiresWriteAccess)
        #expect(plan.containsUnclassifiedStatement)
    }

    @Test
    func preservesAnAmbiguousSelectionAsOneExactRequest() async throws {
        let text = "BEGIN\nCOMMIT"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: NSRange(
                location: 0,
                length: (text as NSString).length
            ),
            parseSnapshot: snapshot
        )

        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(plan.statements.count == 1)
        #expect(plan.statements.first?.sql == text)
    }

    @Test
    func classifiesExplicitTransactionBoundariesWithoutWriteAccess() async throws {
        let text = """
        START TRANSACTION READ ONLY;
        COMMIT;
        ROLLBACK;
        """
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        #expect(snapshot.isReliable, "\(snapshot.syntaxTree)")

        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )
        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(
            plan.statements.map(\.kind) == [
                .transaction(.begin),
                .transaction(.commit),
                .transaction(.rollback),
            ]
        )
        #expect(!plan.requiresWriteAccess)
    }

    @Test
    func resolvesTheCurrentSavepointFromAMixedTransactionBatch() async throws {
        let text = """
        START TRANSACTION;
        UPDATE admin_user SET user_phone = 'savepoint_test' WHERE id = 1;
        SAVEPOINT before_rollback;
        UPDATE admin_user SET user_phone = 'changed_again' WHERE id = 1;
        ROLLBACK TO SAVEPOINT before_rollback;
        SELECT id, user_phone FROM admin_user WHERE id = 1;
        ROLLBACK;
        """
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let cursor = (text as NSString).range(of: "before_rollback").location
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: NSRange(location: cursor, length: 0),
            parseSnapshot: snapshot
        )
        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )

        #expect(plan.statements.map(\.kind) == [.transaction(.savepoint)])
        #expect(
            plan.statements.map(\.sql) == ["SAVEPOINT before_rollback;"]
        )
        #expect(!plan.requiresWriteAccess)

        let rollbackCursor = (text as NSString)
            .range(of: "ROLLBACK TO SAVEPOINT").location
        let rollbackTarget = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: NSRange(
                location: rollbackCursor,
                length: 0
            ),
            parseSnapshot: snapshot
        )
        let rollbackPlan = try SQLExecutionBatchPreflight.makePlan(
            target: rollbackTarget,
            parseSnapshot: snapshot
        )

        #expect(
            rollbackPlan.statements.map(\.kind)
                == [.transaction(.savepoint)]
        )
        #expect(
            rollbackPlan.statements.map(\.sql)
                == ["ROLLBACK TO SAVEPOINT before_rollback;"]
        )
        #expect(!rollbackPlan.requiresWriteAccess)
    }
}
