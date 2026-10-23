import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileSQLExecutionIntegrationTests {
    private func model() throws -> MobileQueryModel {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        let model = MobileQueryModel()
        model.host = "127.0.0.1"; model.port = String(port); model.username = "proof_reader"
        model.password = "querycraft-proof-reader"; model.database = "querycraft_ios_proof"; model.tlsMode = .required
        return model
    }

    @Test func actualCurrentStatementPreservesOriginsMetadataAndEditableBaseTable() async throws {
        let model = try model()
        model.sql = "SELECT 'unrelated';\nSELECT id,name FROM sample ORDER BY id;\nDELETE FROM sample;"
        model.executionInput.selection = .init(location: (model.sql as NSString).range(of: "FROM sample").location, length: 0)
        await model.execute()?.value
        #expect(model.errorMessage == nil)
        #expect(model.lastExecutedSQL == "SELECT id,name FROM sample ORDER BY id;")
        #expect(model.result?.rows.count == 2); #expect(model.result?.rows.first?[1] == "你好 iPad 👋")
        let origin = try #require(model.result?.columnOrigins.first ?? nil)
        #expect(origin.columnName == "id")
        #expect(model.editing?.object.name == "sample"); #expect(model.editingPage?.columns.first?.comment == "primary identifier")
        #expect(model.sql.contains("DELETE FROM sample;"))
        model.sql = "SELECT 'new draft';"; model.executionInput.selection = .init(location: 0, length: 0)
        await model.refresh()?.value
        #expect(model.result?.rows.count == 2); #expect(model.sql == "SELECT 'new draft';")
    }

    @Test func selectedPrefixRunsExactSQLWithoutUnselectedPredicateOrNeighbour() async throws {
        let model = try model()
        model.sql = "SELECT id,name FROM sample WHERE id=99;\nSELECT 'next';"
        let selected = "SELECT id,name FROM sample"
        model.executionInput.selection = (model.sql as NSString).range(of: selected)
        await model.execute()?.value
        #expect(model.errorMessage == nil); #expect(model.lastExecutedSQL == selected)
        #expect(model.result?.rows.count == 2)
        #expect(model.editing != nil, "Editing metadata must come from the executed prefix, not the full multi-statement draft")
    }

    @Test func quotedSemicolonsUnicodeEmptyResultAndCommentsKeepServerMeaning() async throws {
        let model = try model()
        model.sql = "-- inspect 👋\nSELECT '雪;--quote' AS label, NULL AS absent;\nSELECT id FROM sample WHERE id<0;"
        model.executionInput.selection = .init(location: (model.sql as NSString).range(of: "雪;").location, length: 0)
        await model.execute()?.value
        #expect(model.errorMessage == nil); #expect(model.result?.rows == [["雪;--quote", nil]])
        model.executionInput.selection = .init(location: (model.sql as NSString).range(of: "id<0").location, length: 0)
        await model.execute()?.value
        #expect(model.errorMessage == nil); #expect(model.result?.columns == ["id"]); #expect(model.result?.rows.isEmpty == true)
    }

    @Test func unsafeSelectionLeavesPreviousServerResultAndDoesNotRunAnyBatchSubset() async throws {
        let model = try model()
        model.sql = "SELECT COUNT(*) AS n FROM sample;"
        await model.execute()?.value
        let previous = model.result, identity = model.resultID
        model.sql = "SELECT id FROM sample; DELETE FROM sample;"
        model.executionInput.selection = .init(location: 0, length: model.sql.utf16.count)
        await model.execute()?.value
        #expect(model.sqlConfirmation != nil)
        model.sqlConfirmation = nil
        #expect(model.result == previous); #expect(model.resultID == identity)
        model.sql = "SELECT COUNT(*) AS n FROM sample;"; model.executionInput.selection = .init(location: 0, length: 0)
        await model.execute()?.value
        #expect(model.result?.rows == [["2"]])
    }
}
