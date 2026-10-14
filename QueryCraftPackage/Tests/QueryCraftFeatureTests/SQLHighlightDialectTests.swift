import Foundation
import Testing
@testable import QueryCraftFeature

struct SQLHighlightDialectTests {
    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris], [false, true])
    func quotedExpressionsRespectDialectWithoutChangingExecution(_ database: DatabaseType, _ ansi: Bool) async throws {
        let text = "SELECT \"name\", u.\"id\", 'literal \"quoted\"', $$\"opaque\"$$ FROM \"users\" u; SELECT 42;"
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(.init(revision: .init(1), text: text))
        let range = SQLSourceRange(location: 0, length: text.utf16.count)
        let original = try await parser.highlights(in: range, revision: .init(1))
        let context = SQLHighlightContext(databaseType: database, ansiQuotes: ansi)
        let captures = try await parser.highlights(in: range, revision: .init(1), context: context)
        let quotedName = (text as NSString).range(of: "\"name\"")
        #expect(captures.contains { $0.range.nsRange == quotedName && $0.kind == (database == .postgresql || ansi ? .property : .string) })
        #expect(captures.contains { $0.range.nsRange == (text as NSString).range(of: "\"users\"") && $0.kind == .type })
        #expect(captures.contains { $0.range.nsRange == (text as NSString).range(of: "'literal \"quoted\"'") && $0.kind == .string })
        let after = try await parser.highlights(in: range, revision: .init(1))
        #expect(after == original)
        #expect(snapshot.statements.map(\.kind) == [.read, .read])
        for highlight in captures {
            let partial = try await parser.highlights(in: highlight.range, revision: .init(1), context: context)
            #expect(partial == [highlight])
        }
    }

    @Test func reusedStatementsMatchFreshStructureAfterOffsetAndBoundaryEdits() async throws {
        let original = "SELECT u.id FROM users u;\nWITH c AS (SELECT id FROM things) SELECT c.id FROM c;\nUPDATE users SET id = 2 WHERE id = 1;\nDELETE FROM users WHERE id = 3;"
        let parser = try SQLStructuralParser()
        var text = original
        var revision: UInt64 = 1
        _ = try await parser.parse(.init(revision: .init(revision), text: text))
        for (needle, replacement) in [("u.id", "u.name"), ("SELECT u", "/* 中文😀 */ SELECT u"),
                                      (";\nWITH", "\nWITH"), ("\nWITH", ";\nWITH"),
                                      ("WHERE id = 1", ""), ("id = 3", "id = 4"),
                                      ("things", "other_things"), ("/* 中文😀 */ ", "")] {
            let range = (text as NSString).range(of: needle)
            #expect(range.location != NSNotFound)
            let next = (text as NSString).replacingCharacters(in: range, with: replacement)
            let incremental = try await parser.parse(.init(revision: .init(revision + 1), text: next), applying:
                .init(baseRevision: .init(revision), replacedRange: .init(range), replacement: replacement))
            let fresh = try await SQLStructuralParser().parse(.init(revision: .init(1), text: next))
            #expect(incremental.statements == fresh.statements)
            #expect(incremental.syntaxTree == fresh.syntaxTree)
            #expect(incremental.queryScopes == fresh.queryScopes)
            #expect(incremental.relationReferences == fresh.relationReferences)
            #expect(incremental.diagnostics == fresh.diagnostics)
            #expect(incremental.unreliableStatementRanges == fresh.unreliableStatementRanges)
            text = next
            revision += 1
        }
    }

    @Test(arguments: ["1.25E+3", "2E-4", "3E8", "4.0e+2"])
    func scientificNotationIsStructurallyReliable(_ number: String) async throws {
        let parser = try SQLStructuralParser()
        let text = "SELECT \(number) FROM users;"
        let snapshot = try await parser.parse(.init(revision: .init(1), text: text))
        #expect(snapshot.isReliable)
        #expect(snapshot.statements.map(\.kind) == [.read])
    }

    @Test func quoteTransformPreservesUTF16AndOpaqueComments() {
        let source = "-- \"comment\"\nSELECT \"名😀\"\"字`\", '\"string\"', $$\"dollar\"$$; /* \"comment\" */"
        let transformed = SQLHighlightContext(databaseType: .postgresql).displaySource(source)!
        #expect(transformed.utf16.count == source.utf16.count)
        #expect(transformed.contains("`名😀``字_`"))
        #expect(transformed.contains("-- \"comment\""))
        #expect(transformed.contains("'\"string\"'"))
        #expect(transformed.contains("$$\"dollar\"$$"))
        #expect(transformed.contains("/* \"comment\" */"))
    }

    @MainActor @Test func connectionQuoteOverridesPersistAndStayScoped() throws {
        let name = "SQLHighlightDialect.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ApplicationPreferences(userDefaults: defaults)
        func config(_ host: String) -> DatabaseConnectionConfiguration {
            .init(host: host, port: 3306, username: "user", password: "secret", database: "db", tlsMode: .disabled)
        }
        let a = config("a"), b = config("b")
        preferences.editorANSIQuoteConnections.insert(SQLHighlightContext.connectionKey(a))
        #expect(preferences.sqlHighlightContext(for: a).ansiQuotes)
        #expect(!preferences.sqlHighlightContext(for: b).ansiQuotes)
        #expect(SQLHighlightContext.connectionKey(a) == SQLHighlightContext.connectionKey(a.selecting(database: "other")))
        #expect(ApplicationPreferences(userDefaults: defaults).sqlHighlightContext(for: a).ansiQuotes)
    }
}
