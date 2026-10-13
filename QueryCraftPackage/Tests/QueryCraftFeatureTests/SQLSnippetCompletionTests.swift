import Foundation
import Testing

@testable import QueryCraftFeature

struct SQLSnippetCompletionTests {
    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris])
    func snippetsUseTheSameDocumentRangesAcrossSQLDrivers(databaseType: DatabaseType) async throws {
        let text = "SELECT 1;\nsel"
        let revision = SQLSourceRevision(1)
        let source = SQLSourceSnapshot(revision: revision, text: text)
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(source)
        let result = try #require(try SQLCompletionEngine.completions(for: .init(
            source: source, cursorLocation: text.utf16.count,
            parseSnapshot: snapshot, schemaCatalog: .empty, defaultDatabase: nil,
            databaseType: databaseType, snippets: [Self.selectSnippet]
        )))
        let item = try #require(result.items.first { $0.kind == .snippet })
        #expect(item.replacementRange == SQLSourceRange(location: 10, length: 3))
        #expect(item.selectionRanges == [SQLSourceRange(location: 24, length: 5)])
    }

    @Test
    func ranksTriggerMatchFirstAndExposesInsertionAndSelection() async throws {
        let result = try await completions(
            for: "sel",
            snippets: [Self.selectSnippet]
        )
        let snippet = try #require(result.items.first)

        #expect(snippet.label == "select *")
        #expect(snippet.kind == .snippet)
        #expect(snippet.insertionText == "SELECT *\nFROM table\nLIMIT 100;")
        #expect(snippet.detail == "SELECT * FROM ${table} LIMIT 100;")
        #expect(snippet.replacementRange == SQLSourceRange(location: 0, length: 3))
        #expect(snippet.cursorOffset == 0)
        #expect(snippet.selectionRanges == [
            SQLSourceRange(location: 14, length: 5),
        ])
        #expect(
            result.items.contains { $0.label == "SELECT" && $0.kind == .keyword }
        )
    }

    @Test
    func mapsPlaceholderRangesToTheDocumentPositions() async throws {
        let source = "SELECT 1;\nsel"
        let result = try await completions(
            for: source,
            snippets: [Self.selectSnippet]
        )
        let snippet = try #require(result.items.first)

        #expect(snippet.kind == .snippet)
        #expect(snippet.replacementRange == SQLSourceRange(location: 10, length: 3))
        #expect(snippet.selectionRanges == [
            SQLSourceRange(location: 24, length: 5),
        ])
    }

    @Test
    func matchesSnippetsOnlyByTriggerLetters() async throws {
        let byNamePrefix = try await completions(
            for: "comm",
            snippets: [Self.cteSnippet]
        )
        #expect(byNamePrefix.items.contains { $0.kind == .snippet } == false)

        let byNameFuzzy = try await completions(
            for: "st",
            snippets: [Self.selectSnippet]
        )
        #expect(byNameFuzzy.items.contains { $0.kind == .snippet } == false)

        let byTriggerPrefix = try await completions(
            for: "se",
            snippets: [Self.selectSnippet]
        )
        #expect(byTriggerPrefix.items.first?.kind == .snippet)

        let byTriggerFuzzy = try await completions(
            for: "sl",
            snippets: [Self.selectSnippet]
        )
        #expect(byTriggerFuzzy.items.first?.kind == .snippet)
    }

    @Test(arguments: ["", "SELECT 1; ", "\n\n"])
    func hidesSnippetsWithoutATypedPrefix(_ source: String) async throws {
        let result = try await optionalCompletions(
            for: source,
            snippets: [Self.selectSnippet]
        )

        #expect(
            result?.items.contains { $0.kind == .snippet } != true
        )
    }

    @Test
    func hidesSnippetsInQualifiedContexts() async throws {
        let result = try await completions(
            for: "SELECT * FROM app.us",
            snippets: [Self.qualifiedSnippet],
            catalog: Self.catalog,
            defaultDatabase: "app"
        )

        #expect(result.items.first?.label == "users")
        #expect(result.items.first?.kind == .table)
        #expect(result.items.contains { $0.kind == .snippet } == false)
    }

    private func completions(
        for source: String,
        snippets: [SQLSnippetCompletionSource] = [],
        catalog: WorkspaceSchemaCatalogSnapshot = Self.catalog,
        defaultDatabase: String? = nil
    ) async throws -> SQLCompletionResult {
        try #require(
            await optionalCompletions(
                for: source,
                snippets: snippets,
                catalog: catalog,
                defaultDatabase: defaultDatabase
            )
        )
    }

    private func optionalCompletions(
        for source: String,
        snippets: [SQLSnippetCompletionSource] = [],
        catalog: WorkspaceSchemaCatalogSnapshot = Self.catalog,
        defaultDatabase: String? = nil
    ) async throws -> SQLCompletionResult? {
        let revision = SQLSourceRevision(1)
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(
            SQLSourceSnapshot(revision: revision, text: source)
        )
        return try SQLCompletionEngine.completions(
            for: SQLCompletionEngine.Request(
                source: SQLSourceSnapshot(revision: revision, text: source),
                cursorLocation: (source as NSString).length,
                parseSnapshot: snapshot,
                schemaCatalog: catalog,
                defaultDatabase: defaultDatabase,
                snippets: snippets
            )
        )
    }

    private static let selectSnippet = SQLSnippetCompletionSource(
        snippet: SQLSnippet(
            name: "select *",
            trigger: "sel",
            content: "SELECT *\nFROM ${table}\nLIMIT 100;"
        )
    )

    private static let cteSnippet = SQLSnippetCompletionSource(
        snippet: SQLSnippet(
            name: "common table expression",
            trigger: "cte",
            content: "WITH ${name} AS (\n    SELECT ${columns}\n)"
        )
    )

    private static let qualifiedSnippet = SQLSnippetCompletionSource(
        snippet: SQLSnippet(
            name: "users template",
            trigger: "us",
            content: "SELECT * FROM ${table};"
        )
    )

    private static let catalog = WorkspaceSchemaCatalogSnapshot(
        revision: 1,
        databases: [
            WorkspaceSchemaDatabase(
                name: "app",
                objects: [
                    WorkspaceSchemaObject(
                        name: "users",
                        kind: .table,
                        columns: []
                    )
                ]
            )
        ]
    )
}
