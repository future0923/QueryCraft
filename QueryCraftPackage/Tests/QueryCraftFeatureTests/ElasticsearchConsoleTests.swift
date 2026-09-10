import Foundation
import Testing
@testable import QueryCraftFeature

struct ElasticsearchConsoleTests {
    @Test
    func getBodyCompatibilityAndFullContentCopyAreLocalized() {
        let chinese = AppCopy(language: .simplifiedChinese)
        let english = AppCopy(language: .english)
        let error = WorkspaceReadOnlyRequestValidationError.unsupported(method: .get, path: "/_cluster/health")
        #expect(error.description(copy: chinese).contains("此端点不支持 GET 请求体兼容"))
        #expect(error.description(copy: english).contains("GET request bodies cannot be adapted"))
        #expect(chinese.viewFullCellContent == "查看完整内容…")
        #expect(english.viewFullCellContent == "View Full Content...")
    }

    @Test(arguments: ["/_search", "/_all/_search", "/logs-*/_count?routing=a%2Fb", "/logs/_msearch", "/_field_caps", "/logs/_analyze", "/logs/_validate/query", "/logs/_search/template", "/_render/template", "/_sql", "/logs/_eql/search", "/logs/_explain/a%2Fb"])
    func getBodyAllowsOnlyEquivalentReadOnlyRoutes(path: String) throws {
        let request = WorkspaceRequest(method: .get, path: path, body: Data("{}".utf8))
        try WorkspaceReadOnlyRequestValidator.validate(request)
        let result = WorkspaceElasticsearchConsoleResult(request: request, statusCode: 200,
            output: nil, errorMessage: nil, elapsedSeconds: 0)
        #expect(result.requestSummary == "GET → POST \(path)")
        #expect(result.request.method == .get)
    }

    @Test(arguments: ["/logs/_delete_by_query", "/_bulk", "/a/b/_search", "/_cluster/health", "/logs/_search/", "/logs//_search", "/logs/_search#fragment"])
    func getBodyUnknownRoutesAreRejected(path: String) {
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) {
            try WorkspaceReadOnlyRequestValidator.validate(WorkspaceRequest(method: .get, path: path, body: Data("{}".utf8)))
        }
    }

    @Test
    func responseLargerThan16MiBPreservesEveryCellWithPreviewOnlyTruncation() async throws {
        let text = String(repeating: "x", count: 400_000) + "END-OF-VALUE"
        let hits = (0..<48).map { ["_id": String($0), "_index": "large", "_source": ["payload": text]] as [String: Any] }
        let body = try JSONSerialization.data(withJSONObject: ["hits": ["hits": hits]])
        #expect(body.count > 16 * 1024 * 1024)
        let output = try await WorkspaceElasticsearchResponseConversionWorker().output(
            from: WorkspaceRequestExecutionResult(statusCode: 200, contentType: "application/json", body: body), maximumRows: 1000)
        guard case .grid(let page) = output else { Issue.record("Expected grid"); return }
        #expect(page.rowCount == 48)
        let column = try #require(page.columns.first { $0.name == "payload" })
        for row in 0..<48 {
            let value = try #require(page.row(at: row)?.value(at: column.id))
            #expect(value == .text(text))
            #expect(value.gridPreviewText(nullDisplayText: "NULL", maximumCharacterCount: 300).count == 303)
        }
    }

    @Test
    func parsesMultipleRequestsAndBodyRanges() throws {
        let source = """
            GET /logs-*/_search
            {"query":{"match_all":{}}}

            POST /logs-*/_count
            {"query":{"term":{"level":"error"}}}
            """
        let requests = try ElasticsearchConsoleParser().parse(source)

        #expect(requests.count == 2)
        #expect(requests[0].request.method == .get)
        #expect(requests[1].request.path == "/logs-*/_count")
        let firstBody = (source as NSString).substring(
            with: requests[0].bodyRange
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(firstBody == #"{"query":{"match_all":{}}}"#)
    }

    @Test
    func selectionRunsEverySelectedRequestAndCursorRunsOne() throws {
        let source = """
            GET /_cluster/health

            GET /_cat/indices?format=json

            POST /_count
            {"query":{"match_all":{}}}
            """
        let parser = ElasticsearchConsoleParser()
        let all = try parser.requests(
            in: source,
            intersecting: NSRange(
                location: 0,
                length: (source as NSString).length
            )
        )
        #expect(all.count == 3)

        let cursor = (source as NSString).range(of: "/_cat/indices").location
        let current = try parser.requests(
            in: source,
            intersecting: NSRange(location: cursor, length: 0)
        )
        #expect(current.count == 1)
        #expect(current[0].request.path == "/_cat/indices?format=json")
    }

    @Test
    func formatsJSONAndPreservesMSearchTerminalNewline() throws {
        let source = """
            POST /_msearch
            {"index":"logs"}
            {"query":{"match_all":{}}}
            """
        let formatted = try ElasticsearchConsoleParser().formatted(source)
        #expect(formatted.hasSuffix("\n"))
        #expect(formatted.contains(#"{"index":"logs"}"#))
    }

    @Test
    func msearchExecutionBodyAlwaysHasATerminalNewline() throws {
        let source = """
            POST /second_hand/_msearch
            {}
            {"query":{}}
            """
        let parsed = try #require(
            ElasticsearchConsoleParser().parse(source).first
        )
        let body = try #require(parsed.request.body)

        #expect(String(decoding: body, as: UTF8.self).hasSuffix("\n"))
        #expect(String(decoding: body, as: UTF8.self) == """
            {}
            {"query":{}}

            """)
    }

    @Test
    func readOnlyPolicyFailsClosed() throws {
        try WorkspaceReadOnlyRequestValidator.validate(
            WorkspaceRequest(method: .post, path: "/logs/_search")
        )
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) {
            try WorkspaceReadOnlyRequestValidator.validate(
                WorkspaceRequest(method: .post, path: "/logs/_delete_by_query")
            )
        }
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) {
            try WorkspaceReadOnlyRequestValidator.validate(
                WorkspaceRequest(method: .delete, path: "/logs/_doc/1")
            )
        }
        #expect(throws: WorkspaceReadOnlyRequestValidationError.self) {
            try WorkspaceReadOnlyRequestValidator.validate(
                WorkspaceRequest(method: .get, path: "https://example.com/")
            )
        }
    }

    @Test
    func convertsHitsAndObjectArraysToUnionColumnGrids() throws {
        let hits = WorkspaceRequestExecutionResult(
            statusCode: 200,
            contentType: "application/json",
            body: Data(#"{"hits":{"hits":[{"_id":"1","_index":"logs","_score":1.5,"_source":{"message":"ok","user":{"name":"Ada"}}}]}}"#.utf8)
        )
        let hitsOutput = try ElasticsearchConsoleResponseConverter.output(
            from: hits,
            maximumRows: 100
        )
        guard case let .grid(hitsPage) = hitsOutput else {
            Issue.record("Expected search hits to use the data grid")
            return
        }
        #expect(hitsPage.columns.map(\.name) == [
            "_id", "_index", "_score", "message", "user.name",
        ])
        #expect(hitsPage.rowCount == 1)

        let array = WorkspaceRequestExecutionResult(
            statusCode: 200,
            contentType: "application/json",
            body: Data(#"[{"name":"first"},{"count":2}]"#.utf8)
        )
        let arrayOutput = try ElasticsearchConsoleResponseConverter.output(
            from: array,
            maximumRows: 100
        )
        guard case let .grid(arrayPage) = arrayOutput else {
            Issue.record("Expected an object array to use the data grid")
            return
        }
        #expect(arrayPage.columns.map(\.name) == ["count", "name"])
        #expect(arrayPage.rowCount == 2)
    }

    @Test(arguments: [true, false])
    func preservesNumericAndBooleanCellsInHitsAndObjectArrays(searchHits: Bool) throws {
        let source = #"{"name":1,"count":0,"enabled":true,"disabled":false,"numericText":"1","zeroText":"0","booleanText":"true","negative":-1,"decimal":0.5,"large":622887501937246211,"missing":null,"array":[0,1,true,false],"nested":{"count":1}}"#
        let json = searchHits
            ? #"{"hits":{"hits":[{"_id":"1","_index":"logs","_score":1,"_source":\#(source)}]}}"#
            : "[\(source)]"
        let response = WorkspaceRequestExecutionResult(statusCode: 200, contentType: "application/json", body: Data(json.utf8))
        guard case let .grid(page) = try ElasticsearchConsoleResponseConverter.output(from: response, maximumRows: 100) else {
            Issue.record("Expected a grid")
            return
        }
        let row = try #require(page.row(at: 0))
        let cells = Dictionary(uniqueKeysWithValues: zip(page.columns.map(\.name), row.values))
        #expect(cells["name"] == .text("1"))
        #expect(cells["count"] == .text("0"))
        #expect(cells["enabled"] == .text("true"))
        #expect(cells["disabled"] == .text("false"))
        #expect(cells["numericText"] == .text("1"))
        #expect(cells["zeroText"] == .text("0"))
        #expect(cells["booleanText"] == .text("true"))
        #expect(cells["negative"] == .text("-1"))
        #expect(cells["decimal"] == .text("0.5"))
        #expect(cells["large"] == .text("622887501937246211"))
        #expect(cells["missing"] == .null)
        #expect(cells["array"] == .text("[0,1,true,false]"))
        if searchHits {
            #expect(cells["_score"] == .text("1"))
            #expect(cells["nested.count"] == .text("1"))
        } else {
            #expect(cells["nested"] == .text(#"{"count":1}"#))
        }
        #expect(response.body == Data(json.utf8))
    }

    @Test
    func convertsOrdinaryObjectsToCompleteFormattedJSON() throws {
        let response = WorkspaceRequestExecutionResult(
            statusCode: 200,
            contentType: "application/json",
            body: Data(#"{"status":"green","number_of_nodes":3}"#.utf8)
        )
        let output = try ElasticsearchConsoleResponseConverter.output(
            from: response,
            maximumRows: 100
        )

        guard case let .json(json) = output else {
            Issue.record("Expected an ordinary object to use raw JSON output")
            return
        }
        #expect(json.contains(#""number_of_nodes" : 3"#))
        #expect(json.contains(#""status" : "green""#))
        #expect(json.hasPrefix("{"))
        #expect(json.hasSuffix("}"))
    }

    @MainActor
    @Test
    func completesMethodsResourcesAndReadOnlyEndpointsEarly() {
        let resources = [
            WorkspaceElasticsearchCompletionResource(
                name: "second_hand",
                kind: .elasticsearchIndex
            ),
            WorkspaceElasticsearchCompletionResource(
                name: "ee_default_alias",
                kind: .elasticsearchAlias
            ),
        ]
        #expect(
            WorkspaceElasticsearchCompletionService.pathSuggestionTexts(
                forPathPrefix: "/sec",
                method: .post,
                resources: resources
            ) == ["/second_hand/"]
        )
        #expect(
            WorkspaceElasticsearchCompletionService.pathSuggestionTexts(
                forPathPrefix: "/second_hand/",
                method: .post,
                resources: resources
            ).contains("/second_hand/_search")
        )
        #expect(
            WorkspaceElasticsearchCompletionService.pathSuggestionTexts(
                forPathPrefix: "/second_hand/_s",
                method: .post,
                resources: resources
            ).contains("/second_hand/_search")
        )
        #expect(
            WorkspaceElasticsearchCompletionService.pathSuggestionTexts(
                forPathPrefix: "/second_hand/_c",
                method: .post,
                resources: resources
            ).contains("/second_hand/_count")
        )
        #expect(
            WorkspaceElasticsearchCompletionService.pathSuggestionTexts(
                forPathPrefix: "/_cl",
                method: .get,
                resources: resources
            ) == ["/_cluster/health"]
        )
        #expect(
            WorkspaceElasticsearchCompletionService.pathSuggestionTexts(
                forPathPrefix: "/second_hand/_d",
                method: .post,
                resources: resources
            ).contains("/second_hand/_delete_by_query")
        )
        #expect(
            !WorkspaceElasticsearchCompletionService.pathSuggestionTexts(
                forPathPrefix: "/",
                method: .post,
                resources: resources
            ).contains("/_cluster/health")
        )

        #expect(
            WorkspaceElasticsearchCompletionService.pathSuggestionTexts(
                forPathPrefix: "/_m",
                method: .post,
                resources: resources
            ).contains("""
                /_msearch
                {"index": ""}
                {"query": {"match_all": {}}}

                """)
        )
    }

    @MainActor
    @Test
    func highlightsElasticsearchRequestLines() {
        let source = "POST /second_hand/_search?pretty=true\n{}"
        let highlights = WorkspaceElasticsearchJSONBodyHighlighter
            .requestLineHighlights(
                in: source,
                intersecting: NSRange(
                    location: 0,
                    length: (source as NSString).length
                )
            )

        #expect(highlights.contains { highlight in
            highlight.capture == .keyword
                && (source as NSString).substring(with: highlight.range)
                    == "POST"
        })
        #expect(highlights.contains { highlight in
            highlight.capture == .type
                && (source as NSString).substring(with: highlight.range)
                    == "/second_hand/_search"
        })
        #expect(highlights.contains { highlight in
            highlight.capture == .number
                && (source as NSString).substring(with: highlight.range)
                    == "?pretty=true"
        })
    }

    @Test
    func requestRestorationIsBackwardCompatible() throws {
        let context = WorkspaceDatabaseContextRestorationState(
            id: UUID(),
            databaseName: "Elasticsearch",
            selectedObject: nil,
            queryDocuments: [],
            selectedQueryDocumentID: nil,
            contentTabOrder: [],
            selectedContentTab: nil,
            sidebarMode: .items
        )
        let oldData = try JSONEncoder().encode(context)
        var object = try #require(
            JSONSerialization.jsonObject(with: oldData) as? [String: Any]
        )
        object.removeValue(forKey: "elasticsearchRequestDocuments")
        let decoded = try JSONDecoder().decode(
            WorkspaceDatabaseContextRestorationState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.elasticsearchRequestDocuments == nil)
    }

    @MainActor
    @Test
    func savesUpdatesAndReopensElasticsearchRequests() async throws {
        let profile = makeElasticsearchProfile()
        let repository = InMemorySavedQueryRepository()
        let model = makeElasticsearchModel(
            profile: profile,
            savedQueryRepository: repository
        )

        await model.connect()
        let document = try #require(model.createElasticsearchRequestDocument())
        document.source = "GET /logs-*/_search\n{\"query\":{\"match_all\":{}}}"

        let createdAt = Date(timeIntervalSince1970: 1_000)
        let created = try await model.saveElasticsearchRequestDocument(
            document,
            name: "  Recent Logs  ",
            now: createdAt
        )

        #expect(created.name == "Recent Logs")
        #expect(created.defaultDatabase == nil)
        #expect(document.savedQueryID == created.id)
        #expect(document.title == created.name)
        #expect(!document.isDirty)
        #expect(try await repository.fetch(id: created.id) == created)

        document.source = "GET /logs-*/_count"
        let updatedAt = Date(timeIntervalSince1970: 2_000)
        let updated = try await model.saveElasticsearchRequestDocument(
            document,
            name: nil,
            now: updatedAt
        )

        #expect(updated.id == created.id)
        #expect(updated.createdAt == createdAt)
        #expect(updated.updatedAt == updatedAt)
        #expect(updated.sql == document.source)
        #expect(!document.isDirty)
        #expect(try await repository.fetch(id: created.id) == updated)

        let reopened = try #require(
            model.openElasticsearchSavedRequest(created.id)
        )
        #expect(reopened.savedQueryID == created.id)
        #expect(reopened.title == updated.name)
        #expect(reopened.source == updated.sql)
        #expect(!reopened.isDirty)

        await model.disconnect()
    }

    @MainActor
    @Test
    func restorationPreservesSavedBaselineAndUnsavedRequestChanges()
        async throws
    {
        let profile = makeElasticsearchProfile()
        let repository = InMemorySavedQueryRepository()
        let model = makeElasticsearchModel(
            profile: profile,
            savedQueryRepository: repository
        )

        await model.connect()
        let document = try #require(model.createElasticsearchRequestDocument())
        document.source = "GET /logs-*/_search"
        let saved = try await model.saveElasticsearchRequestDocument(
            document,
            name: "Logs"
        )
        document.source = "GET /logs-2026/_search"

        let encoded = try JSONEncoder().encode(document.restorationState)
        let decoded = try JSONDecoder().decode(
            WorkspaceElasticsearchRequestRestorationState.self,
            from: encoded
        )
        let restored = try #require(
            model.restoreElasticsearchRequestDocuments([decoded]).first
        )

        #expect(restored.id == document.id)
        #expect(restored.savedQueryID == saved.id)
        #expect(restored.source == "GET /logs-2026/_search")
        #expect(restored.isDirty)

        await model.disconnect()
    }

    @MainActor
    private func makeElasticsearchModel(
        profile: ConnectionProfile,
        savedQueryRepository: any SavedQueryRepository
    ) -> WorkspaceModel {
        WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            savedQueryRepository: savedQueryRepository,
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
    }

    private func makeElasticsearchProfile() -> ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: "Local Elasticsearch",
            groupID: nil,
            databaseType: .elasticsearch,
            databaseProduct: .elasticsearch,
            host: "127.0.0.1",
            port: 9_200,
            username: "elastic",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }
}
