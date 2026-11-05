import Foundation
import Testing
@_spi(MCP) import QueryCraftFeature
@testable import QueryCraftRedisDriver

struct RedisMCPErrorTests {
    @Test func RESPTokenAndTransportCodeSurviveMCPBoundary() throws {
        let result = try MCPHost.failure(RedisClientError(message: "WRONGPASS fixture-secret"))
        #expect(result.code == "AUTHENTICATION_FAILED")
        let json = String(decoding: result.json, as: UTF8.self)
        #expect(json.contains("WRONGPASS"))
        #expect(json.contains("fixture-secret") == false)
        #expect(try MCPHost.failure(RedisClientError(message: "fixture-secret", transportCode: 3)).code == "CONNECTION_FAILED")
        #expect(try MCPHost.failure(RedisClientError(message: "arbitrary fixture-secret")).code == "DATABASE_ERROR")
    }
}
