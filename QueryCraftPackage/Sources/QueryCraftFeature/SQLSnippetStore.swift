import Foundation
import Observation

@MainActor
@Observable
final class SQLSnippetStore {
    static let shared = SQLSnippetStore(userDefaults: .standard)

    static let defaultSnippets: [SQLSnippet] = [
        SQLSnippet(
            name: "select *",
            trigger: "sel",
            content: "SELECT *\nFROM ${table}\nLIMIT 100;"
        ),
        SQLSnippet(
            name: "insert into",
            trigger: "ins",
            content: "INSERT INTO ${table} (${columns})\nVALUES (${values});"
        ),
        SQLSnippet(
            name: "update set",
            trigger: "upd",
            content: "UPDATE ${table}\nSET ${column} = ${value}\nWHERE ${condition};"
        ),
        SQLSnippet(
            name: "common table expression",
            trigger: "cte",
            content: """
                WITH ${name} AS (
                    SELECT ${columns}
                    FROM ${table}
                )
                SELECT *
                FROM ${name};
                """
        ),
        SQLSnippet(
            name: "join",
            trigger: "join",
            content: "JOIN ${table} ON ${left_column} = ${right_column}"
        ),
        SQLSnippet(
            name: "case when",
            trigger: "case",
            content: "CASE WHEN ${condition} THEN ${value} ELSE ${default} END"
        ),
        SQLSnippet(
            name: "create table",
            trigger: "ct",
            content: "CREATE TABLE ${table} (\n    ${column} ${type}\n);"
        ),
        SQLSnippet(
            name: "exists",
            trigger: "ex",
            content: "EXISTS (\n    SELECT 1\n    FROM ${table}\n    WHERE ${condition}\n)"
        ),
        SQLSnippet(
            name: "not exists",
            trigger: "nex",
            content: "NOT EXISTS (\n    SELECT 1\n    FROM ${table}\n    WHERE ${condition}\n)"
        ),
        SQLSnippet(
            name: "alter table add column",
            trigger: "at",
            content: "ALTER TABLE ${table}\nADD COLUMN ${column} ${type};"
        ),
        SQLSnippet(
            name: "create index",
            trigger: "ci",
            content: "CREATE INDEX ${idx_name}\nON ${table} (${column});"
        ),
    ]

    private(set) var snippets: [SQLSnippet] {
        didSet { persist() }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Key.snippets),
            let stored = try? JSONDecoder().decode(
                [SQLSnippet].self,
                from: data
            )
        {
            snippets = stored
        } else {
            snippets = Self.defaultSnippets
        }
    }

    var completionSources: [SQLSnippetCompletionSource] {
        snippets
            .filter(\.isEnabled)
            .map(SQLSnippetCompletionSource.init(snippet:))
    }

    func add(_ snippet: SQLSnippet) {
        snippets.append(snippet)
    }

    func update(_ snippet: SQLSnippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id })
        else {
            return
        }
        snippets[index] = snippet
    }

    func remove(id: UUID) {
        snippets.removeAll { $0.id == id }
    }

    func restoreDefaults() {
        snippets = Self.defaultSnippets
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        userDefaults.set(data, forKey: Key.snippets)
    }

    private enum Key {
        static let snippets = "preferences.editor.sqlSnippets.v1"
    }
}
