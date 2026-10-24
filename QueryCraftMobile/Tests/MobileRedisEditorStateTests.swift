import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor struct MobileRedisEditorStateTests {
    @Test func initialFailureRetryAndSuccessfulMissingAreDistinct() async {
        let service = HeldRedisMutationService()
        let failing = MobileRedisEditor(key: "key", database: 0, service: service)
        await service.failNextLoad(); await failing.reload()?.value
        #expect(!failing.hasLoaded); #expect(failing.snapshot == nil); #expect(failing.message != nil)
        await service.setValue(nil); await failing.reload()?.value
        #expect(failing.hasLoaded); #expect(failing.snapshot == nil); #expect(failing.canClose)
    }
    @Test func cancelledSlowRefreshRetainsContentAndRejectsLateResponse() async {
        let service = HeldRedisMutationService()
        let model = MobileRedisEditor(key: "key", database: 0, service: service)
        await model.reload()?.value; await service.holdNextLoad()
        let task = model.reload(); await service.waitForLoad()
        #expect(model.isLoading); #expect(model.text == "old"); #expect(model.snapshot != nil)
        model.setBackgrounded(true); await service.setValue("late"); await service.releaseLoad(); await task?.value
        model.setBackgrounded(false)
        #expect(model.text == "old"); #expect(!model.isLoading)
        // First-load cancellation has a reachable retry after foregrounding.
        let editor = MobileRedisEditor(key: "key", database: 0, service: service)
        editor.setBackgrounded(true); #expect(editor.reload() == nil)
        editor.setBackgrounded(false); await editor.reload()?.value
        #expect(editor.hasLoaded)
    }
    @Test func backgroundDuringExecWaitsForOutcomeAndRequiresVerification() async {
        let service = HeldRedisMutationService()
        let model = MobileRedisEditor(key: "key", database: 0, service: service)
        await model.reload()?.value; model.safetyLock.disable(); model.text = "new"; model.prepare()
        await service.holdNextApply()
        let task = model.submit(); await service.waitForApply()
        #expect(model.isSubmitting); #expect(!model.canClose)
        model.setBackgrounded(true); await service.releaseApply(); await task?.value
        #expect(model.needsVerification); #expect(!model.canClose); #expect(model.text == "new")
        #expect(model.safetyLock.isEnabled); #expect(await service.writes == 1)
        model.setBackgrounded(false); #expect(model.needsVerification); #expect(model.submit() == nil)
        await model.reload(discard: true)?.value
        #expect(!model.needsVerification); #expect(!model.hasChanges); #expect(model.text == "new")
        #expect(await service.writes == 1)
    }
}

private actor HeldRedisMutationService: MobileRedisMutating {
    private var value: String? = "old"
    private var failLoad = false, holdLoad = false, holdApply = false
    private var loading: CheckedContinuation<Void, Never>?, applying: CheckedContinuation<Void, Never>?
    private var loadWaiters: [CheckedContinuation<Void, Never>] = [], applyWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var writes = 0
    func setValue(_ value: String?) { self.value = value }
    func failNextLoad() { failLoad = true }
    func holdNextLoad() { holdLoad = true }
    func holdNextApply() { holdApply = true }
    func waitForLoad() async { if loading != nil { return }; await withCheckedContinuation { loadWaiters.append($0) } }
    func waitForApply() async { if applying != nil { return }; await withCheckedContinuation { applyWaiters.append($0) } }
    func releaseLoad() { loading?.resume(); loading = nil }
    func releaseApply() { applying?.resume(); applying = nil }
    func load(key: String, database: Int) async throws -> MobileRedisSnapshot? {
        if failLoad { failLoad = false; throw URLError(.notConnectedToInternet) }
        if holdLoad {
            holdLoad = false
            await withCheckedContinuation { loading = $0; for waiter in loadWaiters { waiter.resume() }; loadWaiters = [] }
        }
        guard let value else { return nil }
        return .init(details: .init(reference: .init(databaseIndex: database, name: key, type: .string), ttlMilliseconds: nil, memoryUsageBytes: nil, encoding: nil, value: .init(columns: [], rows: [], isTruncated: false)), stringData: .init(utf8: value), rows: [], count: value.utf8.count)
    }
    func apply(_ request: RedisOptimisticMutationRequest) async throws {
        if holdApply {
            holdApply = false
            await withCheckedContinuation { applying = $0; for waiter in applyWaiters { waiter.resume() }; applyWaiters = [] }
        }
        writes += 1
        if case .command(let command) = request.operations.first { value = command.arguments[2].losslessUTF8String }
    }
}
