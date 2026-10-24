import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil)) @MainActor struct MobileRedisPagingTests {
    @Test func largeCollectionsEditLaterPageAndRejectWholeKeyOperations() async throws {
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:page:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 1))
        try await client.connect()
        do {
            for type in [RedisKeyType.list, .hash, .set, .sortedSet] {
                _ = try await client.execute(["DEL", key], databaseIndex: 1)
                let members = (0..<1200).map { String(format: "member%04d", $0) }
                let command: [String]
                switch type {
                case .list: command = ["RPUSH", key] + members
                case .hash: command = ["HSET", key] + members.flatMap { [$0, "value"] }
                case .set: command = ["SADD", key] + members
                default: command = ["ZADD", key] + members.enumerated().flatMap { [String($0.offset), $0.element] }
                }
                _ = try await client.execute(command)
                _ = try await client.execute(["PEXPIRE", key, "120000"])
                let editor = MobileRedisEditor(key: key, database: 1, service: MobileRedisMutationService(profile: profile, password: nil))
                await editor.reload()?.value
                #expect(editor.snapshot?.isPartial == true); #expect(editor.snapshot?.count == 1200)
                let first = editor.rows.map(\.originalFirstValue)
                editor.safetyLock.disable(); editor.deleteKey = true; editor.prepare(); #expect(editor.preview == nil); editor.deleteKey = false
                editor.expirationMode = .persistent; editor.prepare(); #expect(editor.preview == nil)
                editor.expirationMode = .expires
                await editor.nextPage()?.value
                #expect(editor.pageNumber == 2); #expect(editor.rows.map(\.originalFirstValue) != first)
                let target = try #require(editor.rows.first)
                if type == .set { editor.rows[0].firstValue = "edited-member" }
                else { editor.rows[0].secondValue = type == .sortedSet ? "9000" : "edited-value" }
                #expect(editor.nextPage() == nil); #expect(editor.previousPage() == nil)
                editor.prepare(); #expect(editor.preview != nil); await editor.submit()?.value
                #expect(!editor.needsVerification); #expect(!editor.hasChanges); #expect(editor.pageNumber == 2)
                let reply: RedisReplyValue
                switch type {
                case .list: reply = try await client.execute(["LINDEX", key, String(try #require(target.originalIndex))])
                case .hash: reply = try await client.execute(["HGET", key, target.originalFirstValue])
                case .set: reply = try await client.execute(["SISMEMBER", key, "edited-member"])
                default: reply = try await client.execute(["ZSCORE", key, target.originalFirstValue])
                }
                if type == .set { #expect(reply.integerValue == 1) }
                else if type == .sortedSet { #expect(Double(reply.stringValue ?? "") == 9000) }
                else { #expect(reply.stringValue == "edited-value") }
                await editor.previousPage()?.value; #expect(editor.pageNumber == 1)
                #expect(try await client.execute(["PTTL", key]).integerValue ?? 0 > 0)
                #expect(try await client.execute(["EXISTS", key], databaseIndex: 0).integerValue == 0)
            }
            _ = try await client.execute(["DEL", key], databaseIndex: 1); await client.close()
        } catch { _ = try? await client.execute(["DEL", key], databaseIndex: 1); await client.close(); throw error }
    }
    @Test func backgroundRejectsLatePageAndReadFailureKeepsCurrentPage() async throws {
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:page-held:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect()
        do {
            _ = try await client.execute(["RPUSH", key] + (0..<1200).map(String.init))
            let service = HeldPageService(base: .init(profile: profile, password: nil))
            let editor = MobileRedisEditor(key: key, database: 0, service: service)
            await editor.reload()?.value; let ids = editor.rows.map(\.originalFirstValue)
            await service.holdNext(); let request = editor.nextPage(); await service.waitUntilHeld()
            #expect(editor.isLoading); #expect(editor.rows.map(\.originalFirstValue) == ids)
            editor.setBackgrounded(true); await service.release(); await request?.value
            editor.setBackgrounded(false)
            #expect(editor.pageNumber == 1); #expect(editor.rows.map(\.originalFirstValue) == ids)
            await service.failNext(); await editor.nextPage()?.value
            #expect(editor.pageNumber == 1); #expect(editor.rows.map(\.originalFirstValue) == ids); #expect(editor.message != nil)
            await editor.nextPage()?.value; #expect(editor.pageNumber == 2)
            _ = try await client.execute(["DEL", key]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }
    @Test func listPageKeepsAbsoluteIndicesAndConflictsOnConcurrentInsertion() async throws {
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:page-conflict:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect()
        do {
            _ = try await client.execute(["RPUSH", key] + (0..<1200).map(String.init))
            let editor = MobileRedisEditor(key: key, database: 0, service: MobileRedisMutationService(profile: profile, password: nil))
            await editor.reload()?.value; await editor.nextPage()?.value
            #expect(editor.rows.first?.originalIndex == 200)
            editor.safetyLock.disable(); editor.rows[0].secondValue = "changed"; editor.prepare()
            _ = try await client.execute(["LPUSH", key, "external"])
            await editor.submit()?.value; #expect(editor.hasChanges); #expect(!editor.needsVerification)
            #expect(try await client.execute(["LINDEX", key, "200"]).stringValue == "199")
            _ = try await client.execute(["DEL", key]); _ = try await client.execute(["HSET", key, "different-type", "value"])
            await editor.reload(discard: true)?.value
            #expect(editor.snapshot?.details.reference.type == .list); #expect(editor.hasChanges); #expect(editor.message != nil)
            _ = try await client.execute(["DEL", key]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }
}

private actor HeldPageService: MobileRedisMutating {
    let base: MobileRedisMutationService
    var hold = false, fail = false
    var held: CheckedContinuation<Void, Never>?
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(base: MobileRedisMutationService) { self.base = base }
    func holdNext() { hold = true }
    func failNext() { fail = true }
    func waitUntilHeld() async { if held != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { held?.resume(); held = nil }
    func load(key: String, database: Int) async throws -> MobileRedisSnapshot? { try await base.load(key: key, database: database) }
    func apply(_ request: RedisOptimisticMutationRequest) async throws { try await base.apply(request) }
    func loadPage(key: String, database: Int, continuation: RedisCollectionContinuation?) async throws -> MobileRedisSnapshot? {
        if hold {
            hold = false
            await withCheckedContinuation { held = $0; for waiter in waiters { waiter.resume() }; waiters = [] }
        }
        if fail { fail = false; throw URLError(.notConnectedToInternet) }
        return try await base.loadPage(key: key, database: database, continuation: continuation)
    }
}
