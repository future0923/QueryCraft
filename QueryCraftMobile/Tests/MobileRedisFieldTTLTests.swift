import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil)) @MainActor struct MobileRedisFieldTTLTests {
    @Test func fieldExpirationRoundTripOrLegacyFallback() async throws {
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:field-ttl:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 1))
        try await client.connect()
        do {
            _ = try await client.execute(["HSET", key, "a", "value", "keep", "unchanged"])
            _ = try await client.execute(["PEXPIRE", key, "120000"])
            let service = MobileRedisMutationService(profile: profile, password: nil)
            let editor = MobileRedisEditor(key: key, database: 1, service: service)
            await editor.reload()?.value; let snapshot = try #require(editor.snapshot)
            editor.safetyLock.disable()
            if ProcessInfo.processInfo.environment["PROOF_REDIS_FIELD_TTL"] == "1" { #expect(snapshot.hashFieldExpirationSupport == true) }
            if snapshot.hashFieldExpirationSupport != true {
                #expect(snapshot.hashFieldExpirationSupport == false)
                editor.rows[0].thirdValue = "60000"; editor.prepare(); #expect(editor.preview == nil)
            } else {
                let index = try #require(editor.rows.firstIndex { $0.firstValue == "a" })
                editor.rows[index].thirdValue = "0"; editor.prepare(); #expect(editor.preview == nil)
                editor.rows[index].thirdValue = "60000"; editor.prepare(); #expect(editor.preview?.contains("HPEXPIRE") == true)
                await editor.submit()?.value; #expect(!editor.needsVerification)
                let first = try #require(editor.rows.firstIndex { $0.firstValue == "a" })
                #expect(Int64(editor.rows[first].thirdValue) ?? 0 > 0)
                #expect(try await client.execute(["HGET", key, "a"]).stringValue == "value")
                editor.rows[first].thirdValue = ""; editor.prepare(); #expect(editor.preview?.contains("HPERSIST") == true)
                await editor.submit()?.value; #expect(!editor.needsVerification)
                let ref = RedisKeyReference(databaseIndex: 1, name: key, type: .hash)
                #expect(try await RedisHashFieldExpirationReader.read(fields: [.init(utf8: "a")], key: ref, client: client) == [-1])
                let updated = try #require(editor.rows.firstIndex { $0.firstValue == "a" })
                editor.rows[updated].thirdValue = "60000"; editor.prepare(); await editor.submit()?.value
                let rename = try #require(editor.rows.firstIndex { $0.firstValue == "a" })
                editor.rows[rename].firstValue = "renamed"; editor.prepare(); await editor.submit()?.value
                #expect(!editor.needsVerification)
                let ttls = try await RedisHashFieldExpirationReader.read(fields: [.init(utf8: "renamed"), .init(utf8: "a"), .init(utf8: "keep")], key: ref, client: client)
                #expect(ttls[0] > 0); #expect(ttls[1] == -2); #expect(ttls[2] == -1)
                // The shared Mac planner preserves HSET semantics when only value changes.
                let valueIndex = try #require(editor.rows.firstIndex { $0.firstValue == "renamed" })
                editor.rows[valueIndex].secondValue = "new"; editor.prepare(); await editor.submit()?.value
                #expect(try await RedisHashFieldExpirationReader.read(fields: [.init(utf8: "renamed")], key: ref, client: client) == [-1])
                #expect(try await client.execute(["PTTL", key]).integerValue ?? 0 > 0)
                #expect(try await client.execute(["EXISTS", key], databaseIndex: 0).integerValue == 0)
            }
            _ = try await client.execute(["DEL", key], databaseIndex: 1); await client.close()
        } catch { _ = try? await client.execute(["DEL", key], databaseIndex: 1); await client.close(); throw error }
    }
    @Test func deniedTTLReadCannotBecomePersistentSnapshot() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_REDIS_FIELD_TTL"] == "1" else { return }
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:field-acl:" + UUID().uuidString
        let username = "qc_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect()
        do {
            _ = try await client.execute(["HSET", key, "a", "value"])
            _ = try await client.execute(["ACL", "SETUSER", username, "on", ">proof", "~*", "+@all", "-hpttl"])
            var restricted = profile; restricted.username = username
            let editor = MobileRedisEditor(key: key, database: 0, service: MobileRedisMutationService(profile: restricted, password: "proof"))
            await editor.reload()?.value
            #expect(editor.snapshot == nil); #expect(editor.message != nil); #expect(!editor.hasLoaded)
            _ = try await client.execute(["ACL", "SETUSER", username, "+hpttl", "-command"])
            await editor.reload()?.value
            #expect(editor.snapshot != nil); #expect(editor.snapshot?.hashFieldExpirationSupport == nil)
            _ = try await client.execute(["DEL", key]); _ = try await client.execute(["ACL", "DELUSER", username]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); _ = try? await client.execute(["ACL", "DELUSER", username]); await client.close(); throw error }
    }
}
