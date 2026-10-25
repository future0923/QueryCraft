import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor struct MobileDorisParityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_DORIS_PORT"] != nil))
    func streamingCachePagingExportAndTrueStructureUseRealDoris() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_DORIS_PORT"].flatMap(Int.init))
        var profile = MobileDriverSupportTests.profile(.doris)
        profile.port = port; profile.database = "querycraft_ios_drivers"; profile.username = "root"
        let workspace = MobileDatabaseWorkspace(profile: profile, password: nil, service: MobileDorisService())
        let query = workspace.query
        let digits = "(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)"
        query.sql = "SELECT a.n+10*b.n+100*c.n+1000*d.n AS n,'雪😀' AS label,NULL AS absent FROM \(digits) a CROSS JOIN \(digits) b CROSS JOIN \(digits) c CROSS JOIN \(digits) d ORDER BY n"
        await query.executeAll()?.value
        #expect(query.errorMessage == nil); #expect(query.cachedRowCount == 10_000)
        #expect(query.result?.rows.count == 500); #expect(!query.supportsTransactions)
        #expect(query.editing == nil); #expect(query.sqlConfirmation == nil)
        await query.pageCache(1)?.value
        #expect(query.cacheOffset == 500); #expect(query.result?.rows.first == ["500", "雪😀", nil])
        let snapshot = try #require(query.queryExportSnapshot)
        var options = WorkspaceDataExportOptions(); options.scope = .allTableRows
        let request = try snapshot.request(options: options)
        var count = 0
        while let batch = try await request.source.nextBatch() { count += batch.count }
        await request.source.finish(); #expect(count == 10_000)
        query.safetyLock.disable(); query.sql = "DELETE FROM sample"
        await query.executeAll()?.value
        #expect(query.sqlConfirmation == nil); #expect(query.errorMessage != nil)
        #expect(query.transaction(.begin) == nil)
        await workspace.browser.loadDatabases().value; await workspace.browser.loadObjects()?.value
        let object = try #require(workspace.browser.catalog?.objects.first { $0.name == "sample" })
        await workspace.browser.selectObject(object)?.value
        workspace.browser.tab = .structure; await workspace.browser.loadTable()?.value
        #expect(workspace.browser.readOnlyStructure?.ddl.uppercased().contains("CREATE TABLE") == true)
        #expect(workspace.browser.readOnlyStructure?.object == object)
        #expect(workspace.browser.columns?.first { $0.name == "name" }?.comment == "真实字段注释")
        for sql in [
            "SELECT name AS alias,name,CAST(1 AS INT) AS name FROM sample LIMIT 1",
            "SELECT a.name AS first,b.name AS second FROM sample a JOIN sample b ON a.id=b.id LIMIT 1",
            "SELECT name AS alias,name,CAST(1 AS INT) AS name FROM sample WHERE id<0"
        ] {
            query.sql = sql; await query.executeAll()?.value
            #expect(query.errorMessage == nil)
            #expect(query.columnDetails.first?.contains("真实字段注释") == true)
            #expect(query.columnDetails.dropFirst().first?.contains("真实字段注释") == true)
            if query.columnDetails.count == 3 { #expect(!query.columnDetails[2].contains("真实字段注释")) }
        }
        workspace.cancelAll()
    }
}
