import Foundation
import Testing
@testable import QueryCraftFeature

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceElasticsearchConsoleResponseTests {
    @Test func keepsCompleteResponseBesideLimitedGridAndAdditionalHitSections() async throws {
        let body = #"{"took":17,"timed_out":false,"_shards":{"total":3,"successful":3,"skipped":1,"failed":0},"hits":{"total":{"value":10000,"relation":"gte"},"hits":[{"_id":"1","_index":"test","fields":{"name":["沈阳"]},"highlight":{"name":["<em>沈阳</em>"]},"sort":[9],"inner_hits":{"nested":{"hits":{"hits":[]}}}},{"_id":"2","_source":{"precise":18446744073709551615}}]},"aggregations":{"cities":{"buckets":[{"key":"沈阳","doc_count":2}]}},"escape":"\u0041\/"}"#
        let analyzed = try await analyze(body, limit: 1)
        guard case .grid(let page) = analyzed.output else { Issue.record("Expected grid"); return }
        #expect(page.rowCount == 1)
        #expect(page.columns.map(\.name).contains("fields.name"))
        #expect(page.columns.map(\.name).contains("highlight.name"))
        #expect(page.columns.map(\.name).contains("inner_hits"))
        #expect(page.columns.map(\.name).contains("sort"))
        #expect(analyzed.details.fullResponse == body)
        #expect(analyzed.details.totalHits == "10000" && analyzed.details.totalIsLowerBound)
        #expect(analyzed.details.returnedHits == 2 && analyzed.details.displayedRows == 1)
        #expect(analyzed.details.tookMilliseconds == "17")
        #expect(analyzed.details.hasAggregations && !analyzed.details.prefersJSON)
        #expect(analyzed.details.failureMessage == nil)
        #expect(analyzed.details.summary(copy: .init(language: .simplifiedChinese)).contains("返回 2"))
        #expect(analyzed.details.summary(copy: .init(language: .english)).contains("Returned 2"))
    }

    @Test func aggregationOnlyDefaultsToJSONAndLegacyTotalStaysExact() async throws {
        let result = try await analyze(#"{"hits":{"total":622887501937246211,"hits":[]},"aggregations":{"count":{"value":42}}}"#)
        #expect(result.details.prefersJSON)
        #expect(result.details.totalHits == "622887501937246211")
        #expect(!result.details.totalIsLowerBound)
    }

    @Test func HTTP200PartialResultsHaveExplicitWarningsAndShardInformation() async throws {
        let partial = try await analyze(#"{"took":7,"_shards":{"total":3,"successful":2,"failed":1,"failures":[{"reason":{"type":"query_shard_exception","reason":"unsupported field"}}]},"hits":{"hits":[]}}"#)
        #expect(partial.details.failedShards == 1 && partial.details.successfulShards == 2)
        #expect(partial.details.failureMessage != nil)
        #expect(partial.details.diagnostics.first?.message.contains("unsupported field") == true)
        let timedOut = try await analyze(#"{"timed_out":true,"hits":{"hits":[]}}"#)
        #expect(timedOut.details.timedOut == true && timedOut.details.failureMessage != nil)
    }

    @Test func errorLocationUsesRequestBodyOffsetAndUTF8Columns() async throws {
        let bodyLine = #"  "城市": "沈阳", "bad": 1"#
        let source = "GET /_cluster/health\n\nPOST /test/_search\n{\n\(bodyLine)\n}"
        let parsed = try #require(ElasticsearchConsoleParser().parse(source).last)
        let bad = try #require(bodyLine.range(of: "\"bad\""))
        let column = bodyLine[..<bad.lowerBound].utf8.count + 1
        let response = response("{\"error\":{\"type\":\"search_phase_execution_exception\",\"reason\":\"failed\",\"root_cause\":[{\"type\":\"parsing_exception\",\"reason\":\"unknown field\",\"line\":2,\"col\":\(column)}]},\"status\":400}", status: 400)
        let analyzed = try await WorkspaceElasticsearchResponseConversionWorker().analyze(from: response,
            maximumRows: 10, parsed: parsed, source: source)
        let diagnostic = try #require(analyzed.details.diagnostics.first { $0.documentRange != nil })
        #expect(diagnostic.documentRange?.location == (source as NSString).range(of: "\"bad\"").location)
        #expect(diagnostic.line == 2 && diagnostic.column == column)
        #expect(analyzed.details.failureMessage?.contains("400") == true)
        #expect(analyzed.details.fullResponse == String(decoding: response.body, as: UTF8.self))
    }

    @Test func ndjsonErrorsRetainReasonsWithoutGuessingSubrequestLocations() async throws {
        let source = "POST /_msearch\n{}\n{\"query\":{}}\n"
        let parsed = try #require(ElasticsearchConsoleParser().parse(source).first)
        let result = try await WorkspaceElasticsearchResponseConversionWorker().analyze(from:
            response(#"{"responses":[{"status":400,"error":{"type":"parsing_exception","reason":"[1:2] invalid clause","line":1,"col":2}}]}"#),
            maximumRows: 10, parsed: parsed, source: source)
        #expect(result.details.failureMessage != nil)
        #expect(result.details.diagnostics.first?.message.contains("invalid clause") == true)
        #expect(result.details.diagnostics.allSatisfy { $0.documentRange == nil })
    }

    @Test func malformedAndEmptyResponsesRemainAvailableInFull() async throws {
        for body in ["", "<html>proxy error</html>"] {
            let result = try await analyze(body, status: 502)
            #expect(result.details.fullResponse == body)
            #expect(result.details.failureMessage == "HTTP 502")
            #expect(result.details.timedOut == nil)
        }
    }

    @Test func queryLanguageAndScriptCoordinatesNeverPretendToBeJSONBodyCoordinates() async throws {
        for (path, type) in [("/_sql", "parsing_exception"), ("/test/_eql/search", "parsing_exception"),
                             ("/test/_search", "script_exception")] {
            let source = "POST \(path)\n{}"
            let parsed = try #require(ElasticsearchConsoleParser().parse(source).first)
            let result = try await WorkspaceElasticsearchResponseConversionWorker().analyze(from:
                response("{\"error\":{\"type\":\"\(type)\",\"reason\":\"bad expression\",\"line\":1,\"col\":1}}", status: 400),
                maximumRows: 10, parsed: parsed, source: source)
            #expect(result.details.diagnostics.allSatisfy { $0.documentRange == nil })
        }
    }

    @Test @MainActor func editingSourceDisablesNavigationToPreviousExecution() async throws {
        let document = WorkspaceElasticsearchRequestDocumentModel(title: "test", source: "POST /test/_search\n{}") { _ in
            .init(statusCode: 400, contentType: "application/json",
                body: Data(#"{"error":{"type":"parsing_exception","reason":"bad request","line":1,"col":1}}"#.utf8))
        }
        document.runAll()
        while document.isExecuting { await Task.yield() }
        let result = try #require(document.results.first)
        #expect(document.canLocateError(in: result))
        document.locateError(in: result)
        #expect(document.navigationRequest?.range.location == (document.source as NSString).range(of: "{}").location)
        let navigation = document.navigationRequest
        document.source = "GET /_cluster/health"
        #expect(!document.canLocateError(in: result))
        document.locateError(in: result)
        #expect(document.navigationRequest == navigation)
    }

    @Test func largeResponseRetainsAllHitsBeyondDisplayLimit() async throws {
        let hits = (0..<12_000).map { "{\"_id\":\"\($0)\",\"_source\":{\"name\":\"文档\($0)\"}}" }.joined(separator: ",")
        let body = "{\"hits\":{\"total\":12000,\"hits\":[\(hits)]},\"aggregations\":{\"count\":{\"value\":12000}}}"
        let result = try await analyze(body, limit: 100)
        #expect(result.details.returnedHits == 12_000 && result.details.displayedRows == 100)
        #expect(result.details.fullResponse == body && result.details.fullResponse.contains("文档11999"))
    }

    private func analyze(_ body: String, status: Int = 200, limit: Int = 100) async throws
        -> (output: WorkspaceElasticsearchConsoleOutput, details: WorkspaceElasticsearchResponseDetails) {
        let source = "GET /test/_search\n{}"
        let parsed = try #require(ElasticsearchConsoleParser().parse(source).first)
        return try await WorkspaceElasticsearchResponseConversionWorker().analyze(
            from: response(body, status: status), maximumRows: limit, parsed: parsed, source: source)
    }

    private func response(_ body: String, status: Int = 200) -> WorkspaceRequestExecutionResult {
        .init(statusCode: status, contentType: "application/json", body: Data(body.utf8))
    }
}
