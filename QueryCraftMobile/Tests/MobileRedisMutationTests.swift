import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil)) @MainActor struct MobileRedisMutationTests {
    static func profile() throws -> MobileConnectionProfile {
        var profile = MobileDriverSupportTests.profile(.redis)
        profile.port = try #require(ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"].flatMap(Int.init))
        return profile
    }
    private func fixture(_ body: (RedisClient, MobileRedisMutationService, String) async throws -> Void) async throws {
        let profile = try Self.profile(), key = "querycraft:mobile-edit:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect()
        do {
            try await body(client, .init(profile: profile, password: nil), key)
            _ = try await client.execute(["DEL", key]); _ = try await client.execute(["DEL", key], databaseIndex: 1)
            await client.close()
        } catch {
            _ = try? await client.execute(["DEL", key], databaseIndex: 0); _ = try? await client.execute(["DEL", key], databaseIndex: 1)
            await client.close(); throw error
        }
    }
    private func editor(_ service: any MobileRedisMutating, _ key: String) async throws -> MobileRedisEditor {
        let editor = MobileRedisEditor(key: key, database: 0, service: service)
        await editor.reload()?.value; #expect(editor.snapshot != nil); editor.safetyLock.disable(); return editor
    }
    private func submit(_ editor: MobileRedisEditor) async throws {
        editor.prepare(); #expect(editor.preview != nil)
        await editor.submit()?.value
        #expect(!editor.needsVerification); #expect(!editor.hasChanges)
    }

    @Test func binaryStringPreservesTTLAndDatabaseAndRequiresFreshConfirmation() async throws {
        try await fixture { client, service, key in
            _ = try await client.executeRaw([.init(utf8: "SET"), .init(utf8: key), .init(data: Data([0, 255, 65]))])
            _ = try await client.execute(["PEXPIRE", key, "60000"])
            _ = try await client.execute(["SET", key, "other database"], databaseIndex: 1)
            let editor = try await editor(service, key)
            #expect(editor.usesHex); #expect(editor.text == "00 ff 41")
            editor.text = "00 ff 42"; editor.safetyLock.enable(); editor.prepare(); #expect(editor.preview == nil)
            editor.safetyLock.disable(); editor.prepare(); editor.text = "00 ff 43"
            #expect(editor.submit() == nil); #expect(editor.preview == nil)
            try await submit(editor)
            #expect(try await client.executeRaw([.init(utf8: "GET"), .init(utf8: key)], databaseIndex: 0).dataValue == Data([0,255,67]))
            let ttl = try await client.execute(["PTTL", key]).integerValue ?? -1
            #expect(ttl > 0 && ttl <= 60000)
            #expect(try await client.execute(["GET", key], databaseIndex: 1).stringValue == "other database")
            editor.text = "invalid hex"; editor.prepare(); #expect(editor.preview == nil)
        }
    }
    @Test func hashRenameAddDeleteAndDestinationConflict() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["HSET", key, "a", "one", "b", "two"])
            let editor = try await editor(service, key)
            let first = try #require(editor.rows.firstIndex { $0.firstValue == "a" })
            editor.rows[first].firstValue = "renamed"; editor.rows[first].secondValue = "你好\0Redis"
            let second = try #require(editor.rows.first { $0.firstValue == "b" }); editor.removeRow(second.id)
            editor.addRow(); editor.rows[editor.rows.count - 1].firstValue = "c"; editor.rows[editor.rows.count - 1].secondValue = "three"
            editor.prepare(); #expect(editor.preview?.contains("\\x00") == true)
            try await submit(editor)
            #expect(try await client.execute(["HGET", key, "renamed"]).stringValue == "你好\0Redis")
            #expect(try await client.execute(["HEXISTS", key, "b"]).integerValue == 0)
            // Match Mac: another field changing does not conflict with this field.
            editor.rows[try #require(editor.rows.firstIndex { $0.firstValue == "renamed" })].secondValue = "edited again"
            _ = try await client.execute(["HSET", key, "unrelated", "external"])
            try await submit(editor)
            #expect(try await client.execute(["HGET", key, "unrelated"]).stringValue == "external")
            editor.addRow(); editor.rows[editor.rows.count - 1].firstValue = "external"
            editor.prepare(); _ = try await client.execute(["HSET", key, "external", "do not overwrite"])
            await editor.submit()?.value
            #expect(editor.hasChanges); #expect(!editor.needsVerification)
            #expect(try await client.execute(["HGET", key, "external"]).stringValue == "do not overwrite")
        }
    }
    @Test func listDuplicateDeletionAndHeadTailOrder() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["RPUSH", key, "same", "same", "third"])
            let editor = try await editor(service, key)
            editor.removeRow(editor.rows[0].id); editor.rows[1].secondValue = "edited"
            editor.addRow(head: true); editor.rows[3].secondValue = "head1"
            editor.addRow(head: true); editor.rows[4].secondValue = "head2"
            editor.addRow(); editor.rows[5].secondValue = "tail"
            try await submit(editor)
            #expect(try await client.execute(["LRANGE", key, "0", "-1"]).collectionValues?.compactMap(\.stringValue) == ["head1", "head2", "edited", "third", "tail"])
            editor.rows[0].secondValue = "should conflict"; editor.prepare()
            _ = try await client.execute(["LPUSH", key, "external"])
            await editor.submit()?.value; #expect(editor.hasChanges)
            #expect(try await client.execute(["LINDEX", key, "0"]).stringValue == "external")
        }
    }
    @Test func setAndSortedSetMemberEdits() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["SADD", key, "old", "delete"])
            let editor = try await editor(service, key)
            editor.rows[try #require(editor.rows.firstIndex { $0.firstValue == "old" })].firstValue = "new"
            editor.removeRow(try #require(editor.rows.first { $0.firstValue == "delete" }).id)
            editor.addRow(); editor.rows[editor.rows.count - 1].firstValue = "added"
            try await submit(editor)
            #expect(Set(try await client.execute(["SMEMBERS", key]).collectionValues?.compactMap(\.stringValue) ?? []) == ["new", "added"])
            _ = try await client.execute(["DEL", key]); _ = try await client.execute(["ZADD", key, "1.5", "old", "2", "delete"])
            await editor.reload(discard: true)?.value
            editor.rows[try #require(editor.rows.firstIndex { $0.firstValue == "old" })].firstValue = "new"
            editor.rows[try #require(editor.rows.firstIndex { $0.firstValue == "new" })].secondValue = "-3.25"
            editor.removeRow(try #require(editor.rows.first { $0.firstValue == "delete" }).id)
            editor.addRow(); editor.rows[editor.rows.count - 1].firstValue = "added"; editor.rows[editor.rows.count - 1].secondValue = "NaN"
            editor.prepare(); #expect(editor.preview == nil)
            editor.rows[editor.rows.count - 1].secondValue = "7"; try await submit(editor)
            #expect(try await client.execute(["ZSCORE", key, "new"]).stringValue == "-3.25")
            #expect(try await client.execute(["ZCARD", key]).integerValue == 2)
        }
    }
    @Test func ttlOnlyPersistentAndDeleteUseOriginalSnapshot() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["SET", key, "original"])
            let editor = try await editor(service, key)
            editor.expirationMode = .expires; editor.ttl = "0"; editor.prepare(); #expect(editor.preview == nil)
            editor.ttl = "60000"; try await submit(editor)
            #expect(try await client.execute(["PTTL", key]).integerValue ?? -1 > 0)
            editor.expirationMode = .persistent; try await submit(editor)
            #expect(try await client.execute(["PTTL", key]).integerValue == -1)
            editor.deleteKey = true; editor.prepare(); _ = try await client.execute(["SET", key, "external"])
            await editor.submit()?.value; #expect(editor.hasChanges)
            #expect(try await client.execute(["GET", key]).stringValue == "external")
            await editor.reload(discard: true)?.value; editor.deleteKey = true; try await submit(editor)
            #expect(editor.hasLoaded && editor.snapshot == nil)
            #expect(try await client.execute(["EXISTS", key]).integerValue == 0)
        }
    }
    @Test func binaryCollectionRowsCannotBeLossilyWritten() async throws {
        try await fixture { client, service, key in
            _ = try await client.executeRaw([.init(utf8: "HSET"), .init(utf8: key), .init(data: Data([255])), .init(data: Data([254])), .init(utf8: "text"), .init(utf8: "old")])
            let editor = try await editor(service, key)
            let binary = try #require(editor.rows.first { $0.isBinaryReadOnly })
            editor.removeRow(binary.id); #expect(editor.rows.first { $0.id == binary.id }?.isDeleted == false)
            editor.rows[try #require(editor.rows.firstIndex { $0.firstValue == "text" })].secondValue = "new"
            try await submit(editor)
            #expect(try await client.executeRaw([.init(utf8: "HGET"), .init(utf8: key), .init(data: Data([255]))]).dataValue == Data([254]))
        }
    }
    @Test func largeAndExpiredKeysCannotBeOverwrittenFromPreview() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["SET", key, String(repeating: "x", count: 1_048_577)])
            let complete = try #require(try await service.load(key: key, database: 0))
            #expect(complete.stringData?.data.count == 1_048_577)
            _ = try await client.execute(["DEL", key])
            _ = try await client.execute(["SETRANGE", key, String(RedisStringEditingLimit.maximumBytes), "x"])
            await #expect(throws: MobileRedisMutationError.self) { try await service.load(key: key, database: 0) }
            _ = try await client.execute(["SET", key, "small"])
            let editor = try await editor(service, key); editor.text = "new"; editor.prepare()
            _ = try await client.execute(["DEL", key]); await editor.submit()?.value
            #expect(editor.hasChanges); #expect(try await client.execute(["EXISTS", key]).integerValue == 0)
        }
    }
    @Test func lostAcknowledgementRequiresReadAndNeverReplays() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["SET", key, "old"])
            let fault = RedisMutationFaultService(base: service)
            let editor = try await editor(fault, key)
            editor.text = "committed"; editor.prepare(); await editor.submit()?.value
            #expect(editor.needsVerification); #expect(!editor.canClose); #expect(editor.submit() == nil)
            #expect(await fault.writeCount == 1)
            #expect(try await client.execute(["GET", key]).stringValue == "committed")
            await editor.reload(discard: true)?.value; #expect(editor.needsVerification)
            await editor.reload(discard: true)?.value
            #expect(!editor.needsVerification); #expect(!editor.hasChanges); #expect(editor.text == "committed")
            #expect(await fault.writeCount == 1)
        }
    }
    @Test func backgroundInvalidatesConfirmationButKeepsDraftAndSelection() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["SET", key, "old"])
            let profile = try Self.profile(), model = MobileResourceModel(profile: profile, password: nil)
            await model.load()?.value; model.select(.init(name: key, kind: "键")); await model.loadDetails()?.value
            model.beginRedisEditing(service: service)
            let editor = try #require(model.redisEditor); await editor.reload()?.value
            editor.safetyLock.disable(); editor.text = "draft"; editor.prepare()
            model.selectScope("1"); model.select(.init(name: "other", kind: "键"))
            #expect(model.scope == "0"); #expect(model.selected?.name == key)
            model.refresh(); #expect(editor.text == "draft")
            model.setBackgrounded(true); #expect(editor.preview == nil); #expect(editor.safetyLock.isEnabled)
            #expect(editor.submit() == nil); model.setBackgrounded(false)
            #expect(editor.text == "draft")
            editor.safetyLock.disable(); try await submit(editor)
            model.closeRedisEditor(); #expect(!model.hasPendingChanges)
        }
    }
    @Test func rejectedWatchAndAssertionReadsFailClosed() async throws {
        try await fixture { client, service, key in
            let username = "qc_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            _ = try await client.execute(["HSET", key, "old", "keep"])
            do {
                _ = try await client.execute(["ACL", "SETUSER", username, "on", ">proof", "~*", "+@all", "-watch"])
                var profile = try Self.profile(); profile.username = username
                let restricted = MobileRedisMutationService(profile: profile, password: "proof")
                let editor = try await editor(service, key)
                editor.addRow(); editor.rows[editor.rows.count - 1].firstValue = "new"; editor.rows[editor.rows.count - 1].secondValue = "value"
                let snapshot = try #require(editor.snapshot)
                let plan = try RedisKeyMutationPlan.make(details: snapshot.details, stringValue: "", rows: editor.rows, expirationMode: .persistent, ttlMillisecondsText: "")
                let request = try #require(plan.optimisticRequest)
                await #expect(throws: MobileRedisMutationError.self) { try await restricted.apply(request) }
                #expect(try await client.execute(["HEXISTS", key, "new"]).integerValue == 0)
                _ = try await client.execute(["ACL", "SETUSER", username, "+watch", "-hget"])
                await #expect(throws: MobileRedisMutationError.self) { try await restricted.apply(request) }
                #expect(try await client.execute(["HEXISTS", key, "new"]).integerValue == 0)
                _ = try await client.execute(["ACL", "DELUSER", username])
            } catch { _ = try? await client.execute(["ACL", "DELUSER", username]); throw error }
        }
    }
    @Test func binaryKeyNamesNeverAliasReplacementCharacterKeys() async throws {
        try await fixture { client, _, key in
            let bytes = Data(key.utf8) + Data([255]), replacement = key + "�"
            _ = try await client.executeRaw([.init(utf8: "SET"), .init(data: bytes), .init(utf8: "binary")])
            _ = try await client.execute(["SET", replacement, "text"])
            do {
                let profile = try Self.profile(), service = MobileResourceService(profile: profile, password: nil)
                var cursor: UInt64 = 0, resources: [MobileResource] = []
                repeat {
                    let page = try await service.catalog(scope: "0", cursor: cursor, search: key + "*")
                    resources += page.resources; cursor = page.cursor
                } while cursor != 0
                let binary = try #require(resources.first { $0.binaryKeyData == bytes })
                let text = try #require(resources.first { $0.name == replacement && $0.binaryKeyData == nil })
                #expect(binary.id != text.id)
                await #expect(throws: MobileRedisMutationError.self) { try await service.details(resource: binary, scope: "0", offset: 0, cursor: 0) }
                #expect(try await client.execute(["GET", replacement]).stringValue == "text")
                _ = try await client.executeRaw([.init(utf8: "DEL"), .init(data: bytes), .init(utf8: replacement)])
            } catch {
                _ = try? await client.executeRaw([.init(utf8: "DEL"), .init(data: bytes), .init(utf8: replacement)]); throw error
            }
        }
    }
    @Test func redisExecErrorCanPartiallyApplyAndMustBeVerified() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["SET", key, "old"])
            let snapshot = try #require(try await service.load(key: key, database: 0))
            let request = RedisOptimisticMutationRequest(reference: snapshot.details.reference, assertions: snapshot.assertions, operations: [
                .command(.init(source: "SET", utf8Arguments: ["SET", key, "applied"])),
                .command(.init(source: "LPUSH", utf8Arguments: ["LPUSH", key, "wrong type"]))
            ])
            await #expect(throws: MobileRedisMutationError.self) { try await service.apply(request) }
            #expect(try await client.execute(["GET", key]).stringValue == "applied")
        }
    }
}

private actor RedisMutationFaultService: MobileRedisMutating {
    let base: MobileRedisMutationService
    private(set) var writeCount = 0
    private var failRead = false
    init(base: MobileRedisMutationService) { self.base = base }
    func load(key: String, database: Int) async throws -> MobileRedisSnapshot? {
        if failRead { failRead = false; throw URLError(.notConnectedToInternet) }
        return try await base.load(key: key, database: database)
    }
    func apply(_ request: RedisOptimisticMutationRequest) async throws {
        writeCount += 1; try await base.apply(request); failRead = true
        throw MobileRedisMutationError.unverified("模拟 EXEC 成功后回执丢失")
    }
}
