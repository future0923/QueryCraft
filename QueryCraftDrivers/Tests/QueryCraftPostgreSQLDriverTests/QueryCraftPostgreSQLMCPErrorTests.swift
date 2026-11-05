import Foundation
import Testing
@_spi(MCP) import QueryCraftFeature
@testable import QueryCraftPostgreSQLDriver

struct PostgreSQLMCPErrorTests {
    @Test func serverSQLSTATEIsRetainedButConnectionTextIsNotGuessed() throws {
        #expect(try MCPHost.failure(PostgreSQLClientError(message: "fixture-secret", sqlState: "3D000")).code == "DATABASE_NOT_FOUND")
        let result = try MCPHost.failure(PostgreSQLClientError(message: "database does not exist fixture-secret", sqlState: nil))
        #expect(result.code == "DATABASE_ERROR")
        #expect(String(decoding: result.json, as: UTF8.self).contains("fixture-secret") == false)
    }
}
