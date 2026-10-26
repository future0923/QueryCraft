import Foundation
import Testing
import SwiftUI
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor struct MobileRedisKeyActionStateTests {
    @Test func lockValidationAndConfirmationBindToExactDraft() async {
        let service = HeldKeyActionService()
        let action = MobileRedisKeyAction(mode: .create(.string), database: 3, service: service)
        action.name = "key"; action.prepare(); #expect(action.preview == nil)
        action.safetyLock.disable(); action.prepare(); #expect(action.preview != nil)
        action.name = "changed"; #expect(action.submit() == nil); #expect(action.preview == nil)
        action.name = String(repeating: "a", count: 65_537); action.prepare(); #expect(action.preview == nil); #expect(action.message?.contains("64 KiB") == true)
        action.name = " "; action.prepare(); #expect(action.preview == nil)
        action.name = "key"; action.expirationMode = .expires; action.ttl = "0"; action.prepare(); #expect(action.preview == nil)
        let rename = MobileRedisKeyAction(mode: .rename(.init(databaseIndex: 3, name: "key")), database: 3, service: service)
        rename.safetyLock.disable(); rename.name = " key "; rename.prepare(); #expect(rename.preview == nil)
        #expect(await service.writes == 0)
    }
    @Test func unknownReplyBlocksReplayUntilInspectionButDoesNotClaimSuccess() async {
        let service = HeldKeyActionService(); await service.loseReply()
        let action = MobileRedisKeyAction(mode: .rename(.init(databaseIndex: 2, name: "old")), database: 2, service: service)
        action.name = "new"; action.safetyLock.disable(); action.prepare(); await action.submit()?.value
        #expect(action.needsVerification); #expect(!action.canClose); #expect(action.submit() == nil)
        await service.failNextRead(); await action.verify()?.value
        #expect(action.needsVerification); #expect(action.statuses == nil)
        await action.verify()?.value
        #expect(action.canClose); #expect(!action.canEdit); #expect(!action.succeeded); #expect(action.verifiedDestination == nil)
        #expect(action.statuses?.count == 2); #expect(await service.writes == 1)
    }
    @Test func backgroundDuringWriteNeverCancelsOrReplays() async {
        let service = HeldKeyActionService(); await service.holdNextWrite()
        let action = MobileRedisKeyAction(mode: .create(.string), database: 1, service: service)
        action.name = "new"; action.safetyLock.disable(); action.prepare()
        let task = action.submit(); await service.waitForWrite()
        action.setBackgrounded(true); await service.releaseWrite(); await task?.value
        #expect(action.succeeded); #expect(action.needsVerification); #expect(!action.canClose); #expect(action.safetyLock.isEnabled)
        action.setBackgrounded(false); #expect(action.submit() == nil)
        await action.verify()?.value; #expect(action.canClose); #expect(action.verifiedDestination?.name == "new")
        #expect(await service.writes == 1)
    }
    @Test func staleInspectionCannotClearVerificationAfterBackground() async {
        let service = HeldKeyActionService(); await service.loseReply()
        let action = MobileRedisKeyAction(mode: .create(.string), database: 0, service: service)
        action.name = "new"; action.safetyLock.disable(); action.prepare(); await action.submit()?.value
        await service.holdNextRead(); let task = action.verify(); await service.waitForRead()
        #expect(action.isLoading); #expect(action.statuses == nil)
        action.setBackgrounded(true); await service.releaseRead(); await task?.value
        #expect(action.needsVerification); #expect(action.statuses == nil); #expect(!action.isLoading)
        action.setBackgrounded(false); await action.verify()?.value; #expect(action.canClose)
        #expect(await service.writes == 1)
    }
    @Test func removingFocusedMemberKeepsIdentityAndIgnoresLateInput() {
        let action = MobileRedisKeyAction(mode: .create(.hash), database: 0, service: HeldKeyActionService())
        action.addRow(); action.addRow()
        let first = action.rows[0], second = action.rows[1]
        let rows = Binding(get: { action.rows }, set: { action.rows = $0 })
        let firstInput = rows.identifiedRow(first), secondInput = rows.identifiedRow(second)
        firstInput.firstValue.wrappedValue = "first"
        secondInput.firstValue.wrappedValue = "second"
        action.removeRow(first.id)
        firstInput.secondValue.wrappedValue = "late keyboard callback"
        #expect(action.rows.map(\.id) == [second.id])
        secondInput.secondValue.wrappedValue = "still the same member"
        #expect(action.rows[0].firstValue == "second")
        #expect(action.rows[0].secondValue == "still the same member")
        action.removeRow(second.id)
        secondInput.firstValue.wrappedValue = "removed"
        #expect(action.rows.isEmpty)
        #expect(firstInput.wrappedValue.id == first.id)
    }
    @Test func filterRowBindingSurvivesRemovalAndReordering() {
        let first = WorkspaceDatabaseDataFilterCondition(columnName: "a", columnKind: .text, operation: .equal)
        let second = WorkspaceDatabaseDataFilterCondition(columnName: "b", columnKind: .text, operation: .equal)
        var filter = WorkspaceDatabaseDataFilter(conditions: [first, second])
        let conditions = Binding(get: { filter.conditions }, set: { filter.conditions = $0 })
        let a = conditions.identifiedRow(first), b = conditions.identifiedRow(second)
        filter.conditions.reverse()
        a.value.wrappedValue = "correct identity"
        #expect(filter.conditions[1].value == "correct identity")
        filter.conditions.removeAll { $0.id == first.id }
        a.value.wrappedValue = "late callback"
        b.value.wrappedValue = "remaining condition"
        #expect(filter.conditions.count == 1)
        #expect(filter.conditions[0].id == second.id)
        #expect(filter.conditions[0].value == "remaining condition")
    }
    @Test func sharedCreationRulesPreserveListOrderAndRejectDuplicateFields() throws {
        let rows: [RedisKeyEditableRow] = [.init(isNew: true, firstValue: "", secondValue: " first "), .init(isNew: true, firstValue: "", secondValue: "  "), .init(isNew: true, firstValue: "", secondValue: "last")]
        let plan = try RedisKeyCreationPlan.make(databaseIndex: 4, name: " key ", type: .list, rows: rows)
        #expect(plan.commands[0].arguments == ["RPUSH", "key", " first ", "last"])
        #expect(plan.optimisticRequest.assertions == [.keyType(.none)])
        #expect(throws: RedisKeyEditError.self) { try RedisKeyCreationPlan.make(databaseIndex: 0, name: "key", type: .hash, rows: [.init(isNew: true, firstValue: "a", secondValue: "1"), .init(isNew: true, firstValue: "a", secondValue: "2")]) }
        #expect(throws: RedisKeyEditError.self) { try RedisKeyCreationPlan.make(databaseIndex: 0, name: "key", type: .stream) }
    }
}

private actor HeldKeyActionService: MobileRedisKeyActing {
    private var unknown = false, failRead = false, holdWrite = false, holdRead = false
    private var writing: CheckedContinuation<Void, Never>?, reading: CheckedContinuation<Void, Never>?
    private var writeWaiters: [CheckedContinuation<Void, Never>] = [], readWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var writes = 0
    func loseReply() { unknown = true }
    func failNextRead() { failRead = true }
    func holdNextWrite() { holdWrite = true }
    func holdNextRead() { holdRead = true }
    func waitForWrite() async { if writing != nil { return }; await withCheckedContinuation { writeWaiters.append($0) } }
    func waitForRead() async { if reading != nil { return }; await withCheckedContinuation { readWaiters.append($0) } }
    func releaseWrite() { writing?.resume(); writing = nil }
    func releaseRead() { reading?.resume(); reading = nil }
    func perform(_ operation: MobileRedisKeyOperation) async throws {
        if holdWrite {
            holdWrite = false
            await withCheckedContinuation { writing = $0; for waiter in writeWaiters { waiter.resume() }; writeWaiters = [] }
        }
        writes += 1
        if unknown { throw MobileRedisMutationError.unverified("模拟回执丢失") }
    }
    func inspect(_ references: [RedisKeyReference]) async throws -> [MobileRedisKeyStatus] {
        if holdRead {
            holdRead = false
            await withCheckedContinuation { reading = $0; for waiter in readWaiters { waiter.resume() }; readWaiters = [] }
        }
        if failRead { failRead = false; throw URLError(.notConnectedToInternet) }
        return references.map { .init(reference: $0, ttl: -1) }
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil)) @MainActor struct MobileRedisKeyActionTests {
    private func fixture(_ body: (RedisClient, MobileRedisKeyActionService, String) async throws -> Void) async throws {
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:mobile-key:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect()
        do {
            try await body(client, .init(profile: profile, password: nil), key)
            for database in [0, 1] { _ = try await client.execute(["DEL", key, key + ":new"], databaseIndex: database) }
            await client.close()
        } catch {
            for database in [0, 1] { _ = try? await client.execute(["DEL", key, key + ":new"], databaseIndex: database) }
            await client.close(); throw error
        }
    }
    @Test func createAllFiveTypesWithTTLAndDatabaseIsolation() async throws {
        try await fixture { client, service, key in
            _ = try await client.execute(["SET", key, "other database"], databaseIndex: 0)
            for type in RedisKeyCreationPlan.creatableTypes {
                let action = MobileRedisKeyAction(mode: .create(type), database: 1, service: service)
                action.name = " \(key) "; action.text = ""; action.expirationMode = .expires; action.ttl = "60000"
                if type != .string { action.addRow(); action.rows[0].firstValue = "member"; action.rows[0].secondValue = type == .sortedSet ? "-2.5" : "value" }
                action.safetyLock.disable(); action.prepare(); #expect(action.preview != nil); await action.submit()?.value
                #expect(action.succeeded); #expect(action.canClose); #expect(action.verifiedDestination?.name == key)
                #expect(try await client.execute(["TYPE", key], databaseIndex: 1).stringValue == type.rawValue)
                let ttl = try await client.execute(["PTTL", key], databaseIndex: 1).integerValue ?? -1
                #expect(ttl > 0 && ttl <= 60000)
                switch type {
                case .string: #expect(try await client.execute(["GET", key], databaseIndex: 1).stringValue == "")
                case .hash: #expect(try await client.execute(["HGET", key, "member"], databaseIndex: 1).stringValue == "value")
                case .list: #expect(try await client.execute(["LINDEX", key, "0"], databaseIndex: 1).stringValue == "value")
                case .set: #expect(try await client.execute(["SISMEMBER", key, "member"], databaseIndex: 1).integerValue == 1)
                case .sortedSet: #expect(try await client.execute(["ZSCORE", key, "member"], databaseIndex: 1).stringValue == "-2.5")
                default: Issue.record("Unexpected creation type")
                }
                _ = try await client.execute(["DEL", key], databaseIndex: 1)
            }
            #expect(try await client.execute(["GET", key], databaseIndex: 0).stringValue == "other database")
        }
    }
    @Test func twoConcurrentCreatorsCannotOverwriteWinner() async throws {
        try await fixture { client, service, key in
            let a = try RedisKeyCreationPlan.make(databaseIndex: 0, name: key, type: .string, stringValue: "first")
            let b = try RedisKeyCreationPlan.make(databaseIndex: 0, name: key, type: .string, stringValue: "second")
            let results = await withTaskGroup(of: Bool.self) { group in
                for plan in [a, b] { group.addTask { do { try await service.perform(.create(plan)); return true } catch { return false } } }
                var results: [Bool] = []; for await result in group { results.append(result) }; return results
            }
            #expect(results.filter { $0 }.count == 1)
            let stored = try await client.execute(["GET", key]).stringValue
            #expect(stored == "first" || stored == "second")
            await #expect(throws: RedisWorkspaceError.self) { try await service.perform(.create(a)) }
            #expect(try await client.execute(["GET", key]).stringValue == stored)
        }
    }
    @Test func renamePreservesBinaryValueTTLAndRejectsExistingTarget() async throws {
        try await fixture { client, service, key in
            _ = try await client.executeRaw([.init(utf8: "SET"), .init(utf8: key), .init(data: Data([0,255,65]))], databaseIndex: 1)
            _ = try await client.execute(["PEXPIRE", key, "60000"], databaseIndex: 1)
            _ = try await client.execute(["SET", key + ":new", "keep"], databaseIndex: 1)
            let action = MobileRedisKeyAction(mode: .rename(.init(databaseIndex: 1, name: key)), database: 1, service: service)
            action.name = key + ":new"; action.safetyLock.disable(); action.prepare(); await action.submit()?.value
            #expect(action.canEdit); #expect(!action.needsVerification); #expect(!action.succeeded)
            #expect(try await client.execute(["GET", key + ":new"], databaseIndex: 1).stringValue == "keep")
            _ = try await client.execute(["DEL", key + ":new"], databaseIndex: 1)
            action.prepare(); await action.submit()?.value
            #expect(action.succeeded); #expect(action.statuses?.first?.exists == false)
            #expect(try await client.executeRaw([.init(utf8: "GET"), .init(utf8: key + ":new")], databaseIndex: 1).dataValue == Data([0,255,65]))
            let ttl = try await client.execute(["PTTL", key + ":new"], databaseIndex: 1).integerValue ?? -1
            #expect(ttl > 0 && ttl <= 60000)
            #expect(try await client.execute(["EXISTS", key + ":new"], databaseIndex: 0).integerValue == 0)
        }
    }
    @Test func renameStreamDoesNotRequireEditableSnapshotAndMissingSourceIsKnownFailure() async throws {
        try await fixture { client, service, key in
            let plan = try RedisKeyRenamePlan.make(reference: .init(databaseIndex: 0, name: key), proposedName: key + ":new")
            await #expect(throws: RedisClientError.self) { try await service.perform(.rename(plan)) }
            _ = try await client.execute(["XADD", key, "*", "field", "value"])
            try await service.perform(.rename(plan))
            let statuses = try await service.inspect([plan.reference, .init(databaseIndex: 0, name: plan.newName)])
            #expect(statuses[0].exists == false); #expect(statuses[1].reference.type == .stream)
            #expect(try await client.execute(["XLEN", key + ":new"]).integerValue == 1)
        }
    }
}
