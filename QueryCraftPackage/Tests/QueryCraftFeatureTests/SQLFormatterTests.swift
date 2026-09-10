import CodeEditLanguages
import CodeEditTextView
import Foundation
import Testing
@testable import QueryCraftFeature

struct SQLFormatterTests {
    @Test(arguments: [
        "simple",
        "simple-from",
        "qualified-limit",
        "join",
        "comments",
        "document",
    ])
    func matchesApprovedGoldenFixture(_ name: String) async throws {
        let input = try fixture(name, kind: "input.sql")
        let expected = try fixture(name, kind: "output.sql")
        let parser = try SQLStructuralParser()
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: input
        )
        let snapshot = try await parser.parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )

        let edit = try SQLFormatter.formattingEdit(
            target: target,
            originalSelection: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )

        #expect(edit?.replacement ?? input == expected)
    }

    @Test
    func isIdempotentAfterApplyingTheGoldenStyle() async throws {
        let sql = try fixture("join", kind: "output.sql")
        let parser = try SQLStructuralParser()
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: sql
        )
        let snapshot = try await parser.parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )

        #expect(
            try SQLFormatter.formattingEdit(
                target: target,
                originalSelection: NSRange(location: 0, length: 0),
                parseSnapshot: snapshot
            ) == nil
        )
    }

    @Test
    func formatsTheExactSelectionAndLeavesFollowingSQLOutsideTheEdit() async throws {
        let sql = "select a,b from users;\nselect 2;"
        let parser = try SQLStructuralParser()
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: sql
        )
        let snapshot = try await parser.parse(source)
        let selection = (sql as NSString).range(of: "select a,b from users;")
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: selection,
            parseSnapshot: snapshot
        )

        let possibleEdit = try SQLFormatter.formattingEdit(
            target: target,
            originalSelection: selection,
            parseSnapshot: snapshot
        )
        let edit = try #require(possibleEdit)
        let formattedDocument = NSMutableString(string: sql)
        formattedDocument.replaceCharacters(
            in: edit.range.nsRange,
            with: edit.replacement
        )

        #expect(edit.range == SQLSourceRange(selection))
        #expect(edit.selectedRange == NSRange(
            location: selection.location,
            length: (edit.replacement as NSString).length
        ))
        #expect(formattedDocument.hasSuffix("\nselect 2;"))
    }

    @Test
    func preservesTheCursorAtItsOriginalToken() async throws {
        let sql = "select first_name,last_name from users;"
        let cursor = (sql as NSString).range(of: "last_name").location
        let parser = try SQLStructuralParser()
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: sql
        )
        let snapshot = try await parser.parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: NSRange(location: cursor, length: 0),
            parseSnapshot: snapshot
        )

        let possibleEdit = try SQLFormatter.formattingEdit(
            target: target,
            originalSelection: NSRange(location: cursor, length: 0),
            parseSnapshot: snapshot
        )
        let edit = try #require(possibleEdit)
        let formattedCursor = edit.selectedRange.location - edit.range.location
        #expect(
            (edit.replacement as NSString).substring(
                with: NSRange(location: formattedCursor, length: 9)
            ) == "last_name"
        )
    }

    @Test
    func bestEffortFormatsUnreliableAndWriteStatements() async throws {
        for sql in [
            "SELECT * FROM users LIMIT 10, 20;",
            "delete from users where id=1;"
        ] {
            let formatted = try await formattedSQL(sql)
            #expect(!formatted.isEmpty)
            #expect(try await formattedSQL(formatted) == formatted)
        }
    }

    @Test
    func recursivelyFormatsNestedQueryBlocks() async throws {
        let sql = "select id from users where id in (select user_id from orders);"
        let formatted = try await formattedSQL(sql)

        #expect(formatted.contains("IN (\n    SELECT"))
        #expect(formatted.contains("\n    FROM\n        orders"))
        #expect(try await formattedSQL(formatted) == formatted)
    }

    @Test
    func recursivelyFormatsCTEsAndCombinedQueries() async throws {
        let sql = """
        with recent(user_id) as (select user_id from events) select user_id from recent union all select user_id from archive intersect select user_id from allowed except select user_id from blocked order by user_id;
        """
        let formatted = try await formattedSQL(sql)

        #expect(formatted.hasPrefix("WITH recent (user_id) AS (\n    SELECT"))
        #expect(formatted.contains("\nUNION ALL\nSELECT"))
        #expect(formatted.contains("\nINTERSECT\nSELECT"))
        #expect(formatted.contains("\nEXCEPT\nSELECT"))
        #expect(try await formattedSQL(formatted) == formatted)
    }

    @Test
    func preservesInterleavedAndExecutableCommentsWhileFormatting() async throws {
        let sql = """
        select
        -- select note
        *
        from
        # relation note
        users
        where /*!80000 users.is_active = 1 and */ users.id>0;
        """
        let formatted = try await formattedSQL(sql)

        #expect(formatted.contains("-- select note"))
        #expect(formatted.contains("# relation note"))
        #expect(formatted.contains("/*!80000 users.is_active = 1 and */"))
        #expect(formatted.contains("users.id > 0"))
    }

    @Test(arguments: [
        "insert into archived_users(id) select id from users where is_active=0;",
        "create table active_users as select id from users where is_active=1;",
        "update users set last_seen=(select max(created_at) from events) where id=1;",
    ])
    func formatsQueryBearingWriteAndDDLStatements(_ sql: String) async throws {
        let formatted = try await formattedSQL(sql)

        #expect(formatted.contains("SELECT\n"))
        #expect(formatted.contains("FROM\n"))
    }

    @Test
    func leavesACommentOnlyDocumentUnchanged() async throws {
        let sql = "-- nothing to format"
        let parser = try SQLStructuralParser()
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: sql
        )
        let snapshot = try await parser.parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )

        #expect(try SQLFormatter.formattingEdit(
            target: target,
            originalSelection: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        ) == nil)
    }

    @Test
    func preservesMalformedDerivedAliasWhileFormatting() async throws {
        let sql = """
        select a.user_phone,a.c from (select user_phone,count(*) as c from admin_user group by user_phone) a.c limit 20;
        """
        let formatted = try await formattedSQL(sql)

        #expect(formatted.contains(") a.c"))
        #expect(formatted.contains("COUNT(*) AS c"))
        #expect(try await formattedSQL(formatted) == formatted)
    }

    @Test(arguments: [
        "select * fro",
        "select mystery_operator(value) wobble clause;",
    ])
    func preservesIncompleteOrUnknownSyntaxWithoutDataLoss(_ sql: String) async throws {
        let formatted = try await formattedSQL(sql)

        for fragment in sql.split(whereSeparator: \.isWhitespace) {
            #expect(formatted.lowercased().contains(fragment.lowercased()))
        }
        #expect(try await formattedSQL(formatted) == formatted)
    }

    @Test
    func preservesCommentAndStringContentsExactly() async throws {
        let lineComment = "-- keep  two spaces and SELECT"
        let hashComment = "# keep # punctuation"
        let blockComment = "/* keep  block SELECT */"
        let executableComment = "/*!80000 SET_VAR(sort_buffer_size=16M) */"
        let literal = "'keep  SELECT -- text'"
        let sql = """
        select \(literal),value \(lineComment)
        from users \(hashComment)
        where \(executableComment) value=1 \(blockComment);
        """
        let formatted = try await formattedSQL(sql)

        for fragment in [
            lineComment, hashComment, blockComment, executableComment, literal
        ] {
            #expect(formatted.contains(fragment))
        }
        #expect(try await formattedSQL(formatted) == formatted)
    }

    @Test
    func preservesCRLFLineEndings() async throws {
        let sql = "select first_name,last_name from users;\r\nselect 2;"
        let parser = try SQLStructuralParser()
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: sql
        )
        let snapshot = try await parser.parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )

        let possibleEdit = try SQLFormatter.formattingEdit(
            target: target,
            originalSelection: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )
        let edit = try #require(possibleEdit)

        #expect(edit.replacement.contains("\r\n"))
        #expect(!edit.replacement.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test
    func appliesConfiguredKeywordCaseAndIndentation() async throws {
        let sql = "SELECT a,b FROM users WHERE a=1;"
        let parser = try SQLStructuralParser()
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: sql
        )
        let snapshot = try await parser.parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )

        let possibleEdit = try SQLFormatter.formattingEdit(
            target: target,
            originalSelection: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot,
            options: SQLFormattingOptions(
                keywordCase: .lowercase,
                indentationUnit: "\t"
            )
        )
        let edit = try #require(possibleEdit)

        #expect(edit.replacement.hasPrefix("select\n\t"))
        #expect(edit.replacement.contains("\nfrom\n\tusers"))
        #expect(edit.replacement.contains("\nwhere\n\ta = 1"))
        #expect(!edit.replacement.contains("SELECT"))
    }

    @Test
    func formattingWorkerBuildsTheTargetOffTheCallingActor() async throws {
        let sql = "select first_name,last_name from users;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: sql
        )
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(source)
        let worker = SQLFormattingWorker()

        let possibleEdit = try await worker.formattingEdit(
            for: .document,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot,
            options: .standard
        )
        let edit = try #require(possibleEdit)

        #expect(edit.sourceRevision == source.revision)
        #expect(edit.replacement.hasPrefix("SELECT\n"))
        #expect(edit.range == SQLSourceRange(
            location: 0,
            length: (sql as NSString).length
        ))
    }

    private func fixture(_ name: String, kind pathExtension: String) throws -> String {
        let fixturesURL = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil)
        )
        let url = fixturesURL
            .appending(path: "Formatting")
            .appending(path: "\(name).\(pathExtension)")
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
    }

    private func formattedSQL(_ sql: String) async throws -> String {
        let parser = try SQLStructuralParser()
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: sql
        )
        let snapshot = try await parser.parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )
        return try SQLFormatter.formattingEdit(
            target: target,
            originalSelection: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )?.replacement ?? sql
    }

}

@MainActor
struct WorkspaceQueryFormattingCommandTests {
    @Test
    func formatsTheCurrentUnreliableStatementWithoutDroppingSource() async throws {
        let original = """
        select a.user_phone,a.c from (select user_phone,count(*) as c from admin_user group by user_phone) a.c limit 20;
        """
        let textView = TextView(string: original)
        let cursor = (original as NSString).range(of: "a.c limit").location
        textView.selectionManager.setSelectedRange(
            NSRange(location: cursor, length: 0)
        )
        let languageService = WorkspaceSQLLanguageService()
        languageService.setUp(textView: textView, codeLanguage: .sql)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: DatabaseConnectionConfiguration(
                host: "127.0.0.1",
                port: 3306,
                username: "root",
                password: "secret",
                database: nil,
                tlsMode: .disabled
            ),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let coordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document,
            languageService: languageService
        )

        #expect(try await coordinator.applyFormatting(
            .selectionOrCurrentStatement,
            textView: textView
        ))
        #expect(textView.string.contains(") a.c"))
        #expect(textView.string.contains("COUNT(*) AS c"))
    }

    @Test
    func appliesFormattingAsOneUndoableEditorMutation() async throws {
        let original = "select first_name,last_name from users;"
        let textView = TextView(string: original)
        textView.selectionManager.setSelectedRange(
            NSRange(location: (original as NSString).length, length: 0)
        )
        let languageService = WorkspaceSQLLanguageService()
        languageService.setUp(textView: textView, codeLanguage: .sql)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: DatabaseConnectionConfiguration(
                host: "127.0.0.1",
                port: 3306,
                username: "root",
                password: "secret",
                database: nil,
                tlsMode: .disabled
            ),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let coordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document,
            languageService: languageService
        )

        #expect(try await coordinator.applyFormatting(.document, textView: textView))
        #expect(textView.string != original)
        #expect(textView.undoManager?.canUndo == true)

        textView.undoManager?.undo()

        #expect(textView.string == original)
        #expect(textView.undoManager?.canUndo == false)
    }

    @Test
    func commandIDoesNotDisturbActiveMarkedText() {
        let textView = TextView(string: "select 1;")
        textView.selectionManager.setSelectedRange(
            NSRange(location: textView.length, length: 0)
        )
        let languageService = WorkspaceSQLLanguageService()
        languageService.setUp(textView: textView, codeLanguage: .sql)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: DatabaseConnectionConfiguration(
                host: "127.0.0.1",
                port: 3306,
                username: "root",
                password: "secret",
                database: nil,
                tlsMode: .disabled
            ),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let coordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document,
            languageService: languageService
        )
        textView.setMarkedText(
            "zhong",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let markedSource = textView.string

        #expect(
            coordinator.handleTextViewKeyCommand(
                .commandI,
                textView: textView
            )
        )
        #expect(textView.hasMarkedText())
        #expect(textView.string == markedSource)
    }
}
