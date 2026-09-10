import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceJSONPresentationTests {
    @Test func formattingPreservesLexemesAndTypes() async throws {
        let source = #"{"id":18446744073709551615,"name":"\u0041\/","items":[true,false,null,"null",1.00e+20]}"#
        let worker = WorkspaceJSONPresentationWorker()
        let formatted = try #require(try await worker.format(source, automatic: true))
        #expect(formatted.contains("\n"))
        #expect(try ElasticsearchJSONWhitespaceFormatter.format(Data(formatted.utf8), compact: true) == source)
    }

    @Test func plainAndInvalidTextRemainsUnchanged() async throws {
        let worker = WorkspaceJSONPresentationWorker()
        for source in ["hello", "null", "42", #"{"unfinished":"#] {
            #expect(try await worker.format(source, automatic: true) == nil)
            #expect(try await worker.format(source, automatic: false) == source)
        }
    }

    @Test func fullLargeResponseHasNoPreviewLimit() async throws {
        let tail = "end-of-document"
        let source = "{\"value\":\"" + String(repeating: "a", count: 1_100_000) + tail + "\"}"
        let formatted = try #require(try await WorkspaceJSONPresentationWorker().format(source, automatic: true))
        #expect(formatted.contains(tail))
        #expect(try ElasticsearchJSONWhitespaceFormatter.format(Data(formatted.utf8), compact: true) == source)
    }

    @Test func cancellationNeverPublishesFormattedText() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorkspaceJSONPresentationWorker().format("{}", automatic: true)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled formatting returned a result")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func previewKeepsRequestBoundariesAndNDJSON() async throws {
        let body = Data("{\"index\":{}}\n{\"id\":18446744073709551615}\n".utf8)
        let requests: [WorkspaceRequest] = [
            .init(method: .post, path: "/_bulk", body: body),
            .init(method: .put, path: "/example/_mapping", body: Data(#"{"properties":{"name":{"type":"keyword"}}}"#.utf8))
        ]
        let preview = try await WorkspaceElasticsearchConsoleWorker().previewSource(requests)
        #expect(preview.hasPrefix("POST /_bulk\n" + String(decoding: body, as: UTF8.self)))
        #expect(preview.contains("PUT /example/_mapping\n{\n"))
        #expect(requests[0].body == body)
    }
}
