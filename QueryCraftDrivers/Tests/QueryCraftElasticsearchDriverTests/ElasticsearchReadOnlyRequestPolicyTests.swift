#if os(iOS)
import QueryCraftMobileCore
@testable import QueryCraftMobileProof
#else
import QueryCraftFeature
#endif
import Testing
#if !os(iOS)
@testable import QueryCraftElasticsearchDriver
#endif

@Suite("Elasticsearch read-only request policy")
struct ElasticsearchReadOnlyRequestPolicyTests {
    @Test("Allows documented read-only requests")
    func allowsReadOnlyRequests() throws {
        try ElasticsearchReadOnlyRequestPolicy.validate(
            WorkspaceRequest(method: .get, path: "/_cluster/health")
        )
        try ElasticsearchReadOnlyRequestPolicy.validate(
            WorkspaceRequest(method: .post, path: "/logs-*/_search")
        )
        try ElasticsearchReadOnlyRequestPolicy.validate(
            WorkspaceRequest(method: .post, path: "/_index_template/_simulate_index/qc-preview-1")
        )
    }

    @Test("Rejects writes and absolute URLs")
    func rejectsUnsafeRequests() {
        #expect(throws: ElasticsearchError.self) {
            try ElasticsearchReadOnlyRequestPolicy.validate(
                WorkspaceRequest(method: .delete, path: "/logs")
            )
        }
        #expect(throws: ElasticsearchError.self) {
            try ElasticsearchReadOnlyRequestPolicy.validate(
                WorkspaceRequest(
                    method: .get,
                    path: "https://example.com/_search"
                )
            )
        }
    }
}
