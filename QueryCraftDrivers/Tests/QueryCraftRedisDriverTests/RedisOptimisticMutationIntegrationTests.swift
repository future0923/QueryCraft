import Foundation
import QueryCraftFeature
import Testing
@testable import QueryCraftRedisDriver

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil))
struct RedisOptimisticMutationIntegrationTests {
    @Test func watchAndAssertionACLFailuresNeverReachExec() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"].flatMap(Int.init))
        let client = RedisClient(configuration: .init(host: "127.0.0.1", port: port, username: "", password: nil, databaseIndex: 0))
        let username = "qc_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let key = "querycraft:desktop-mutation:" + UUID().uuidString
        try await client.connect()
        let restricted = RedisClient(configuration: .init(host: "127.0.0.1", port: port, username: username, password: "proof", databaseIndex: 0))
        do {
            _ = try await client.execute(["HSET", key, "old", "keep"])
            _ = try await client.execute(["ACL", "SETUSER", username, "on", ">proof", "~*", "+@all", "-watch"])
            try await restricted.connect()
            let request = RedisOptimisticMutationRequest(reference: .init(databaseIndex: 0, name: key, type: .hash), assertions: [.keyType(.hash), .hashValue(field: .init(utf8: "new"), value: nil)], operations: [.command(.init(source: "HSET", utf8Arguments: ["HSET", key, "new", "value"]))])
            await #expect(throws: RedisClientError.self) { try await restricted.executeOptimisticMutation(request) }
            #expect(try await client.execute(["HEXISTS", key, "new"]).integerValue == 0)
            _ = try await client.execute(["ACL", "SETUSER", username, "+watch", "-hget"])
            await #expect(throws: RedisClientError.self) { try await restricted.executeOptimisticMutation(request) }
            #expect(try await client.execute(["HEXISTS", key, "new"]).integerValue == 0)
            _ = try await client.execute(["ACL", "SETUSER", username, "+hget"])
            try await restricted.executeOptimisticMutation(request)
            #expect(try await client.execute(["HGET", key, "new"]).stringValue == "value")
            await #expect(throws: RedisWorkspaceError.self) { try await restricted.executeOptimisticMutation(request) }
            await restricted.close(); _ = try await client.execute(["ACL", "DELUSER", username]); _ = try await client.execute(["DEL", key]); await client.close()
        } catch {
            await restricted.close(); _ = try? await client.execute(["ACL", "DELUSER", username]); _ = try? await client.execute(["DEL", key]); await client.close(); throw error
        }
    }
    @Test func resp3NumericScoresMatchScanStrings() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"].flatMap(Int.init))
        let client = RedisClient(configuration: .init(host: "127.0.0.1", port: port, username: "", password: nil, databaseIndex: 0))
        let key = "querycraft:desktop-score:" + UUID().uuidString
        try await client.connect()
        do {
            _ = try await client.execute(["ZADD", key, "2", "member"])
            let request = RedisOptimisticMutationRequest(reference: .init(databaseIndex: 0, name: key, type: .sortedSet), assertions: [.keyType(.sortedSet), .sortedSetScore(member: .init(utf8: "member"), score: "2")], operations: [.command(.init(source: "ZADD", utf8Arguments: ["ZADD", key, "3.5", "member"]))])
            try await client.executeOptimisticMutation(request)
            #expect(try await client.execute(["ZSCORE", key, "member"]).stringValue == "3.5")
            await #expect(throws: RedisWorkspaceError.self) { try await client.executeOptimisticMutation(request) }
            _ = try await client.execute(["DEL", key]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }

}
