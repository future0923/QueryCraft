import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class SQLSnippetStore {
    static let shared = SQLSnippetStore(userDefaults: .standard)

    static let defaultSnippets: [SQLSnippet] = seededDefaultSnippets.map { snippet in
        var snippet = snippet
        snippet.id = defaultSnippetID(trigger: snippet.trigger)
        return snippet
    }

    /// Stable across launches and devices so iCloud sync merges the built-in
    /// snippets instead of duplicating them.
    static func defaultSnippetID(trigger: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("QueryCraft.defaultSnippet.\(trigger)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static let seededDefaultSnippets: [SQLSnippet] = [
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
        didSet {
            persist()
            if !isApplyingRemoteChanges { reportLocalChanges(from: oldValue) }
        }
    }

    /// Receives IDs edited or deleted locally, for iCloud sync.
    @ObservationIgnored var onLocalChange: ((_ changed: [UUID], _ deleted: [UUID]) -> Void)?
    @ObservationIgnored private var isApplyingRemoteChanges = false

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

    enum TriggerIssue: Equatable { case required, whitespace, duplicate }
    func triggerIssue(_ trigger: String, excluding id: UUID? = nil) -> TriggerIssue? {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .required }
        if trimmed.contains(where: { $0.isWhitespace }) { return .whitespace }
        if snippets.contains(where: { $0.id != id && $0.trigger.caseInsensitiveCompare(trimmed) == .orderedSame }) { return .duplicate }
        return nil
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

    func cloudSyncValue(id: UUID) -> CloudSyncSnippet? {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return nil }
        let snippet = snippets[index]
        return CloudSyncSnippet(id: snippet.id, name: snippet.name, trigger: snippet.trigger,
                                content: snippet.content, isEnabled: snippet.isEnabled, sortIndex: index)
    }

    /// Applies snippets from iCloud. A remote snippet that reuses the trigger
    /// of a different local snippet replaces it when identical; otherwise the
    /// local one is renamed. Returns local edits/deletions that must be
    /// uploaded as a result.
    @discardableResult
    func applyRemoteChanges(
        upserts: [CloudSyncSnippet],
        deletions: [UUID]
    ) -> (changed: [UUID], deleted: [UUID]) {
        var result = snippets
        var changed: [UUID] = []
        var deleted: [UUID] = []
        let removed = Set(deletions)
        result.removeAll { removed.contains($0.id) }
        for remote in upserts.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            let snippet = SQLSnippet(id: remote.id, name: remote.name, trigger: remote.trigger,
                                     content: remote.content, isEnabled: remote.isEnabled)
            if let clash = result.firstIndex(where: {
                $0.id != remote.id && $0.trigger.caseInsensitiveCompare(remote.trigger) == .orderedSame
            }) {
                let local = result[clash]
                if local.name == remote.name && local.content == remote.content {
                    result.remove(at: clash)
                    deleted.append(local.id)
                } else {
                    result[clash].trigger = Self.uniqueTrigger(local.trigger, in: result + [snippet])
                    changed.append(local.id)
                }
            }
            if let index = result.firstIndex(where: { $0.id == remote.id }) {
                result[index] = snippet
            } else {
                result.insert(snippet, at: min(max(remote.sortIndex, 0), result.count))
            }
        }
        isApplyingRemoteChanges = true
        snippets = result
        isApplyingRemoteChanges = false
        return (changed, deleted)
    }

    private static func uniqueTrigger(_ base: String, in snippets: [SQLSnippet]) -> String {
        var suffix = 2
        while true {
            let candidate = "\(base)\(suffix)"
            if !snippets.contains(where: { $0.trigger.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return candidate
            }
            suffix += 1
        }
    }

    private func reportLocalChanges(from oldValue: [SQLSnippet]) {
        guard let onLocalChange else { return }
        let previous = Dictionary(oldValue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Set(snippets.map(\.id))
        let changed = snippets.filter { previous[$0.id] != $0 }.map(\.id)
        let deleted = oldValue.map(\.id).filter { !current.contains($0) }
        if !changed.isEmpty || !deleted.isEmpty { onLocalChange(changed, deleted) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        userDefaults.set(data, forKey: Key.snippets)
    }

    private enum Key {
        static let snippets = "preferences.editor.sqlSnippets.v1"
    }
}
