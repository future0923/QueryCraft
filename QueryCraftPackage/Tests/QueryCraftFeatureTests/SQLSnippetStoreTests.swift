import Foundation
import Testing

#if os(iOS)
import QueryCraftMobileCore
@testable import QueryCraftMobileProof
#else
@testable import QueryCraftFeature
#endif

@MainActor
struct SQLSnippetStoreTests {
    @Test
    func validatesTriggersWithTheSameRulesForAllEditors() throws {
        let store = SQLSnippetStore(userDefaults: makeUserDefaults())
        let select = try #require(store.snippets.first { $0.trigger == "sel" })
        #expect(store.triggerIssue(" \n") == .required)
        #expect(store.triggerIssue("two words") == .whitespace)
        #expect(store.triggerIssue(" SEL ") == .duplicate)
        #expect(store.triggerIssue("SEL", excluding: select.id) == nil)
        #expect(store.triggerIssue("my_custom") == nil)
    }

    @Test
    func seedsTheDefaultSnippetsWhenNothingIsStored() {
        let store = SQLSnippetStore(userDefaults: makeUserDefaults())

        #expect(store.snippets == SQLSnippetStore.defaultSnippets)
        #expect(store.snippets.count == 11)
        #expect(store.snippets.contains { $0.trigger == "sel" })
    }

    @Test
    func persistsChangesAcrossStoreInstances() {
        let defaults = makeUserDefaults()
        let store = SQLSnippetStore(userDefaults: defaults)
        let snippet = SQLSnippet(
            name: "explain",
            trigger: "exp",
            content: "EXPLAIN ${statement};"
        )

        store.add(snippet)

        let reloaded = SQLSnippetStore(userDefaults: defaults)
        #expect(reloaded.snippets.count == 12)
        #expect(reloaded.snippets.contains(snippet))
    }

    @Test
    func keepsAnEmptyListInsteadOfReseedingDefaults() {
        let defaults = makeUserDefaults()
        let store = SQLSnippetStore(userDefaults: defaults)

        for snippet in store.snippets {
            store.remove(id: snippet.id)
        }

        let reloaded = SQLSnippetStore(userDefaults: defaults)
        #expect(store.snippets.isEmpty)
        #expect(reloaded.snippets.isEmpty)
    }

    @Test
    func updateReplacesOnlyTheMatchingSnippet() throws {
        let store = SQLSnippetStore(userDefaults: makeUserDefaults())
        var snippet = try #require(store.snippets.first)
        snippet.name = "renamed"

        store.update(snippet)
        #expect(store.snippets.first == snippet)
        #expect(store.snippets.count == SQLSnippetStore.defaultSnippets.count)

        let unknown = SQLSnippet(
            name: "unknown",
            trigger: "unk",
            content: "SELECT 1;"
        )
        store.update(unknown)
        #expect(store.snippets.contains { $0.id == unknown.id } == false)
        #expect(store.snippets.count == SQLSnippetStore.defaultSnippets.count)
    }

    @Test
    func removeDeletesTheSnippet() throws {
        let store = SQLSnippetStore(userDefaults: makeUserDefaults())
        let removed = try #require(store.snippets.first)

        store.remove(id: removed.id)

        #expect(store.snippets.count == 10)
        #expect(store.snippets.contains { $0.id == removed.id } == false)
    }

    @Test
    func restoreDefaultsResetsEveryChange() {
        let store = SQLSnippetStore(userDefaults: makeUserDefaults())
        if let first = store.snippets.first {
            store.remove(id: first.id)
        }
        store.add(
            SQLSnippet(name: "custom", trigger: "cst", content: "SELECT 1;")
        )

        store.restoreDefaults()

        #expect(store.snippets == SQLSnippetStore.defaultSnippets)
    }

    @Test
    func completionSourcesSkipDisabledSnippets() throws {
        let store = SQLSnippetStore(userDefaults: makeUserDefaults())
        var select = try #require(store.snippets.first { $0.trigger == "sel" })
        select.isEnabled = false
        store.update(select)

        let sources = store.completionSources
        #expect(sources.contains { $0.trigger == "sel" } == false)
        #expect(sources.count == store.snippets.count - 1)
    }

    @Test
    func completionSourcesExposeParsedTemplates() throws {
        let store = SQLSnippetStore(userDefaults: makeUserDefaults())

        let source = try #require(
            store.completionSources.first { $0.trigger == "sel" }
        )

        #expect(source.name == "select *")
        #expect(source.insertionText == "SELECT *\nFROM table\nLIMIT 100;")
        #expect(source.previewText == "SELECT * FROM ${table} LIMIT 100;")
        #expect(source.placeholderRanges == [
            SQLSourceRange(location: 14, length: 5),
        ])
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "SQLSnippetStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create UserDefaults suite \(suiteName)")
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
