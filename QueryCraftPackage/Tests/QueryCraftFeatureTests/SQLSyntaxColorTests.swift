import Foundation
import Testing
@testable import QueryCraftFeature

struct SQLSyntaxColorTests {
    @Test
    func indexColumnsHaveTheSameCategoryAsQueryColumns() async throws {
        let source = """
        ALTER TABLE broker_wage_basic_salary
        ADD INDEX idx_basic_salary_user_confirm
        (user_id, confirm_status, flag_del, create_time, id);
        ALTER TABLE cache_dept_user
        ADD INDEX idx_cache_user_work_age (type, cache_date, dept_user_id, flag_del);
        SELECT id, flag_del, type FROM cache_dept_user;
        """
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: source))
        let highlights = try await parser.highlights(
            in: .init(location: 0, length: (source as NSString).length), revision: .init(1)
        )
        for token in ["user_id", "confirm_status", "flag_del", "create_time", "id", "type", "cache_date", "dept_user_id"] {
            let ranges = try NSRegularExpression(pattern: "\\b\(token)\\b")
                .matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
            for match in ranges {
                #expect(highlights.first { $0.range.nsRange == match.range }?.kind == .property,
                        "\(token) at \(match.range)")
            }
        }
    }
    @Test
    func recoveryPreservesQuotedNamesCommentsStringsAndFollowingStatements() async throws {
        let source = """
        -- ALTER TABLE fake ADD INDEX x (wrong);
        ALTER TABLE t ADD UNIQUE INDEX idx (`type`, `列名`, name(12), (lower(name)), id DESC /* keep */);
        SELECT 'ALTER TABLE fake ADD INDEX x (wrong)' AS note, 42 AS n;
        """
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: source))
        let highlights = try await parser.highlights(
            in: .init(location: 0, length: (source as NSString).length), revision: .init(1)
        )
        for (token, expected) in [
            ("`type`", SQLSyntaxHighlight.Kind.property), ("`列名`", .property),
            ("lower", .function), ("12", .number), ("DESC", .attribute), ("/* keep */", .comment),
            ("'ALTER TABLE fake ADD INDEX x (wrong)'", .string), ("42", .number)
        ] {
            let range = (source as NSString).range(of: token)
            #expect(highlights.first { $0.range.nsRange == range }?.kind == expected, "\(token)")
        }
        let recovery = SQLIndexHighlightRecovery.highlights(in: source)
        let lastSemicolon = (source as NSString).range(of: ";\nSELECT").location
        #expect(recovery.allSatisfy { $0.highlight.range.upperBound <= lastSemicolon })
    }

    @Test
    func incrementalIndexEditsAndPartialHighlightRangesAgree() async throws {
        let initial = "ALTER TABLE t ADD INDEX idx (type, flag_del);"
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: initial))
        let range = (initial as NSString).range(of: "flag_del")
        let updated = (initial as NSString).replacingCharacters(in: range, with: "dept_user_id")
        _ = try await parser.parse(.init(revision: .init(2), text: updated), applying: .init(
            baseRevision: .init(1), replacedRange: .init(range), replacement: "dept_user_id"
        ))
        let partial = SQLSourceRange(location: range.location + 2, length: 5)
        let highlights = try await parser.highlights(in: partial, revision: .init(2))
        #expect(highlights == [.init(range: partial, kind: .property)])
    }

    @Test
    func distinguishesTypesNullFieldsAndFunctionsAcrossDDLAndDML() async throws {
        let source = """
        ALTER TABLE users ADD COLUMN active INT DEFAULT 1 AFTER id;
        INSERT INTO users (active, id) VALUES (1, 2);
        SELECT COUNT(active), NULL, TRUE FROM users WHERE active = 1;
        UPDATE users SET active = 0 WHERE id = 2;
        """
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: source))
        let highlights = try await parser.highlights(
            in: .init(location: 0, length: (source as NSString).length), revision: .init(1)
        )
        for (token, expected) in [("INT", SQLSyntaxHighlight.Kind.builtinType), ("NULL", .boolean),
                                  ("TRUE", .boolean), ("COUNT", .function), ("DEFAULT", .attribute)] {
            #expect(highlights.first { $0.range.nsRange == (source as NSString).range(of: token) }?.kind == expected)
        }
        for token in ["active", "id"] {
            for match in try NSRegularExpression(pattern: "\\b\(token)\\b")
                .matches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) {
                #expect(highlights.first { $0.range.nsRange == match.range }?.kind == .property,
                        "\(token) at \(match.range)")
            }
        }
    }

    @Test
    func indexExpressionsKeepKeywordsAndTypes() async throws {
        let source = "ALTER TABLE users ADD INDEX idx_cast ((CAST(name AS CHAR(20))), (CASE WHEN active = 1 THEN id ELSE 0 END), (CHAR(65)), (MOD(id, 2)));"
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: source))
        let highlights = try await parser.highlights(
            in: .init(location: 0, length: (source as NSString).length), revision: .init(1)
        )
        for (token, expected) in [("AS", SQLSyntaxHighlight.Kind.keyword), ("CHAR", .builtinType),
                                  ("CASE", .keyword), ("WHEN", .keyword), ("THEN", .keyword), ("ELSE", .keyword)] {
            let range = try #require(NSRegularExpression(pattern: "\\b\(token)\\b")
                .firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length))).range
            #expect(highlights.first { $0.range.nsRange == range }?.kind == expected, "\(token)")
        }
        for function in ["CHAR(65)", "MOD(id"] {
            let range = (source as NSString).range(of: function)
            #expect(highlights.first { $0.range.location == range.location }?.kind == .function)
        }
    }

    @Test(arguments: [
        "CREATE INDEX idx ON users (id DESC, name ASC);",
        "CREATE TABLE users (id INT, name TEXT, INDEX idx (id DESC, name ASC));"
    ])
    func orderedIndexColumnsDoNotConsumeDirectionColors(_ source: String) async throws {
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: source))
        let highlights = try await parser.highlights(
            in: .init(location: 0, length: (source as NSString).length), revision: .init(1)
        )
        for (token, expected) in [("id", SQLSyntaxHighlight.Kind.property), ("name", .property),
                                  ("DESC", .attribute), ("ASC", .attribute)] {
            let range = (source as NSString).range(of: token, options: .backwards)
            #expect(highlights.first { $0.range.nsRange == range }?.kind == expected, "\(token)")
        }
        for pair in zip(highlights, highlights.dropFirst()) {
            #expect(pair.0.range.upperBound <= pair.1.range.location)
        }
    }

}
