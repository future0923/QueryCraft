import Foundation
import QueryCraftFeature
import Testing
@testable import QueryCraftElasticsearchDriver

@Suite("Elasticsearch mapping and filters")
struct ElasticsearchMappingAndFilterTests {
    @Test("Flattens mappings, detects conflicts, and resolves keyword fields")
    func mappingCatalog() throws {
        let mapping = Data("""
        {
          "logs-a":{"mappings":{"properties":{
            "message":{"type":"text","fields":{"keyword":{"type":"keyword"}}},
            "status":{"type":"integer"},
            "user":{"properties":{"name":{"type":"keyword"}}}
          }}},
          "logs-b":{"mappings":{"properties":{"status":{"type":"keyword"}}}}
        }
        """.utf8)
        let caps = Data("""
        {"fields":{
          "message":{"text":{"searchable":true,"aggregatable":false}},
          "message.keyword":{"keyword":{"searchable":true,"aggregatable":true}},
          "status":{"integer":{"searchable":true,"aggregatable":true},"keyword":{"searchable":true,"aggregatable":true}},
          "user.name":{"keyword":{"searchable":true,"aggregatable":true}},
          "_seq_no":{"long":{"searchable":false,"aggregatable":false}},
          "_source":{"_source":{"searchable":false,"aggregatable":false}},
          "_type":{"_type":{"searchable":false,"aggregatable":false}},
          "_version":{"long":{"searchable":false,"aggregatable":false}}
        }}
        """.utf8)

        let catalog = try ElasticsearchMappingCatalog.parse(
            mappingData: mapping,
            fieldCapsData: caps
        )

        #expect(catalog.byPath["message"]?.keywordSubfieldPath == "message.keyword")
        #expect(catalog.byPath["message.keyword"]?.type == "keyword")
        #expect(catalog.byPath["status"]?.hasTypeConflict == true)
        #expect(catalog.byPath["user.name"]?.isAggregatable == true)
        #expect(catalog.fields.allSatisfy { !$0.path.hasPrefix("_") })
    }

    @Test("Allows explicit term-level queries on analyzed text")
    func analyzedTextTermQuery() throws {
        let catalog = ElasticsearchMappingCatalog(fields: [
            field("areaName", type: "text", aggregatable: false),
        ])
        let filter = WorkspaceDatabaseDataFilter(conditions: [
            .init(
                columnName: "areaName",
                columnKind: .elasticsearchText,
                operation: .term,
                value: "shanghai"
            ),
        ])

        let query = try ElasticsearchFilterTranslator.query(
            for: filter,
            mapping: catalog
        )
        let clauses = try #require(
            (query["bool"] as? [String: Any])?["filter"]
                as? [[String: Any]]
        )
        #expect(
            ((clauses[0]["term"] as? [String: Any])?["areaName"]
                as? String) == "shanghai"
        )
    }

    @Test("Builds four ordered bool buckets and requires one should clause")
    func mixedBoolClauses() throws {
        let catalog = ElasticsearchMappingCatalog(fields: [
            field("age", type: "integer"),
            field("title", type: "text", aggregatable: false),
            field("status", type: "keyword"),
            field("message.keyword", type: "keyword"),
        ])
        let filter = WorkspaceDatabaseDataFilter(conditions: [
            .init(
                columnName: "status",
                columnKind: .elasticsearchKeyword,
                operation: .term,
                value: "open"
            ),
            .init(
                columnName: "status",
                columnKind: .elasticsearchKeyword,
                operation: .wildcard,
                value: "open-*"
            ),
            .init(
                columnName: "title",
                columnKind: .elasticsearchText,
                elasticsearchClause: .must,
                operation: .match,
                value: "timeout"
            ),
            .init(
                columnName: "age",
                columnKind: .elasticsearchNumber,
                elasticsearchClause: .should,
                operation: .rangeGreaterThanOrEqual,
                value: "18"
            ),
            .init(
                columnName: "message.keyword",
                columnKind: .elasticsearchKeyword,
                elasticsearchClause: .mustNot,
                operation: .exists
            ),
        ])

        let query = try ElasticsearchFilterTranslator.query(
            for: filter,
            mapping: catalog
        )
        let bool = try #require(query["bool"] as? [String: Any])
        let filterClauses = try #require(bool["filter"] as? [[String: Any]])
        let mustClauses = try #require(bool["must"] as? [[String: Any]])
        let shouldClauses = try #require(bool["should"] as? [[String: Any]])
        let mustNotClauses = try #require(bool["must_not"] as? [[String: Any]])
        #expect(
            ((filterClauses[0]["term"] as? [String: Any])?["status"]
                as? String) == "open"
        )
        #expect(filterClauses[1]["wildcard"] != nil)
        #expect(mustClauses[0]["match"] != nil)
        #expect(shouldClauses[0]["range"] != nil)
        #expect(mustNotClauses[0]["exists"] != nil)
        #expect(bool["minimum_should_match"] as? Int == 1)
    }

    @Test("Parses JSON and comma-separated typed terms")
    func termsQueries() throws {
        let catalog = ElasticsearchMappingCatalog(fields: [
            field("status", type: "keyword"),
            field("age", type: "integer"),
        ])
        let filter = WorkspaceDatabaseDataFilter(conditions: [
            .init(
                columnName: "status",
                columnKind: .elasticsearchKeyword,
                operation: .terms,
                value: #"["open", "closed"]"#
            ),
            .init(
                columnName: "age",
                columnKind: .elasticsearchNumber,
                operation: .terms,
                value: "18, 30"
            ),
        ])

        let query = try ElasticsearchFilterTranslator.query(
            for: filter,
            mapping: catalog
        )
        let clauses = try #require(
            (query["bool"] as? [String: Any])?["filter"]
                as? [[String: Any]]
        )
        let statuses = try #require(
            (clauses[0]["terms"] as? [String: Any])?["status"] as? [Any]
        )
        let ages = try #require(
            (clauses[1]["terms"] as? [String: Any])?["age"] as? [Any]
        )
        #expect(statuses as? [String] == ["open", "closed"])
        #expect(ages.map(String.init(describing:)) == ["18", "30"])
    }

    @Test("Rejects invalid terms and mapping conflicts")
    func invalidStructuredFilters() throws {
        let catalog = ElasticsearchMappingCatalog(fields: [
            field("age", type: "integer"),
            WorkspaceDocumentMappingField(
                path: "status",
                type: "integer|keyword",
                isIndexed: true,
                isSearchable: true,
                isAggregatable: false,
                hasTypeConflict: true,
                keywordSubfieldPath: nil
            ),
        ])

        #expect(throws: WorkspaceSessionError.self) {
            try ElasticsearchFilterTranslator.query(
                for: WorkspaceDatabaseDataFilter(conditions: [
                    .init(
                        columnName: "age",
                        columnKind: .elasticsearchNumber,
                        operation: .terms,
                        value: "[{}]"
                    ),
                ]),
                mapping: catalog
            )
        }
        #expect(throws: ElasticsearchError.self) {
            try ElasticsearchFilterTranslator.query(
                for: WorkspaceDatabaseDataFilter(conditions: [
                    .init(
                        columnName: "status",
                        columnKind: .elasticsearchKeyword,
                        operation: .term,
                        value: "open"
                    ),
                ]),
                mapping: catalog
            )
        }
        let matchAll = try ElasticsearchFilterTranslator.query(
            for: .empty,
            mapping: catalog
        )
        #expect(matchAll["match_all"] != nil)
    }

    private func field(
        _ path: String,
        type: String,
        aggregatable: Bool = true,
        keywordSubfieldPath: String? = nil
    ) -> WorkspaceDocumentMappingField {
        WorkspaceDocumentMappingField(
            path: path,
            type: type,
            isIndexed: true,
            isSearchable: true,
            isAggregatable: aggregatable,
            hasTypeConflict: false,
            keywordSubfieldPath: keywordSubfieldPath
        )
    }
}
