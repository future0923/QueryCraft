import Foundation
import Testing
@testable import QueryCraftFeature

/// Markers assert exact source ranges, including repeated words in different semantic contexts.
struct SQLSyntaxCoverageTests {
    static let corpus: [String] = [
        // Common queries: aliases, qualification, aggregates, joins and subqueries.
        "«keyword|SELECT» «type|u».«property|id», «function|COUNT»(*) «keyword|AS» «variable|total» FROM «type|users» AS «variable|u» LEFT JOIN «type|orders» AS «variable|o» ON u.id = o.user_id GROUP BY u.id HAVING COUNT(*) > «number|2» ORDER BY total DESC LIMIT 10 OFFSET 5;",
        "SELECT «property|name» FROM users WHERE «keyword|EXISTS» (SELECT 1 FROM orders WHERE orders.user_id = users.id) AND id «keyword|IN» (1, 2) AND name «keyword|LIKE» «string|'A%'»;",
        "«keyword|WITH» «type|recent» AS (SELECT id FROM orders WHERE amount > 20) SELECT recent.id FROM recent «keyword|UNION» ALL SELECT id FROM archive;",
        "WITH «keyword|RECURSIVE» «type|seq»(«property|n») AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 5) SELECT n FROM seq;",
        "SELECT «keyword|CASE» «keyword|WHEN» «property|active» = «boolean|TRUE» «keyword|THEN» «string|'yes'» «keyword|ELSE» «string|'no'» «keyword|END» AS «variable|status», «function|COALESCE»(name, 'unknown') FROM users;",
        "SELECT «function|ROW_NUMBER»() «keyword|OVER» («keyword|PARTITION» BY dept_id ORDER BY salary DESC) AS rn, «function|SUM»(salary) OVER (ORDER BY id «keyword|ROWS» BETWEEN «attribute|UNBOUNDED» PRECEDING AND CURRENT ROW) FROM staff;",
        "SELECT «number|1.25», «number|1e3», «number|2.5E-4», «number|.75», «number|0xFF», «string|'123'»;",
        "SELECT «function|CAST»(amount AS «builtinType|DECIMAL»(10,2)), «function|LOWER»(name), «function|NOW»() FROM orders;",
        "SELECT «property|id» FROM «type|users» WHERE id = «parameter|?» OR id = «parameter|$1»;",
        "SELECT «property|`列名`», «property|`select`» FROM «type|`订单`» WHERE «property|`列名`» = «string|'中文😀'»;",
        // Without a dialect/SQL-mode input, bare double quotes retain MySQL string semantics.
        // Qualified quoted columns are unambiguous and must still be recognized.
        "SELECT «string|\"name\"», u.«property|\"name\"» FROM «type|\"public\"».«type|\"users\"» u;",
        // MySQL DML / DDL.
        "CREATE TABLE complex (id INT, parent_id INT, value INT, KEY «type|`idx_func`» ((«function|abs»(«property|`value`»))), CONSTRAINT «type|`fk_parent`» «keyword|FOREIGN» KEY («property|`parent_id`») «keyword|REFERENCES» «type|`other`».«type|`parents`» («property|`id`»), KEY «type|`idx_tail`» («property|`value`»));",
        "CREATE TABLE t (`key` INT, note TEXT DEFAULT 'FOREIGN KEY (fake) REFERENCES fake (id)', KEY «type|idx_expr» ((«function|lower»(«property|note»)), «property|`key`»));",
        "«keyword|INSERT» INTO «type|users» («property|id», «property|name») VALUES (1, 'a'), (2, 'b') ON «keyword|DUPLICATE» KEY UPDATE «property|name» = «function|VALUES»(name);",
        "UPDATE «type|users» SET «property|name» = 'b', «property|active» = «boolean|FALSE» WHERE «property|id» = 1; DELETE FROM users WHERE id = 2;",
        "CREATE TABLE «type|users» («property|id» «builtinType|BIGINT» UNSIGNED NOT NULL AUTO_INCREMENT, «property|name» «builtinType|VARCHAR»(100) DEFAULT 'x', PRIMARY KEY («property|id»), UNIQUE KEY «type|uk_name» («property|name»));",
        "CREATE TABLE «type|orders» (id INT, «property|user_id» INT, CONSTRAINT «type|fk_user» FOREIGN KEY («property|user_id») REFERENCES «type|users» («property|id»));",
        "ALTER TABLE users «keyword|MODIFY» COLUMN «property|name» «builtinType|VARCHAR»(200); ALTER TABLE users «keyword|RENAME» COLUMN «property|name» TO «property|full_name»; ALTER TABLE users DROP COLUMN «property|active»;",
        "ALTER TABLE users ADD KEY «type|idx_pair» («property|type», «property|name»(«number|8»)), ADD INDEX «type|idx_other» («property|active»);",
        "CREATE VIEW «type|active_users» AS SELECT id FROM users WHERE active = 1; «keyword|EXPLAIN» SELECT id FROM users; «keyword|TRUNCATE» TABLE users;",
        // PostgreSQL: casts, JSON, arrays, returning, conflict and dollar strings.
        "SELECT «property|payload» «operator|->>» «string|'name'», «property|amount»«operator|::»«builtinType|numeric» FROM events;",
        "SELECT «function|ARRAY»[«number|1», 2], «string|$$hello; SELECT 😀$$», «string|$tag$quoted ' text$tag$»;",
        "INSERT INTO users (id, name) VALUES (1, 'a') ON «keyword|CONFLICT» (id) «keyword|DO» UPDATE SET «property|name» = excluded.name «keyword|RETURNING» «property|id»;",
        "SELECT «function|COUNT»(*) «keyword|FILTER» (WHERE active) FROM users; SELECT «property|id» FROM users WHERE name «keyword|ILIKE» 'a%';",
        "CREATE INDEX «type|idx_lower» ON «type|users» («function|lower»(«property|name»)) WHERE «property|active» = TRUE;",
        // Doris common queries and table clauses.
        "CREATE TABLE audit_log («property|`query_id`» «builtinType|varchar»(128) «boolean|NULL», «property|`time`» «builtinType|datetime»(3) «boolean|NULL», «property|`client_ip`» «builtinType|varchar»(128) «boolean|NULL», «property|`error_code`» «builtinType|int» «boolean|NULL», «property|`cpu_time_ms`» «builtinType|bigint» «boolean|NULL») DUPLICATE KEY (`query_id`) DISTRIBUTED BY HASH (`query_id`) BUCKETS 1;",
        "CREATE TABLE t («property|`NULL`» «builtinType|VARCHAR»(40) DEFAULT «string|'id INT, wrong TEXT NULL'», «property|created» «builtinType|DATETIMEV2»(3), «property|note» «builtinType|VARCHAR»(20), «property|amount» «builtinType|DECIMAL»(10,2));",
        "SELECT «function|IFNULL»(«property|name», 'none'), «function|BITMAP_COUNT»(«property|user_bitmap») FROM «type|events» GROUP BY name, user_bitmap;",
        "CREATE TABLE «type|events» («property|id» BIGINT, «property|name» VARCHAR(32)) «keyword|DUPLICATE» KEY («property|id») «keyword|DISTRIBUTED» BY «function|HASH» («property|id») «keyword|BUCKETS» «number|8» «keyword|PROPERTIES» («string|\"replication_num\"» = «string|\"1\"»);",
        // Comments, transaction boundaries, statement recovery and mixed case.
        "«comment|-- SELECT name FROM fake;»\nSELECT «string|'ALTER TABLE fake ADD INDEX x (id)'», «number|42»; «comment|/* INSERT INTO fake */»",
        "«keyword|START» «keyword|TRANSACTION»; UPDATE users SET active = 1; «keyword|COMMIT»; «keyword|BEGIN»; «keyword|ROLLBACK»;",
        "«keyword|sElEcT» «property|name» «keyword|fRoM» «type|users» «keyword|wHeRe» active = «boolean|true»;",
        "SELECT «property|name», «function|COUNT»(«property|id») FROM «type|users» WHERE",
        "ALTER TABLE users ADD INDEX «type|idx_open» («property|type», «property|name»",
        "SELECT «operator|-»«number|42», «operator|+»«number|3.5E+2», «number|0b1010», «number|0o77», «number|1_000», «number|1.»;",
        "SELECT «string|$$ALTER TABLE t ADD INDEX fake (wrong);$$», «property|id» FROM users;",
        "SELECT «string|$body$😀; ALTER TABLE t ADD INDEX fake (wrong);$body$»; ALTER TABLE t ADD INDEX real_idx («property|id»);",
        "SELECT «string|E'hello\\nworld'», «string|'it''s a string'», «string|X'FF'», «string|B'101'»;",
        "«comment|# ALTER TABLE t ADD INDEX fake (wrong)»\nSELECT «property|buckets», «property|distributed», «property|properties» FROM users;",
        "SELECT id FROM users; «comment|/* unfinished SELECT 1e3 ALTER TABLE t ADD INDEX fake (wrong)»",
        "SELECT «string|'unfinished 2.5E-4 ALTER TABLE t ADD INDEX fake (wrong)»",
        "CREATE TABLE t (id BIGINT) UNIQUE KEY («property|id») DISTRIBUTED BY «keyword|RANDOM» «keyword|BUCKETS» «keyword|AUTO» PROPERTIES («string|\"enable_unique_key_merge_on_write\"» = «string|\"true\"»);",
        // More DDL: generated columns, constraints, qualified names and schema changes.
        "CREATE TABLE invoice («property|price» DECIMAL(10,2), «property|qty» INT, «property|total» DECIMAL(12,2) GENERATED ALWAYS AS («property|price» * «property|qty») STORED);",
        "CREATE TABLE account (id INT, «property|balance» DECIMAL(12,2), CONSTRAINT «type|positive_balance» CHECK («property|balance» >= «number|0»));",
        "ALTER TABLE users CHANGE COLUMN «property|name» «property|full_name» «builtinType|VARCHAR»(200);",
        "ALTER TABLE orders ADD CONSTRAINT «type|fk_order_user» FOREIGN KEY («property|user_id») REFERENCES «type|users» («property|id»);",
        "CREATE TABLE «type|public».«type|events» («property|id» «builtinType|UUID», «property|data» «builtinType|JSONB», «property|created_at» «builtinType|TIMESTAMPTZ»);",
        "CREATE TABLE child («property|parent_id» INT REFERENCES «type|parent» («property|id»), «property|name» TEXT);",
        "CREATE UNIQUE INDEX «type|idx_name» ON «type|public».«type|users» («property|name» DESC, «property|id» ASC);",
        "CREATE MATERIALIZED VIEW «type|daily_totals» AS SELECT «property|day», «function|SUM»(«property|amount») FROM sales GROUP BY day;",
        "CREATE SCHEMA «type|analytics»; DROP TABLE IF EXISTS «type|analytics».«type|events»;",
        // Subqueries, CTE lists, joins, tuple expressions and window frames.
        "WITH «type|a»(«property|id») AS (SELECT id FROM users), «type|b» AS (SELECT id FROM a) SELECT «type|b».«property|id» FROM b;",
        "SELECT «type|q».«property|id» FROM (SELECT id FROM users) AS «variable|q» WHERE q.id > 0;",
        "SELECT u.id FROM users u CROSS JOIN «keyword|LATERAL» (SELECT «function|MAX»(«property|amount») AS total FROM orders WHERE user_id = u.id) o;",
        "SELECT «function|LAG»(«property|salary», «number|1», «number|0») OVER (PARTITION BY dept_id ORDER BY id) FROM staff;",
        "SELECT «function|SUM»(«property|amount») OVER (ORDER BY id ROWS BETWEEN «number|2» PRECEDING AND «number|1» FOLLOWING) FROM orders;",
        "SELECT «property|id» FROM users WHERE («property|id», «property|name») IN ((«number|1», «string|'a'»), (2, 'b'));",
        "SELECT id FROM users «keyword|INTERSECT» SELECT id FROM staff «keyword|EXCEPT» SELECT id FROM archived;",
        "SELECT «function|NULLIF»(«property|name», «string|''»), «function|CONCAT»(name, '-', id) FROM users WHERE deleted_at IS «boolean|NULL»;",
        // DML and expressions used by the three SQL drivers.
        "INSERT INTO «type|archive» («property|id», «property|name») SELECT «property|id», «property|name» FROM «type|users»;",
        "REPLACE INTO «type|cache» («property|id», «property|value») VALUES («number|1», «string|'cached'»);",
        "UPDATE users u JOIN orders o ON u.id = o.user_id SET u.«property|active» = «boolean|TRUE» WHERE o.«property|amount» > «number|10»;",
        "SELECT «property|payload» «operator|->» «string|'items'» «operator|->>» «number|0» FROM events;",
        "SELECT «function|JSON_EXTRACT»(«property|payload», «string|'$.items[0].name'»), «function|JSON_UNQUOTE»(payload) FROM events;",
        "SELECT «number|1» «operator|<=» «number|2», 2 «operator|<>» 3, 4 «operator|!=» 5, 6 «operator|>=» 1;",
        "SELECT «builtinType|DATE» «string|'2026-10-14'», «builtinType|INTERVAL» «string|'2 days'»;",
        "CREATE TABLE metrics (id BIGINT, amount BIGINT SUM) «keyword|AGGREGATE» KEY («property|id») DISTRIBUTED BY HASH («property|id») BUCKETS «number|16»;",
        // Opaque quoted content, comments and Unicode offsets.
        "SELECT «property|`a``b`» FROM «type|`table``name`»;",
        "SELECT u.«property|\"a\"\"b\"» FROM users u;",
        "SELECT «string|N'中文'», «string|U&'d\\0061t'», «string|E'it\\'s ok'»;",
        "SELECT «string|$A$inside $a$ 1e9 -- comment $A$», «number|1E+9»;",
        "«comment|/* 😀 comment */»\r\nSELECT «property|id», «string|'👨‍👩‍👧‍👦 é'» FROM users;",
        "SELECT «comment|/*+ MAX_EXECUTION_TIME(1000) */» «property|id» FROM users;",
        "«comment|/*!40101 SET NAMES utf8mb4 */» SELECT «number|10»;",
        "SELECT «string|'# not a comment /* nor this */ -- SELECT 1'», «number|7»;",
        "SELECT «number|1»«operator|-»«number|2», «number|3»«operator|+»«number|4»; «comment|-- done»",
        "SELECT «string|$$unfinished 😀 SELECT 1e9 ALTER TABLE t ADD INDEX fake (x)»",
        "ALTER TABLE t ADD INDEX «type|idx_prefix» («property|name»(«number|16») DESC, «property|id» ASC);",
        "SELECT «string|\"a\"\"b; -- still a string\"», «number|42»;",
        "SELECT «property|`a``;DROP TABLE fake;--b`» FROM «type|`table``name`»; SELECT «number|42»;",
        "SELECT u.«property|\"a\"\";DROP TABLE fake;--b\"» FROM users u; SELECT «number|42»;",
        "SELECT «builtinType|TIMESTAMP» «string|'2026-10-14 12:30:00'», «builtinType|UUID» «string|'123e4567-e89b-12d3-a456-426614174000'»;",
    ]

    struct Expected {
        let range: NSRange
        let kind: String
        let token: String
    }

    static func decode(_ marked: String) throws -> (String, [Expected]) {
        let pattern = try NSRegularExpression(pattern: "«([a-zA-Z]+)\\|([^»]*)»")
        let input = marked as NSString
        var source = ""
        var expected: [Expected] = []
        var end = 0
        for match in pattern.matches(in: marked, range: NSRange(location: 0, length: input.length)) {
            source += input.substring(with: NSRange(location: end, length: match.range.location - end))
            let token = input.substring(with: match.range(at: 2))
            expected.append(.init(range: NSRange(location: (source as NSString).length, length: (token as NSString).length),
                                  kind: input.substring(with: match.range(at: 1)), token: token))
            source += token
            end = NSMaxRange(match.range)
        }
        source += input.substring(from: end)
        return (source, expected)
    }

    @Test(arguments: corpus)
    func classifiesDialectCorpus(_ marked: String) async throws {
        let (source, expected) = try Self.decode(marked)
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: source))
        let highlights = try await parser.highlights(
            in: .init(location: 0, length: (source as NSString).length), revision: .init(1)
        )
        for item in expected {
            var covered = IndexSet()
            for highlight in highlights where String(describing: highlight.kind) == item.kind {
                let overlap = NSIntersectionRange(highlight.range.nsRange, item.range)
                if overlap.length > 0 { covered.insert(integersIn: overlap.location..<NSMaxRange(overlap)) }
            }
            #expect(covered.count == item.range.length, "Expected \(item.kind) for \(item.token) in \(source)")
        }
        for pair in zip(highlights, highlights.dropFirst()) {
            #expect(pair.0.range.upperBound <= pair.1.range.location, "Overlapping captures in \(source)")
        }
        for item in expected {
            let requested = SQLSourceRange(location: item.range.location, length: max(1, item.range.length / 2))
            let partial = try await parser.highlights(in: requested, revision: .init(1))
            let clipped = highlights.compactMap { highlight -> SQLSyntaxHighlight? in
                let overlap = NSIntersectionRange(highlight.range.nsRange, requested.nsRange)
                return overlap.length > 0 ? .init(range: .init(overlap), kind: highlight.kind) : nil
            }
            #expect(partial == clipped, "Partial capture differs for \(item.token) in \(source)")
        }
    }

    @Test(arguments: [
        "SELECT '中文😀', 2.5E-4 FROM users WHERE id = $1;",
        "ALTER TABLE t ADD INDEX idx ((lower(name)), type);",
        "CREATE TABLE t (id INT) DUPLICATE KEY (id) DISTRIBUTED BY HASH (id) BUCKETS 8;",
        "SELECT $$ALTER TABLE t ADD INDEX fake (wrong);$$; SELECT name FROM users;"
    ])
    func incrementalTypingAndDeletingMatchesFreshParse(_ source: String) async throws {
        let parser = try SQLStructuralParser()
        var current = ""
        var revision: UInt64 = 1
        _ = try await parser.parse(.init(revision: .init(revision), text: current))
        let prefixes = source.indices.map { String(source[...$0]) }
        for next in prefixes + prefixes.dropLast().reversed() {
            let oldLength = (current as NSString).length
            let newLength = (next as NSString).length
            let location = min(oldLength, newLength)
            let replacement = (next as NSString).substring(from: location)
            _ = try await parser.parse(.init(revision: .init(revision + 1), text: next), applying: .init(
                baseRevision: .init(revision), replacedRange: .init(location: location, length: oldLength - location),
                replacement: replacement
            ))
            revision += 1
            current = next
            let fresh = try SQLStructuralParser()
            _ = try await fresh.parse(.init(revision: .init(1), text: next))
            let range = SQLSourceRange(location: 0, length: newLength)
            let incremental = try await parser.highlights(in: range, revision: .init(revision))
            let complete = try await fresh.highlights(in: range, revision: .init(1))
            #expect(incremental == complete, "Incremental mismatch: \(next)")
            #expect(incremental.allSatisfy { $0.range.location >= 0 && $0.range.upperBound <= newLength })
        }
    }

    @Test(arguments: [
        "SELECT id, '中文😀', 2.5E+4 FROM users; SELECT payload->>'name' FROM events;",
        "CREATE TABLE t (id INT, name VARCHAR(20)) DUPLICATE KEY (id) DISTRIBUTED BY HASH (id) BUCKETS 8;",
        "ALTER TABLE t ADD INDEX idx (name(8), id); /* comment */ SELECT $$opaque ; SQL$$;"
    ])
    func middleEditsAndUndoMatchFreshParse(_ initial: String) async throws {
        let parser = try SQLStructuralParser()
        var current = initial
        var revision: UInt64 = 1
        _ = try await parser.parse(.init(revision: .init(revision), text: current))
        // Character boundaries protect surrogate pairs/combining marks; edits cross lexical contexts.
        for fraction in [0, 1, 2, 3] {
            for insertion in ["'", "/*", "*/", "-- 😀\n", "$tag$", ";\nSELECT 1E+6;", "\"", "`", "👨‍👩‍👧‍👦"] {
                let characterIndex = initial.index(initial.startIndex, offsetBy: initial.count * fraction / 3)
                let location = initial[..<characterIndex].utf16.count
                let replaced = initial[characterIndex...].prefix(3)
                let oldRange = NSRange(location: location, length: replaced.utf16.count)
                let edited = (initial as NSString).replacingCharacters(in: oldRange, with: insertion)
                for (next, range, replacement) in [
                    (edited, oldRange, insertion),
                    (initial, NSRange(location: location, length: insertion.utf16.count), String(replaced))
                ] {
                    _ = try await parser.parse(.init(revision: .init(revision + 1), text: next), applying: .init(
                        baseRevision: .init(revision), replacedRange: .init(range), replacement: replacement
                    ))
                    revision += 1
                    current = next
                    let fresh = try SQLStructuralParser()
                    _ = try await fresh.parse(.init(revision: .init(1), text: next))
                    let requested = SQLSourceRange(location: 0, length: next.utf16.count)
                    let actual = try await parser.highlights(in: requested, revision: .init(revision))
                    let expected = try await fresh.highlights(in: requested, revision: .init(1))
                    #expect(actual == expected, "Middle edit mismatch at \(range): \(next)")
                }
            }
        }
        #expect(current == initial)
    }

    @Test
    func longDocumentViewportsAndEmptyReplacement() async throws {
        let statement = "SELECT id, '中文😀', 1.25E+3 FROM users WHERE active = TRUE;\n"
        let source = String(repeating: statement, count: 300)
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: source))
        let full = try await parser.highlights(in: .init(location: 0, length: source.utf16.count), revision: .init(1))
        #expect(full.filter { $0.kind == .property }.count == 600)
        for location in stride(from: 0, to: source.utf16.count, by: 137) {
            let range = NSRange(location: location, length: min(83, source.utf16.count - location))
            let partial = try await parser.highlights(in: .init(range), revision: .init(1))
            let clipped = full.compactMap { highlight -> SQLSyntaxHighlight? in
                let overlap = NSIntersectionRange(highlight.range.nsRange, range)
                return overlap.length > 0 ? .init(range: .init(overlap), kind: highlight.kind) : nil
            }
            #expect(partial == clipped, "Viewport mismatch at \(range)")
        }
        _ = try await parser.parse(.init(revision: .init(2), text: ""), applying: .init(
            baseRevision: .init(1), replacedRange: .init(location: 0, length: source.utf16.count), replacement: ""
        ))
        #expect(try await parser.highlights(in: .init(location: 0, length: 0), revision: .init(2)).isEmpty)
        _ = try await parser.parse(.init(revision: .init(3), text: statement), applying: .init(
            baseRevision: .init(2), replacedRange: .init(location: 0, length: 0), replacement: statement
        ))
        let restored = try await parser.highlights(in: .init(location: 0, length: statement.utf16.count), revision: .init(3))
        #expect(restored.contains { $0.kind == .property })
    }
}
