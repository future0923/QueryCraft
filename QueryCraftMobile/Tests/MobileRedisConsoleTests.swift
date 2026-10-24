import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil)) @MainActor struct MobileRedisConsoleTests {
    private func fixture(_ body: (RedisClient, MobileConnectionProfile, String) async throws -> Void) async throws {
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:console:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect()
        do {
            try await body(client, profile, key)
            for db in [0,1] { _ = try await client.execute(["DEL", key], databaseIndex: db) }; await client.close()
        } catch { for db in [0,1] { _ = try? await client.execute(["DEL", key], databaseIndex: db) }; await client.close(); throw error }
    }
    private func run(_ console: MobileRedisConsole, _ source: String) async {
        console.document.updateSource(source)
        if console.document.requiresSafetyLockDisable { console.prepare() }
        await console.run()?.value
    }
    @Test func safetyExactConfirmationQuotesHistorySelectAndTransaction() async throws {
        try await fixture { client, profile, key in
            let console = MobileRedisConsole(profile: profile, password: nil, database: 0, keys: [])
            console.document.updateSource("SET \(key) '你好 Redis'"); console.prepare(); #expect(console.preview == nil); #expect(console.run() == nil)
            console.safetyLock.disable(); console.prepare(); console.document.updateSource("SET \(key) changed")
            #expect(console.run() == nil)
            await run(console, "SET \(key) '你好 Redis'")
            let initial = try await client.execute(["GET", key])
            #expect(initial.stringValue == "你好 Redis")
            await run(console, "MULTI"); await run(console, "SELECT 1"); await run(console, "SET \(key) other-db")
            #expect(console.transactionOpen)
            let beforeCommit = try await client.execute(["GET", key], databaseIndex: 1)
            #expect(beforeCommit == .null)
            await run(console, "EXEC"); #expect(!console.transactionOpen); #expect(console.database == 1)
            await run(console, "GET \(key)")
            guard case .success(let reply, _) = console.document.transcriptEntries.last?.outcome else { Issue.record("Missing reply"); return }
            #expect(reply == .bulkString("other-db"))
            #expect(console.document.showPreviousCommand()); #expect(console.document.source == "GET \(key)")
            console.document.updateSource(""); await console.close()
        }
    }
    @Test func backgroundDiscardsQueuedCommandsAndUnknownReceiptNeverReplays() async throws {
        try await fixture { client, profile, key in
            let console = MobileRedisConsole(profile: profile, password: nil, database: 0, keys: [])
            console.safetyLock.disable(); await run(console, "MULTI"); await run(console, "SET \(key) discarded")
            console.setBackgrounded(true); await console.close(); console.setBackgrounded(false)
            #expect(console.safetyLock.isEnabled); #expect(try await client.execute(["GET", key]) == .null)
            let fault = ConsoleFaultService(base: .init(profile: profile, password: nil, database: 0))
            let uncertain = MobileRedisConsole(profile: profile, password: nil, database: 0, keys: [], injectedService: fault)
            uncertain.safetyLock.disable(); await run(uncertain, "SET \(key) committed")
            #expect(uncertain.needsVerification); #expect(!uncertain.canClose); #expect(uncertain.run() == nil)
            #expect(try await client.execute(["GET", key]).stringValue == "committed")
            await uncertain.verify()?.value; #expect(!uncertain.needsVerification); #expect(uncertain.canClose)
            #expect(await fault.writes == 1); await uncertain.close()
            _ = try await client.execute(["DEL", key])
            let gate = ConsoleFaultService(base: .init(profile: profile, password: nil, database: 0), losesReply: false)
            let held = MobileRedisConsole(profile: profile, password: nil, database: 0, keys: [], injectedService: gate)
            held.safetyLock.disable(); await run(held, "MULTI")
            await gate.holdNext(); held.document.updateSource("SET \(key) not-executed"); held.prepare()
            let pending = held.run(); await gate.waitUntilHeld()
            held.setBackgrounded(true); await gate.release(); await pending?.value
            #expect(!held.transactionOpen); #expect(held.safetyLock.isEnabled)
            #expect(try await client.execute(["GET", key]) == .null); await held.close()
        }
    }
    @Test func immediateForegroundWaitsForIdleTransactionConnectionClose() async throws {
        try await fixture { client, profile, key in
            let gate = ConsoleFaultService(base: .init(profile: profile, password: nil, database: 0), losesReply: false)
            let console = MobileRedisConsole(profile: profile, password: nil, database: 0, keys: [], injectedService: gate)
            console.safetyLock.disable(); await run(console, "MULTI"); await run(console, "SET \(key) discarded")
            await gate.holdNextClose()
            console.setBackgrounded(true); console.setBackgrounded(false)
            await gate.waitUntilHeld()
            #expect(console.isClosingConnection); #expect(!console.canRun); #expect(!console.canClose)
            console.document.updateSource("EXEC"); #expect(console.run() == nil)
            await gate.release(); await console.close()
            #expect(!console.isClosingConnection); #expect(console.canRun)
            let actual = try await client.execute(["GET", key])
            #expect(actual == .null)
        }
    }
    @Test func deniedVerificationReadKeepsUnknownWriteFence() async throws {
        try await fixture { client, profile, key in
            let user = "qc_verify_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            _ = try await client.execute(["ACL", "SETUSER", user, "on", ">qc-local-proof", "~" + key, "-@all", "+hello", "+select", "+set", "+get"])
            do {
                var restricted = profile; restricted.username = user
                let service = ConsoleFaultService(base: .init(profile: restricted, password: "qc-local-proof", database: 0))
                let console = MobileRedisConsole(profile: restricted, password: "qc-local-proof", database: 0, keys: [], injectedService: service)
                console.safetyLock.disable(); await run(console, "SET \(key) confirmed-server-write")
                #expect(console.needsVerification)
                await console.verify()?.value
                #expect(console.needsVerification); #expect(!console.canRun); #expect(!console.canClose)
                #expect(console.message?.contains("NOPERM") == true)
                let actual = try await client.execute(["GET", key])
                #expect(actual.stringValue == "confirmed-server-write")
                await service.close(); _ = try await client.execute(["ACL", "DELUSER", user])
            } catch { _ = try? await client.execute(["ACL", "DELUSER", user]); throw error }
        }
    }
    @Test func binaryOutputBudgetAndJSONPresentationPreserveOriginalBytes() async throws {
        try await fixture { client, profile, key in
            _ = try await client.execute(["SET", key, "{\"large\":12345678901234567890,\"text\":\"\\u4f60\"}"])
            let editor = MobileRedisEditor(key: key, database: 0, service: MobileRedisMutationService(profile: profile, password: nil))
            await editor.reload()?.value
            let data = editor.stringExportData; await editor.toggleJSONPresentation()?.value
            #expect(editor.jsonPresentation?.contains("12345678901234567890") == true)
            #expect(editor.jsonPresentation?.contains("\\u4f60") == true); #expect(!editor.hasChanges); #expect(editor.stringExportData == data)
            let bounded = RedisReplyValue.array((0..<10000).map { _ in .bulkString(String(repeating: "x", count: 100)) }).boundedText(maximumBytes: 1000)
            #expect(bounded.utf8.count < 1100); #expect(bounded.contains("输出已截断"))
            _ = try await client.execute(["DEL", key])
            _ = try await client.executeRaw([.init(utf8: "HSET"), .init(utf8: key), .init(data: Data([255])), .init(data: Data([254])), .init(utf8: "text"), .init(utf8: "value")])
            await editor.reload(discard: true)?.value
            editor.selectAllRows()
            let exportedData = try #require(await editor.commandExport(selectedOnly: true))
            let exported = String(decoding: exportedData, as: UTF8.self)
            #expect(exported.contains("\\xff")); #expect(exported.contains("\\xfe"))
            editor.removeSelectedRows(); editor.safetyLock.disable(); editor.prepare(); await editor.submit()?.value
            #expect(try await client.execute(["HLEN", key]).integerValue == 1)
            #expect(try await client.executeRaw([.init(utf8: "HGET"), .init(utf8: key), .init(data: Data([255]))]).dataValue == Data([254]))
        }
    }
    @Test func metadataActionsWorkForLargeCollectionsAndStreamWithoutValueSnapshot() async throws {
        try await fixture { client, profile, key in
            _ = try await client.execute(["RPUSH", key] + (0..<1200).map(String.init))
            let service = MobileRedisKeyActionService(profile: profile, password: nil)
            let reference = RedisKeyReference(databaseIndex: 0, name: key)
            let ttl = MobileRedisKeyAction(mode: .metadata(reference, .expiration), database: 0, service: service)
            #expect(!ttl.canEdit); await ttl.loadMetadata()?.value; #expect(ttl.canEdit); #expect(ttl.type == .list)
            ttl.safetyLock.disable(); ttl.expirationMode = .expires; ttl.ttl = "60000"; ttl.prepare(); await ttl.submit()?.value
            #expect(ttl.succeeded); #expect(ttl.canClose)
            #expect(try await client.execute(["LLEN", key]).integerValue == 1200)
            #expect(try await client.execute(["PTTL", key]).integerValue ?? 0 > 0)
            let deletion = MobileRedisKeyAction(mode: .metadata(reference, .delete), database: 0, service: service)
            await deletion.loadMetadata()?.value; deletion.prepare(); #expect(deletion.preview == nil)
            deletion.safetyLock.disable(); deletion.prepare(); await deletion.submit()?.value
            #expect(deletion.succeeded); #expect(deletion.statuses?.first?.exists == false)
            _ = try await client.execute(["XADD", key, "*", "field", "value"])
            let streamTTL = MobileRedisKeyAction(mode: .metadata(reference, .expiration), database: 0, service: service)
            await streamTTL.loadMetadata()?.value; #expect(streamTTL.type == .stream)
            streamTTL.safetyLock.disable(); streamTTL.expirationMode = .expires; streamTTL.ttl = "60000"; streamTTL.prepare(); await streamTTL.submit()?.value
            #expect(streamTTL.succeeded); #expect(try await client.execute(["XLEN", key]).integerValue == 1)
            let missing = MobileRedisKeyAction(mode: .metadata(.init(databaseIndex: 0, name: key + "-missing"), .delete), database: 0, service: service)
            await missing.loadMetadata()?.value; #expect(!missing.canEdit); #expect(missing.message != nil); #expect(missing.canClose)
        }
    }
    @Test func segmentedUnicodeDraftRetainsWholeValueAndChecksBytesOutsidePreview() async throws {
        try await fixture { client, profile, key in
            let source = String(repeating: "你🙂e\u{301}\n", count: 10_000)
            _ = try await client.execute(["SET", key, source])
            let editor = MobileRedisEditor(key: key, database: 0, service: MobileRedisMutationService(profile: profile, password: nil))
            await editor.reload()?.value; #expect(editor.usesStringSegments)
            await editor.switchFormat(true)?.value; #expect(editor.usesHex); #expect(!editor.hasChanges)
            await editor.switchFormat(false)?.value; #expect(!editor.usesHex); #expect(editor.text == source)
            let first = editor.stringEditorText; #expect(first.utf8.count <= 32_772)
            editor.updateStringEditorText(first + "新增")
            let expected = first + "新增" + String(decoding: source.utf8.dropFirst(first.utf8.count), as: UTF8.self)
            #expect(editor.text == expected); #expect(await editor.rawStringExport() == Data(expected.utf8))
            editor.nextStringSegment(); let second = editor.stringEditorText
            #expect(editor.stringPageOffset > 0); #expect(!second.contains("�"))
            editor.updateStringEditorText("改" + second); editor.previousStringSegment()
            #expect(editor.stringPageOffset == 0); #expect(editor.text.hasSuffix(String(source.suffix(100))))
            editor.safetyLock.disable(); await editor.prepare()?.value; #expect(editor.preview?.contains("预览已截断") == true)
            editor.text += "尾部"; #expect(editor.submit() == nil)
            await editor.prepare()?.value; _ = try await client.execute(["SETRANGE", key, String(source.utf8.count - 1), "z"])
            await editor.submit()?.value; #expect(editor.hasChanges); #expect(!editor.needsVerification)
            #expect(try await client.execute(["GETRANGE", key, "-1", "-1"]).stringValue == "z")
            let binary = Data((0..<1_048_576).map { UInt8($0 % 256) })
            _ = try await client.executeRaw([.init(utf8: "SET"), .init(utf8: key), .init(data: binary)])
            await editor.reload(discard: true)?.value; #expect(editor.usesHex); #expect(!editor.hasChanges)
            await editor.switchFormat(false)?.value; #expect(editor.usesHex); #expect(!editor.hasChanges)
            let hexPage = editor.stringEditorText
            editor.updateStringEditorText("01" + hexPage.dropFirst(2))
            let changed = await editor.rawStringExport(); #expect(changed?.first == 1); #expect(changed?.last == 255)
            await editor.prepare()?.value; await editor.submit()?.value
            #expect(!editor.needsVerification)
            #expect(try await client.executeRaw([.init(utf8: "GETRANGE"), .init(utf8: key), .init(utf8: "0"), .init(utf8: "0")]).dataValue == Data([1]))
            #expect(try await client.execute(["STRLEN", key]).integerValue == 1_048_576)
        }
    }
    @Test func consoleRetainsBoundedReplyPrefixesAndRecentTranscript() async {
        let profile = MobileDriverSupportTests.profile(.redis)
        let console = MobileRedisConsole(profile: profile, password: nil, database: 0, keys: [], injectedService: ConsoleStaticReplyService())
        for _ in 0..<75 { console.document.updateSource("PING"); await console.run()?.value }
        #expect(console.document.transcriptEntries.count < 75)
        guard case .success(let reply, _) = console.document.transcriptEntries.last?.outcome else { Issue.record("Missing retained reply"); return }
        #expect(reply.boundedText().contains("仅保留回复展示前缀"))
        #expect(reply.estimatedByteCount(upTo: 100_000) < 70_000)
        #expect(console.document.showPreviousCommand()); #expect(console.document.source == "PING")
    }
    @Test func primaryCollectionGridSharesMacOrderPaginationAndBinaryIdentity() async throws {
        try await fixture { client, profile, key in
            var args = ["ZADD", key]
            for i in 0..<205 { args += [String(i), "member\(i)"] }
            _ = try await client.execute(args)
            let service = MobileResourceService(profile: profile, password: nil), resource = MobileResource(name: key, kind: "key")
            let first = try await service.details(resource: resource, scope: "0", offset: 0, cursor: 0)
            #expect(first.data.rows.first?[0] == "member204"); #expect(first.hasNext)
            let second = try await service.details(resource: resource, scope: "0", offset: 100, cursor: first.nextCursor)
            #expect(second.data.rows.first?[0] == "member104")
            let third = try await service.details(resource: resource, scope: "0", offset: 200, cursor: second.nextCursor)
            #expect(third.data.rows.count == 5); #expect(third.data.rows.last?[0] == "member0"); #expect(!third.hasNext)
            _ = try await client.execute(["DEL", key]); _ = try await client.execute(["RPUSH", key] + (0..<205).map(String.init))
            let list = try await service.details(resource: resource, scope: "0", offset: 0, cursor: 0)
            let list2 = try await service.details(resource: resource, scope: "0", offset: 100, cursor: list.nextCursor)
            #expect(list2.data.rows.first == ["100", "100"])
            _ = try await client.execute(["DEL", key])
            _ = try await client.executeRaw([.init(utf8: "HSET"), .init(utf8: key), .init(data: Data([255])), .init(data: Data([254]))])
            let hash = try await service.details(resource: resource, scope: "0", offset: 0, cursor: 0)
            #expect(hash.data.rows.first == ["HEX: ff", "HEX: fe"])
        }
    }
    @Test func streamPagesUseActualIDsAndCatalogMatchModes() async throws {
        try await fixture { client, profile, key in
            for i in 1...205 { _ = try await client.execute(["XADD", key, "\(i)-0", "field", "value\(i)"]) }
            let service = MobileResourceService(profile: profile, password: nil)
            let resource = MobileResource(name: key, kind: "key")
            let first = try await service.details(resource: resource, scope: "0", offset: 0, cursor: 0)
            #expect(first.data.rows.first?[0] == "1-0"); #expect(first.hasNext); #expect(first.redisType == .stream)
            let second = try await service.details(resource: resource, scope: "0", offset: 100, cursor: first.nextCursor)
            #expect(second.data.rows.first?[0] == "101-0")
            let third = try await service.details(resource: resource, scope: "0", offset: 200, cursor: second.nextCursor)
            #expect(third.data.rows.count == 5); #expect(!third.hasNext)
            let model = MobileResourceModel(profile: profile, password: nil)
            await model.load()?.value; model.search = key; model.redisSearchMode = .exact; await model.loadCatalog()?.value
            #expect(model.catalog?.contains { $0.name == key } == true)
            #expect(RedisKeySearchMatchMode.exact.scanPattern(for: "a*b") == "a\\*b")
            #expect(RedisKeySearchMatchMode.prefix.scanPattern(for: "a?b") == "a\\?b*")
        }
    }
}

private actor ConsoleFaultService: MobileRedisConsoleServing {
    let base: MobileRedisConsoleService
    private(set) var writes = 0
    let losesReply: Bool
    private var holdClose = false
    private var hold = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(base: MobileRedisConsoleService, losesReply: Bool = true) { self.base = base; self.losesReply = losesReply }
    func holdNext() { hold = true }
    func holdNextClose() { holdClose = true }
    func waitUntilHeld() async { if held != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { held?.resume(); held = nil }
    func execute(_ invocation: RedisCommandInvocation) async throws -> MobileRedisConsoleResult {
        let result = try await base.execute(invocation)
        if hold { hold = false; await withCheckedContinuation { held = $0; for waiter in waiters { waiter.resume() }; waiters = [] } }
        if invocation.arguments.first == "SET", losesReply { writes += 1; throw MobileRedisMutationError.unverified("模拟成功后回执丢失") }
        return result
    }
    func suggestions(_ request: RedisCommandSuggestionRequest) async throws -> [String] { try await base.suggestions(request) }
    func close() async {
        if holdClose { holdClose = false; await withCheckedContinuation { held = $0; for waiter in waiters { waiter.resume() }; waiters = [] } }
        await base.close()
    }
    func verifyConnection() async throws { try await base.verifyConnection() }
}

private struct ConsoleStaticReplyService: MobileRedisConsoleServing {
    func execute(_ invocation: RedisCommandInvocation) async throws -> MobileRedisConsoleResult {
        .init(result: .init(invocation: invocation, reply: .bulkString(String(repeating: "line\n", count: 40_000)), elapsedSeconds: 0), database: 0, transactionOpen: false)
    }
    func suggestions(_ request: RedisCommandSuggestionRequest) async throws -> [String] { [] }
    func close() async {}
    func verifyConnection() async throws {}
}
