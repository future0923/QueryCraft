import Foundation
import Testing
@_spi(MCP) import QueryCraftFeature
@testable import QueryCraftMariaDBTransportV4

struct MySQLMCPErrorTests {
    @Test func nativeDatabaseErrorSurvivesTransportAndMCPBoundary() throws {
        let error = CDatabaseClientError(code: 1049, message: "Unknown database fixture-secret", sqlState: "42000")
        let result = try MCPHost.failure(error)
        #expect(result.code == "DATABASE_NOT_FOUND")
        let json = String(decoding: result.json, as: UTF8.self)
        #expect(json.contains("1049"))
        #expect(json.contains("42000"))
        #expect(json.contains("fixture-secret") == false)
    }
}
