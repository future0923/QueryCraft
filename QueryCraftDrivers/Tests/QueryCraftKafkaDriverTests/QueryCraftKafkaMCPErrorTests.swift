import Foundation
import Testing
@_spi(MCP) import QueryCraftFeature
@testable import QueryCraftKafkaDriver

struct KafkaMCPErrorTests {
    @Test func protocolCodesSurviveButLegacyTextIsNotGuessed() throws {
        let result = try MCPHost.failure(KafkaError.protocolError(code: 58, message: "fixture-secret"))
        #expect(result.code == "AUTHENTICATION_FAILED")
        #expect(String(decoding: result.json, as: UTF8.self).contains("fixture-secret") == false)
        #expect(try MCPHost.failure(KafkaError.protocolError(code: 29, message: nil)).code == "DATABASE_ACCESS_DENIED")
        #expect(try MCPHost.failure(KafkaError.network("Unknown topic fixture-secret")).code == "DATABASE_ERROR")
    }
}
