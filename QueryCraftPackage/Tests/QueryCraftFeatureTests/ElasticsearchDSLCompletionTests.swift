import Foundation
import Testing
@testable import QueryCraftFeature

struct ElasticsearchDSLCompletionTests {
    private let fields = [
        "areaCode", "areaCode.keyword", "areaName", "created_at", "message",
        "status", "status.keyword", "user.name",
    ]
    private let resources = [
        WorkspaceElasticsearchCompletionResource(
            name: "logs",
            kind: .elasticsearchIndex
        ),
        WorkspaceElasticsearchCompletionResource(
            name: "logs_alias",
            kind: .elasticsearchAlias
        ),
    ]

    @Test
    func searchTopLevelAndQueryClauseCompletionsAreContextual() async throws {
        let topSource = "POST /logs/_search\n{"
        let top = try await completions(topSource)
        #expect(top.map(\.label).contains("query"))
        #expect(top.map(\.label).contains("aggs"))
        #expect(top.map(\.label).contains("sort"))
        #expect(!top.map(\.label).contains("analyzer"))

        let querySource = "POST /logs/_search\n{\n  \"query\": {"
        let query = try await completions(querySource)
        #expect(query.map(\.label).contains("bool"))
        #expect(query.map(\.label).contains("term"))
        #expect(query.map(\.label).contains("match"))
        #expect(query.map(\.label).contains("range"))
        #expect(!query.map(\.label).contains("size"))
    }

    @Test
    func boolArraysReturnToQueryClauseContext() async throws {
        let source = """
            POST /logs/_search
            {
              "query": {
                "bool": {
                  "filter": [
                    {
            """
        let items = try await completions(source)
        #expect(items.map(\.label).contains("term"))
        #expect(items.map(\.label).contains("exists"))
        #expect(!items.map(\.label).contains("minimum_should_match"))
    }

    @Test
    func termMatchAndRangeOfferMappingFields() async throws {
        for queryKind in ["term", "match", "range"] {
            let source = """
                POST /logs/_search
                {
                  "query": {
                    "\(queryKind)": {
                """
            let items = try await completions(source)
            #expect(items.map(\.label).contains("status.keyword"))
            #expect(items.map(\.label).contains("user.name"))
            let field = try #require(items.first {
                $0.label == "status.keyword"
            })
            #expect(field.insertionText.contains("\"status.keyword\""))
            if queryKind == "range" {
                #expect(field.insertionText.contains("\"gte\""))
            }
        }
    }

    @Test
    func fieldCompletionUsesMySQLStyleFuzzyMatching() async throws {
        let source = """
            POST /logs/_search
            {
              "query": {
                "term": {
                  an
                }
              }
            }
            """
        let items = try await WorkspaceElasticsearchDSLCompletionWorker()
            .completions(
                source: source,
                cursor: (source as NSString).range(of: "an\n").location + 2,
                fields: fields,
                resources: resources,
                indentationUnit: "  "
            )

        let areaName = try #require(items.first { $0.label == "areaName" })
        let completed = applying(areaName, to: source)
        let body = completed.split(separator: "\n", maxSplits: 1)
            .dropFirst().first.map(String.init) ?? ""

        _ = try JSONSerialization.jsonObject(with: Data(body.utf8))
    }

    @Test
    func fieldCompletionReplacesAnAutoPairedClosingQuote() async throws {
        let source = """
            POST /logs/_search
            {
              "query": {
                "term": {
                  "ar"
                }
              }
            }
            """
        let quotedToken = (source as NSString).range(of: "\"ar\"")
        let cursor = quotedToken.location + quotedToken.length - 1
        let items = try await WorkspaceElasticsearchDSLCompletionWorker()
            .completions(
                source: source,
                cursor: cursor,
                fields: fields,
                resources: resources,
                indentationUnit: "  "
            )
        let field = try #require(items.first { $0.label == "areaCode" })

        #expect(field.requestCursorLocation == cursor)
        #expect(field.replacementRange.location == quotedToken.location)
        #expect(field.replacementRange.length >= quotedToken.length)
        let completed = applying(field, to: source)
        let body = completed.split(separator: "\n", maxSplits: 1)
            .dropFirst().first.map(String.init) ?? ""
        _ = try JSONSerialization.jsonObject(with: Data(body.utf8))
    }

    @Test
    func propertyCompletionLeavesTheParentObjectClosingToTheEditor() async throws {
        let source = "POST /logs/_search\n{"
        let query = try #require(
            try await completions(source).first { $0.label == "query" }
        )

        #expect(query.insertionText.filter { $0 == "}" }.count == 1)
        #expect(query.selectedRangeInInsertion.length == 0)
        #expect(
            query.selectedRangeInInsertion.location
                < (query.insertionText as NSString).length
        )
    }

    @Test
    func rootCompletionProducesCompleteJSONAndEditableSelection() async throws {
        let source = "POST /logs/_search\n"
        let query = try #require(
            try await completions(source).first { $0.label == "query" }
        )
        let completed = applying(query, to: source)
        let body = completed.split(separator: "\n", maxSplits: 1)
            .dropFirst().first.map(String.init) ?? ""

        _ = try JSONSerialization.jsonObject(with: Data(body.utf8))
        #expect(query.selectedRangeInInsertion.length == 0)
    }

    @Test
    func queryCompletionReusesAnExistingRootClosingBrace() async throws {
        let source = """
            POST /logs/_search
            {
            }
            """
        let openingBrace = (source as NSString).range(of: "{")
        let cursor = NSMaxRange(openingBrace)
        let items = try await WorkspaceElasticsearchDSLCompletionWorker()
            .completions(
                source: source,
                cursor: cursor,
                fields: fields,
                resources: resources,
                indentationUnit: "  "
            )
        let query = try #require(items.first { $0.label == "query" })
        let completed = applying(query, to: source)
        let body = completed.split(separator: "\n", maxSplits: 1)
            .dropFirst().first.map(String.init) ?? ""

        _ = try JSONSerialization.jsonObject(with: Data(body.utf8))
        #expect(body.filter { $0 == "{" }.count == 2)
        #expect(body.filter { $0 == "}" }.count == 2)
    }

    @Test
    func countHasCountSpecificTopLevelKeys() async throws {
        let items = try await completions("POST /logs/_count\n{")
        let labels = items.map(\.label)
        #expect(labels.contains("query"))
        #expect(labels.contains("terminate_after"))
        #expect(labels.contains("min_score"))
        #expect(!labels.contains("aggs"))
        #expect(!labels.contains("sort"))
    }

    @Test
    func analyzeHasAnalyzeSpecificTopLevelKeys() async throws {
        let items = try await completions("POST /logs/_analyze\n{")
        let labels = items.map(\.label)
        #expect(labels.contains("analyzer"))
        #expect(labels.contains("tokenizer"))
        #expect(labels.contains("filter"))
        #expect(labels.contains("char_filter"))
        #expect(labels.contains("text"))
        #expect(!labels.contains("query"))
    }

    @Test
    func sqlHasSQLSpecificTopLevelKeys() async throws {
        let items = try await completions("POST /_sql\n{")
        let labels = items.map(\.label)
        #expect(labels.contains("query"))
        #expect(labels.contains("params"))
        #expect(labels.contains("fetch_size"))
        #expect(labels.contains("time_zone"))
        #expect(labels.contains("columnar"))
        #expect(!labels.contains("aggs"))
    }

    @Test
    func msearchAlternatesHeaderAndSearchBodySchemas() async throws {
        let headerSource = "POST /_msearch\n"
        let headerItems = try await completions(headerSource)
        #expect(headerItems.map(\.label).contains("index"))
        #expect(headerItems.map(\.label).contains("routing"))
        #expect(!headerItems.map(\.label).contains("query"))

        let bodySource = "POST /_msearch\n{\"index\":\"logs\"}\n"
        let bodyItems = try await completions(bodySource)
        #expect(bodyItems.map(\.label).contains("query"))
        #expect(bodyItems.map(\.label).contains("size"))
        let resourceName = try await WorkspaceElasticsearchDSLCompletionWorker()
            .resourceName(
                source: bodySource,
                cursor: (bodySource as NSString).length
            )
        #expect(resourceName == "logs")
    }

    @Test
    func existingObjectKeysAreNotSuggestedAgain() async throws {
        let source = """
            POST /logs/_search
            {
              "size": 20,
            """
        let labels = try await completions(source).map(\.label)
        #expect(!labels.contains("size"))
        #expect(labels.contains("query"))
    }

    private func completions(
        _ source: String
    ) async throws -> [WorkspaceElasticsearchDSLCompletionItem] {
        try await WorkspaceElasticsearchDSLCompletionWorker().completions(
            source: source,
            cursor: (source as NSString).length,
            fields: fields,
            resources: resources,
            indentationUnit: "  "
        )
    }

    private func applying(
        _ item: WorkspaceElasticsearchDSLCompletionItem,
        to source: String
    ) -> String {
        let result = NSMutableString(string: source)
        result.replaceCharacters(
            in: item.replacementRange,
            with: item.insertionText
        )
        return result as String
    }
}
