import Testing

@testable import QueryCraftFeature

struct WorkspaceSessionOperationGateTests {
    @Test
    func serializesOperationsAcrossSuspensionPoints() async throws {
        let gate = WorkspaceSessionOperationGate()
        let probe = SessionOperationProbe()

        let first = Task {
            try await gate.run {
                await probe.enter(1)
                await probe.waitForRelease()
                await probe.leave(1)
                return 1
            }
        }
        await probe.waitUntilFirstOperationEnters()

        let second = Task {
            try await gate.run {
                await probe.enter(2)
                await probe.leave(2)
                return 2
            }
        }
        let third = Task {
            try await gate.run {
                await probe.enter(3)
                await probe.leave(3)
                return 3
            }
        }

        for _ in 0..<8 {
            await Task.yield()
        }
        #expect(await probe.enteredOperations() == [1])

        await probe.releaseFirstOperation()
        let values = try await [first.value, second.value, third.value]

        #expect(values == [1, 2, 3])
        #expect(await probe.maximumConcurrentOperations() == 1)
        #expect(Set(await probe.enteredOperations()) == [1, 2, 3])
    }

    @Test
    func uncancelledOperationStillWaitsForActiveWork() async throws {
        let gate = WorkspaceSessionOperationGate()
        let probe = SessionOperationProbe()

        let activeWork = Task {
            try await gate.run {
                await probe.enter(1)
                await probe.waitForRelease()
                await probe.leave(1)
            }
        }
        await probe.waitUntilFirstOperationEnters()

        let close = Task {
            await gate.runUncancelled {
                await probe.enter(2)
                await probe.leave(2)
            }
        }
        close.cancel()
        for _ in 0..<8 {
            await Task.yield()
        }
        #expect(await probe.enteredOperations() == [1])

        await probe.releaseFirstOperation()
        try await activeWork.value
        await close.value

        #expect(await probe.enteredOperations() == [1, 2])
        #expect(await probe.maximumConcurrentOperations() == 1)
    }
}

private actor SessionOperationProbe {
    private var activeOperationCount = 0
    private var maximumActiveOperationCount = 0
    private var enteredOperationIDs: [Int] = []
    private var firstOperationContinuation: CheckedContinuation<Void, Never>?
    private var firstOperationEntered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func enter(_ id: Int) {
        activeOperationCount += 1
        maximumActiveOperationCount = max(
            maximumActiveOperationCount,
            activeOperationCount
        )
        enteredOperationIDs.append(id)
        if id == 1 {
            firstOperationEntered = true
            firstOperationContinuation?.resume()
            firstOperationContinuation = nil
        }
    }

    func leave(_ id: Int) {
        activeOperationCount -= 1
    }

    func waitUntilFirstOperationEnters() async {
        guard !firstOperationEntered else { return }
        await withCheckedContinuation { continuation in
            firstOperationContinuation = continuation
        }
    }

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func releaseFirstOperation() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func maximumConcurrentOperations() -> Int {
        maximumActiveOperationCount
    }

    func enteredOperations() -> [Int] {
        enteredOperationIDs
    }
}
