import AppKit
import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor @Suite("Kafka live reading", .timeLimit(.minutes(1)))
struct WorkspaceKafkaLiveTests {
    private let selection = WorkspaceDatabaseObjectSelection(databaseName: "Kafka", objectName: "events", kind: .table)
    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw LiveTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func batch(_ values: [String], next: Int64, received: Int? = nil) -> WorkspaceKafkaTailBatch {
        .init(data: .init(columns: [.init(id: 0, name: "value")], rows: values.enumerated().map {
            .init(id: $0.offset, values: [.text($0.element)])
        }), received: received ?? values.count, nextOffsets: [0: next])
    }

    @Test("Live starts at end, counts received/filtered rows and bounds its retained window")
    func boundedWindow() async throws {
        let session = LiveTestSession()
        let model = WorkspaceKafkaLiveModel(maximumRows: 3)
        defer { model.leave() }
        let filter = WorkspaceKafkaScanRequest(text: "value")
        model.start(selection: selection, partition: 0, filter: filter, previousPage: nil) { session }
        await session.send(.success(batch(["a", "b", "c", "d", "e"], next: 17, received: 7)))
        try await waitFor { model.mode == .running }
        #expect(await session.positions.first == [0: 10])
        #expect(await session.filters.first == filter)
        #expect(model.received == 7 && model.matched == 5 && model.discarded == 2)
        #expect(model.page?.rows.map(\.id) == [2, 3, 4])
        #expect(model.page?.rows.map { $0.values[0] } == [.text("c"), .text("d"), .text("e")])
        #expect(model.page?.live?.firstSequence == 2)
        model.pause()
        try await waitFor { await session.closed }
    }

    @Test("The byte limit also bounds large messages and can evict an oversized single row")
    func byteBudget() async throws {
        let session = LiveTestSession()
        let model = WorkspaceKafkaLiveModel(maximumBytes: 6)
        defer { model.leave() }
        model.start(selection: selection, partition: nil, filter: nil, previousPage: nil) { session }
        await session.send(.success(batch(["aa", "bb", "cccc"], next: 13)))
        try await waitFor { model.matched == 3 }
        #expect(model.page?.rows.map { $0.values[0] } == [.text("bb"), .text("cccc")])
        await session.send(.success(batch(["oversized"], next: 14)))
        try await waitFor { model.matched == 4 }
        #expect(model.page?.rowCount == 0)
        #expect(model.discarded == 4)
    }

    @Test("Pause closes the reader; resume keeps its cursor and existing results")
    func pauseResume() async throws {
        let first = LiveTestSession(), second = LiveTestSession()
        let factory = LiveTestFactory([first, second])
        let model = WorkspaceKafkaLiveModel()
        defer { model.leave() }
        model.start(selection: selection, partition: nil, filter: nil, previousPage: nil) { await factory.next() }
        await first.send(.success(batch(["first"], next: 11)))
        try await waitFor { model.received == 1 }
        model.pause()
        try await waitFor { await first.closed }
        #expect(model.mode == .paused && model.page?.rowCount == 1)
        model.resume()
        await second.send(.success(batch(["second"], next: 12)))
        try await waitFor { model.received == 2 }
        #expect(await second.starts == 0)
        #expect(await second.positions.first == [0: 11])
        #expect(model.page?.rows.map(\.id) == [0, 1])
        model.stop()
        try await waitFor { await second.closed }
        #expect(model.mode == .stopped)
    }

    @Test("Disconnect reports an error while preserving rows; paused refresh reads once from the same cursor")
    func failedReadAndRefresh() async throws {
        let first = LiveTestSession(), second = LiveTestSession()
        let factory = LiveTestFactory([first, second])
        let model = WorkspaceKafkaLiveModel()
        defer { model.leave() }
        model.start(selection: selection, partition: nil, filter: nil, previousPage: nil) { await factory.next() }
        await first.send(.success(batch(["first"], next: 11)))
        try await waitFor { model.received == 1 }
        await first.send(.failure(.disconnected))
        try await waitFor { model.mode == .failed }
        #expect(model.page?.rowCount == 1 && model.error != nil)
        await second.send(.success(batch(["second"], next: 12)))
        await model.refresh()
        #expect(model.mode == .paused && !model.isRefreshing && model.error == nil)
        #expect(model.received == 2 && model.page?.rowCount == 2)
        #expect(await second.positions == [[0: 11]])
        #expect(await second.closed)
    }

    @Test("Idle polls preserve the page revision and stopping rejects later messages")
    func idleAndStop() async throws {
        let session = LiveTestSession()
        let model = WorkspaceKafkaLiveModel()
        model.start(selection: selection, partition: nil, filter: nil, previousPage: nil) { session }
        await session.send(.success(batch([], next: 10)))
        try await waitFor { model.mode == .running }
        let revision = model.page?.revision
        await session.send(.success(batch([], next: 10)))
        try await waitFor { await session.positions.count >= 2 }
        #expect(model.page?.revision == revision)
        model.stop()
        await session.send(.success(batch(["too late"], next: 11)))
        try await waitFor { await session.closed }
        #expect(model.page?.rowCount == 0 && model.received == 0)
        model.leave()
    }

    @Test("Refresh preserves live controls while polling and closing the reader",
          arguments: [WorkspaceKafkaLiveModel.Mode.running, .paused, .stopped])
    func refreshPreservesMode(_ mode: WorkspaceKafkaLiveModel.Mode) async throws {
        let first = LiveTestSession(), refreshSession = LiveTestSession(blocksClose: true)
        let resumed = LiveTestSession()
        let factory = LiveTestFactory([first, refreshSession, resumed])
        let model = WorkspaceKafkaLiveModel()
        defer { model.leave() }
        model.start(selection: selection, partition: nil, filter: nil, previousPage: nil) { await factory.next() }
        await first.send(.success(batch(["first"], next: 11)))
        try await waitFor { model.received == 1 }
        if mode == .paused { model.pause() }
        if mode == .stopped { model.stop() }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel() }
        try await waitFor { await refreshSession.positions.count == 1 }
        #expect(model.mode == mode && model.isRefreshing)
        #expect(model.isReading == (mode == .running))
        await refreshSession.send(.success(batch(["refreshed"], next: 12)))
        try await waitFor { await refreshSession.closeStarted }
        #expect(model.mode == mode && model.isRefreshing)
        #expect(model.page?.rowCount == 2)
        await refreshSession.releaseClose()
        await refresh.value
        #expect(model.mode == mode && !model.isRefreshing)
        if mode == .running {
            await resumed.send(.success(batch(["still live"], next: 13)))
            try await waitFor { model.received == 3 }
            #expect(await resumed.positions.first == [0: 12])
        }
    }

    @Test("A newer refresh during reader cleanup preserves continuous reading")
    func overlappingRefresh() async throws {
        let first = LiveTestSession(), slow = LiveTestSession(blocksClose: true)
        let second = LiveTestSession(), resumed = LiveTestSession()
        let factory = LiveTestFactory([first, slow, second, resumed])
        let model = WorkspaceKafkaLiveModel()
        defer { model.leave() }
        model.start(selection: selection, partition: nil, filter: nil, previousPage: nil) { await factory.next() }
        await first.send(.success(batch(["first"], next: 11)))
        try await waitFor { model.received == 1 }
        let oldRefresh = Task { await model.refresh() }
        defer { oldRefresh.cancel() }
        await slow.send(.success(batch(["second"], next: 12)))
        try await waitFor { await slow.closeStarted }
        await second.send(.success(batch(["third"], next: 13)))
        await model.refresh()
        await slow.releaseClose()
        await oldRefresh.value
        await resumed.send(.success(batch(["fourth"], next: 14)))
        try await waitFor { model.received == 4 }
        #expect(model.mode == .running && !model.isRefreshing)
        #expect(await second.positions == [[0: 12]])
        #expect(await resumed.positions.first == [0: 13])
    }

    @Test("Explicit pause or stop during refresh wins over refresh completion", arguments: [false, true])
    func interruptRefresh(stop: Bool) async throws {
        let first = LiveTestSession(), second = LiveTestSession(blocksClose: true)
        let factory = LiveTestFactory([first, second])
        let model = WorkspaceKafkaLiveModel()
        defer { model.leave() }
        model.start(selection: selection, partition: nil, filter: nil, previousPage: nil) { await factory.next() }
        await first.send(.success(batch(["first"], next: 11)))
        try await waitFor { model.received == 1 }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel() }
        await second.send(.success(batch(["second"], next: 12)))
        try await waitFor { await second.closeStarted }
        if stop { model.stop() } else { model.pause() }
        await second.releaseClose()
        await refresh.value
        #expect(model.mode == (stop ? .stopped : .paused))
        #expect(!model.isReading && !model.isRefreshing)
    }

    @Test("Cancelling a toolbar refresh does not pause an independent live reader")
    func cancelledRefresh() async throws {
        let first = LiveTestSession(), second = LiveTestSession(), resumed = LiveTestSession()
        let factory = LiveTestFactory([first, second, resumed])
        let model = WorkspaceKafkaLiveModel()
        defer { model.leave() }
        model.start(selection: selection, partition: nil, filter: nil, previousPage: nil) { await factory.next() }
        await first.send(.success(batch(["first"], next: 11)))
        try await waitFor { model.received == 1 }
        let refresh = Task { await model.refresh() }
        try await waitFor { await second.positions.count == 1 }
        refresh.cancel()
        await refresh.value
        await resumed.send(.success(batch(["still live"], next: 12)))
        try await waitFor { model.received == 2 }
        #expect(model.mode == .running && !model.isRefreshing)
        #expect(await resumed.positions.first == [0: 11])
        #expect(await second.closed)
    }

    @Test("Live table preserves an older viewport when rows append or expire; Latest jumps to end")
    func tableScroll() throws {
        let streamID = UUID()
        func page(_ start: Int, _ end: Int, scroll: Int = 0) -> WorkspaceDatabaseDataPage {
            var page = WorkspaceDatabaseDataPage(columns: [.init(id: 0, name: "value")],
                rows: (start..<end).map { .init(id: $0, values: [.text(String($0))]) },
                offset: 0, limit: 10_000, hasNextPage: false)
            page.live = .init(id: streamID, firstSequence: start, scrollRequest: scroll)
            return page
        }
        let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page(0, 200), isFetching: false, sortData: { _ in })
        let scroll = coordinator.makeScrollView()
        scroll.frame = .init(x: 0, y: 0, width: 600, height: 260)
        scroll.layoutSubtreeIfNeeded()
        let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
        table.reloadData()
        table.scrollRowToVisible(80)
        let originalY = table.visibleRect.minY
        #expect(originalY > 0)
        coordinator.update(page: page(0, 210), isFetching: false, sortData: { _ in })
        #expect(abs(table.visibleRect.minY - originalY) < 1)
        let rowHeight = table.rowHeight + table.intercellSpacing.height
        coordinator.update(page: page(10, 210), isFetching: false, sortData: { _ in })
        #expect(abs(table.visibleRect.minY - (originalY - rowHeight * 10)) < 1)
        coordinator.update(page: page(10, 210, scroll: 1), isFetching: false, sortData: { _ in })
        #expect(table.visibleRect.maxY >= table.rect(ofRow: 199).maxY - 1)
    }
}

private enum LiveTestError: Error { case disconnected, timeout }

private actor LiveTestFactory {
    var sessions: [LiveTestSession]
    init(_ sessions: [LiveTestSession]) { self.sessions = sessions }
    func next() -> LiveTestSession { sessions.removeFirst() }
}

private actor LiveTestSession: WorkspaceSession, WorkspaceKafkaTailing {
    let batches = AsyncStream<Result<WorkspaceKafkaTailBatch, LiveTestError>>.makeStream()
    let closeGate = AsyncStream<Void>.makeStream()
    let blocksClose: Bool
    var closeStarted = false
    init(blocksClose: Bool = false) { self.blocksClose = blocksClose }
    func releaseClose() { closeGate.continuation.finish() }
    var positions: [[Int32: Int64]] = []
    var filters: [WorkspaceKafkaScanRequest?] = []
    var starts = 0
    var closed = false
    func send(_ batch: Result<WorkspaceKafkaTailBatch, LiveTestError>) { batches.continuation.yield(batch) }
    func tailStartingOffsets(topic: String, partition: Int32?) async throws -> [Int32: Int64] { starts += 1; return [0: 10] }
    func pollTail(topic: String, offsets: [Int32: Int64], filter: WorkspaceKafkaScanRequest?) async throws -> WorkspaceKafkaTailBatch {
        positions.append(offsets)
        filters.append(filter)
        var iterator = batches.stream.makeAsyncIterator()
        guard let result = await iterator.next() else { throw CancellationError() }
        return try result.get()
    }
    func connect() async throws {}
    func isConnected() async -> Bool { !closed }
    func close() async {
        closeStarted = true
        if blocksClose {
            var iterator = closeGate.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        closed = true
        batches.continuation.finish()
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { .init(columns: [], ddl: "") }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int,
        sort: WorkspaceDatabaseDataSort, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult { .init(columns: [], hasNextPage: false) }
}
