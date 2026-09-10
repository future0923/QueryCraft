import Foundation
import Testing
@testable import QueryCraftFeature

struct SQLExecutionTargetResolverTests {
    @Test
    func resolvesANonWhitespaceSelectionExactlyWithoutAParseSnapshot() throws {
        let text = "SELECT 1;\n  SELECT 2;  "
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let selection = (text as NSString).range(of: "  SELECT 2;  ")

        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: selection,
            parseSnapshot: nil
        )

        #expect(target.kind == .selection)
        #expect(target.range == SQLSourceRange(selection))
        #expect(target.sql == "  SELECT 2;  ")
    }

    @Test
    func resolvesWhitespaceSelectionForwardToTheNextReliableStatement() async throws {
        let text = "SELECT 1;\n-- inspect next\nSELECT 2;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(source)
        let beforeSecondStatement = (text as NSString).range(of: "\nSELECT 2;")
        let whitespace = NSRange(
            location: beforeSecondStatement.location,
            length: 1
        )

        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: whitespace,
            parseSnapshot: snapshot
        )

        #expect(target.kind == .currentStatement)
        #expect(target.sql == "SELECT 2;")
    }

    @Test
    func keepsTheInsertionPointAfterASemicolonWithThePrecedingStatement() async throws {
        let text = "SELECT 1;\nSELECT 2;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(source)

        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: NSRange(location: 9, length: 0),
            parseSnapshot: snapshot
        )

        #expect(target.sql == "SELECT 1;")
    }

    @Test
    func runAllCapturesTheCompleteDocumentExactly() throws {
        let text = " \nSELECT 1;\n "
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )

        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: nil
        )

        #expect(target.kind == .document)
        #expect(target.sql == text)
    }

    @Test
    func resolvesAStatementWhoseBoundarySurvivesGrammarDiagnostics() async throws {
        let text = "SELECT * FROM users LIMIT 10, 20;\nSELECT 2;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(source)
        let firstSemicolon = (text as NSString).range(of: ";")

        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: NSRange(
                location: NSMaxRange(firstSemicolon),
                length: 0
            ),
            parseSnapshot: snapshot
        )

        #expect(target.sql == "SELECT * FROM users LIMIT 10, 20;")
    }

    @Test
    func rejectsAParseSnapshotFromAnotherRevision() async throws {
        let parser = try SQLStructuralParser()
        let parsedSource = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: "SELECT 1;"
        )
        let snapshot = try await parser.parse(parsedSource)
        let editedSource = SQLSourceSnapshot(
            revision: SQLSourceRevision(2),
            text: "SELECT 2;"
        )

        #expect(throws: SQLExecutionTargetError.sourceChanged) {
            try SQLExecutionTargetResolver.resolve(
                .selectionOrCurrentStatement,
                source: editedSource,
                selectedRange: NSRange(location: 3, length: 0),
                parseSnapshot: snapshot
            )
        }
    }

    @Test
    func rejectsAnEmptyDocument() {
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: " \n\t"
        )

        #expect(throws: SQLExecutionTargetError.emptyDocument) {
            try SQLExecutionTargetResolver.resolve(
                .all,
                source: source,
                selectedRange: NSRange(location: 0, length: 0),
                parseSnapshot: nil
            )
        }
    }
}
