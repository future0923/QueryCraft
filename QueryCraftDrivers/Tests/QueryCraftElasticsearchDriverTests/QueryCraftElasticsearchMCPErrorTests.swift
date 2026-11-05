import Foundation
import Testing
@_spi(MCP) import QueryCraftFeature
@testable import QueryCraftElasticsearchDriver

struct ElasticsearchMCPErrorTests {
    @Test func HTTPAndTransportCasesAreMappedWithoutServerBodies() throws {
        #expect(try MCPHost.failure(ElasticsearchError.unauthorized).code == "AUTHENTICATION_FAILED")
        #expect(try MCPHost.failure(ElasticsearchError.forbidden).code == "DATABASE_ACCESS_DENIED")
        #expect(try MCPHost.failure(ElasticsearchError.certificateValidationFailed).code == "TLS_FAILED")
        let result = try MCPHost.failure(ElasticsearchError.server(status: 404, message: "fixture-secret"))
        #expect(result.code == "DATABASE_ERROR")
        #expect(String(decoding: result.json, as: UTF8.self).contains("fixture-secret") == false)
    }
}
