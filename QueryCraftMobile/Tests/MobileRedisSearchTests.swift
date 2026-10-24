import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil)) @MainActor struct MobileRedisSearchTests {
    private func fixture(_ body: (RedisClient, MobileRedisMutationService, String) async throws -> Void) async throws {
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:search:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 1))
        try await client.connect()
        do {
            try await body(client, .init(profile: profile, password: nil), key)
            _ = try await client.execute(["DEL", key], databaseIndex: 1); await client.close()
        } catch { _ = try? await client.execute(["DEL", key], databaseIndex: 1); await client.close(); throw error }
    }
    @Test func listSearchFindsBeyondFirstPageAndEditsAbsoluteIndex() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["RPUSH", key] + (0..<1199).map(String.init) + ["Résumé"])
            let editor = MobileRedisEditor(key: key, database: 1, service: service)
            await editor.reload()?.value
            editor.searchState.draftText = " resume "; await editor.applySearch()?.value
            #expect(editor.activeSearch?.text == "resume"); #expect(editor.rows.count == 1)
            #expect(editor.rows.first?.originalIndex == 1199); #expect(editor.snapshot?.matchingCount == 1)
            editor.safetyLock.disable(); editor.deleteKey = true; editor.prepare(); #expect(editor.preview == nil); editor.deleteKey = false
            editor.rows[0].secondValue = "edited"; editor.prepare(); #expect(editor.preview != nil)
            editor.searchState.draftText = "other"; #expect(editor.applySearch() == nil)
            await editor.submit()?.value
            #expect(!editor.needsVerification); #expect(editor.rows.isEmpty); #expect(editor.activeSearch?.text == "resume")
            #expect(try await client.execute(["LINDEX", key, "1199"]).stringValue == "edited")
            await editor.applySearch(clear: true)?.value
            #expect(editor.activeSearch == nil); #expect(editor.pageNumber == 1); #expect(editor.rows.first?.originalIndex == 0)
        }
    }
    @Test func hashFieldsValuesLiteralGlobAndBroadSearchPagination() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["HSET", key] + (0..<1200).flatMap { ["field\($0)", "value\($0)"] } + ["literal*?[x]", "Résumé"])
            let editor = MobileRedisEditor(key: key, database: 1, service: service); await editor.reload()?.value
            editor.searchState.field = .field; editor.searchState.mode = .prefix; editor.searchState.isCaseSensitive = true; editor.searchState.draftText = "field"
            await editor.applySearch()?.value
            #expect(editor.rows.count > 0 && editor.rows.count <= 1000); #expect(editor.snapshot?.continuation != nil)
            let first = editor.rows.map(\.firstValue); await editor.nextPage()?.value
            #expect(editor.pageNumber == 2); #expect(editor.rows.map(\.firstValue) != first)
            editor.searchState.mode = .exact; editor.searchState.draftText = "literal*?[x]"
            await editor.applySearch()?.value
            #expect(editor.pageNumber == 1); #expect(editor.rows.map(\.firstValue) == ["literal*?[x]"])
            editor.searchState.field = .value; editor.searchState.isCaseSensitive = false; editor.searchState.draftText = "resume"
            await editor.applySearch()?.value; #expect(editor.rows.count == 1)
            editor.searchState.isCaseSensitive = true; await editor.applySearch()?.value
            #expect(editor.rows.isEmpty); #expect(editor.snapshot?.matchingCount == 0)
        }
    }
    @Test func setCaseSensitivityAndSortedSetScoreAndDescendingOrder() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["SADD", key, "Alpha", "alphabet", "other"])
            let editor = MobileRedisEditor(key: key, database: 1, service: service); await editor.reload()?.value
            editor.searchState.draftText = "alpha"; editor.searchState.mode = .prefix; await editor.applySearch()?.value
            #expect(Set(editor.rows.map(\.firstValue)) == ["Alpha", "alphabet"])
            editor.searchState.isCaseSensitive = true; await editor.applySearch()?.value
            #expect(editor.rows.map(\.firstValue) == ["alphabet"])
            _ = try await client.execute(["DEL", key]); _ = try await client.execute(["ZADD", key, "2", "member-low", "10", "member-high", "1", "other"])
            let sorted = MobileRedisEditor(key: key, database: 1, service: service); await sorted.reload()?.value
            sorted.searchState.field = .member; sorted.searchState.draftText = "member"; sorted.searchState.mode = .prefix
            await sorted.applySearch()?.value; #expect(sorted.rows.map(\.firstValue) == ["member-high", "member-low"])
            sorted.searchState.field = .score; sorted.searchState.mode = .exact; sorted.searchState.draftText = "10.0"
            await sorted.applySearch()?.value; #expect(sorted.rows.map(\.firstValue) == ["member-high"])
        }
    }
}

@MainActor struct MobileRedisSearchStateTests {
    @Test func rapidSearchFailureRetryClearAndBackgroundRejectStaleReply() async throws {
        let service = SearchGateService()
        let model = MobileRedisEditor(key: "key", database: 0, service: service)
        await model.reload()?.value; await service.holdNext()
        model.searchState.draftText = "first"; let old = model.applySearch(); await service.waitForRead()
        #expect(model.isSearchPending); #expect(model.rows.first?.firstValue == "all")
        model.searchState.draftText = "second"; await model.applySearch()?.value
        #expect(model.activeSearch?.text == "second"); await service.release(); await old?.value
        #expect(model.rows.first?.firstValue == "second")
        await service.failNext(); model.searchState.draftText = "retry"; await model.applySearch()?.value
        #expect(model.activeSearch?.text == "second"); #expect(model.isSearchPending); #expect(!model.canEdit)
        await model.reload()?.value; #expect(model.activeSearch?.text == "retry")
        await service.holdNext(); model.searchState.draftText = "late"; let late = model.applySearch(); await service.waitForRead()
        model.setBackgrounded(true); await service.release(); await late?.value
        #expect(model.activeSearch?.text == "retry"); #expect(model.isSearchPending)
        model.setBackgrounded(false); await model.applySearch(clear: true)?.value
        #expect(model.activeSearch == nil); #expect(!model.isSearchPending); #expect(model.rows.first?.firstValue == "all")
    }
}

private actor SearchGateService: MobileRedisMutating {
    private var hold = false, fail = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func holdNext() { hold = true }
    func failNext() { fail = true }
    func waitForRead() async { if held != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { held?.resume(); held = nil }
    private func snapshot(_ name: String) -> MobileRedisSnapshot {
        .init(details: .init(reference: .init(databaseIndex: 0, name: "key", type: .hash), ttlMilliseconds: nil, memoryUsageBytes: nil, encoding: nil, value: .init(columns: [], rows: [], isTruncated: false)), stringData: nil, rows: [.init(isNew: false, firstValue: name, secondValue: "value")], count: 1)
    }
    func load(key: String, database: Int) async throws -> MobileRedisSnapshot? { snapshot("all") }
    func apply(_ request: RedisOptimisticMutationRequest) async throws {}
    func searchPage(key: String, database: Int, continuation: RedisCollectionContinuation?, search: RedisCollectionSearch?) async throws -> MobileRedisSnapshot? {
        if hold { hold = false; await withCheckedContinuation { held = $0; for waiter in waiters { waiter.resume() }; waiters = [] } }
        if fail { fail = false; throw URLError(.notConnectedToInternet) }
        return snapshot(search?.text ?? "all")
    }
}
