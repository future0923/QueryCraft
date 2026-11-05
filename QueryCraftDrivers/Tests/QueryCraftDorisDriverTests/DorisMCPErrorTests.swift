import Foundation
import Testing
@_spi(MCP) import QueryCraftFeature
@testable import QueryCraftMariaDBTransportV4

struct DorisMCPErrorTests {
    @Test func mysqlWireErrorsKeepSafeNativeDiagnostics() throws {
        let result = try MCPHost.failure(CDatabaseClientError(code: 1049, message: "fixture-secret", sqlState: "42000"))
        #expect(result.code == "DATABASE_NOT_FOUND")
        #expect(String(decoding: result.json, as: UTF8.self).contains("fixture-secret") == false)
    }
}
