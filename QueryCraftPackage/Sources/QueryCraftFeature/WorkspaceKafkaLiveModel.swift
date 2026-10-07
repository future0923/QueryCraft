import Foundation
import Observation

@MainActor @Observable
final class WorkspaceKafkaLiveModel {
    enum Mode { case idle, starting, running, paused, stopped, failed }
    private(set) var mode = Mode.idle
    private(set) var selection: WorkspaceDatabaseObjectSelection?
    private(set) var page: WorkspaceDatabaseDataPage?
    private(set) var received = 0
    private(set) var matched = 0
    private(set) var discarded = 0
    private(set) var error: String?
    private(set) var isRefreshing = false
    private var cursor: [Int32: Int64]?
    private var partition: Int32?
    private var filter: WorkspaceKafkaScanRequest?
    private var buffer: [(row: WorkspaceDatabaseDataRow, bytes: Int)] = []
    private var bufferBytes = 0
    private var streamID = UUID()
    private var scrollRequest = 0
    private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var makeSession: (@Sendable () async throws -> any WorkspaceSession)?
    private let maximumRows: Int
    private let maximumBytes: Int

    init(maximumRows: Int = 10_000, maximumBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumRows = max(1, maximumRows)
        self.maximumBytes = max(1, maximumBytes)
    }

    deinit { task?.cancel() }

    var isReading: Bool { mode == .starting || mode == .running }
    var firstSequence: Int { buffer.first?.row.id ?? matched }
    func isShowing(_ selection: WorkspaceDatabaseObjectSelection) -> Bool {
        self.selection == selection && mode != .idle
    }
    var dataState: WorkspaceDatabaseDataState {
        guard let page else {
            if let error { return .failed(error) }
            return isReading ? .loading : .stopped(nil)
        }
        return mode == .starting || isRefreshing ? .fetching(page) : .loaded(page)
    }

    func start(selection: WorkspaceDatabaseObjectSelection, partition: Int32?, filter: WorkspaceKafkaScanRequest?,
               previousPage: WorkspaceDatabaseDataPage?, makeSession: @escaping @Sendable () async throws -> any WorkspaceSession) {
        stop()
        self.selection = selection
        self.partition = partition
        self.filter = filter
        self.makeSession = makeSession
        cursor = nil
        buffer = []
        bufferBytes = 0
        received = 0
        matched = 0
        discarded = 0
        streamID = UUID()
        scrollRequest = 0
        page = previousPage
        launch(oneShot: false)
    }

    func pause() {
        guard mode != .idle else { return }
        invalidate()
        mode = .paused
    }

    func resume() { guard mode == .paused || mode == .failed else { return }; launch(oneShot: false) }

    func stop() {
        invalidate()
        if mode != .idle { mode = .stopped }
    }

    func leave() {
        stop()
        mode = .idle
        selection = nil
        page = nil
        buffer = []
        bufferBytes = 0
        makeSession = nil
    }

    func refresh() async {
        guard mode != .idle, !Task.isCancelled else { return }
        let continueReading = isReading
        invalidate()
        isRefreshing = true
        let id = launch(oneShot: true)
        let pending = task
        await withTaskCancellationHandler {
            await pending?.value
        } onCancel: { pending?.cancel() }
        guard generation == id else { return }
        isRefreshing = false
        // Refresh owns only a bounded fetch. Cancelling/replacing that fetch must
        // not change the user's live-reading intent; pause/stop invalidate it.
        if continueReading, error == nil { launch(oneShot: false) }
    }

    func showLatest() {
        scrollRequest += 1
        if let page { publish(columns: page.columns) }
    }

    private func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRefreshing = false
    }

    @discardableResult private func launch(oneShot: Bool) -> UUID {
        task?.cancel()
        if !oneShot { isRefreshing = false }
        let id = UUID()
        generation = id
        guard let makeSession, let selection else { return id }
        let savedCursor = cursor
        let partition = partition
        let filter = filter
        if !oneShot { mode = cursor == nil ? .starting : .running }
        error = nil
        task = Task { [weak self] in
            var openedSession: (any WorkspaceSession)?
            do {
                let session = try await makeSession()
                openedSession = session
                try Task.checkCancellation()
                guard self?.generation == id else { throw CancellationError() }
                guard let provider = session as? any WorkspaceKafkaTailing else {
                    throw WorkspaceKafkaConsumerGroupError.driverUpdateRequired
                }
                var offsets: [Int32: Int64]
                if let savedCursor { offsets = savedCursor }
                else { offsets = try await provider.tailStartingOffsets(topic: selection.objectName, partition: partition) }
                try Task.checkCancellation()
                guard self?.generation == id else { throw CancellationError() }
                self?.cursor = offsets
                repeat {
                    let batch = try await provider.pollTail(topic: selection.objectName, offsets: offsets, filter: filter)
                    try Task.checkCancellation()
                    guard self?.generation == id else { throw CancellationError() }
                    self?.accept(batch)
                    if !oneShot { self?.mode = .running }
                    offsets = batch.nextOffsets
                    if oneShot { break }
                    try await Task.sleep(for: .milliseconds(100))
                } while self != nil
                if self?.generation == id, oneShot, self?.mode == .failed {
                    self?.mode = .paused
                }
            } catch is CancellationError {
                if self?.generation == id {
                    if !oneShot { self?.mode = .paused }
                    self?.isRefreshing = false
                }
            } catch {
                if self?.generation == id {
                    self?.error = error.localizedDescription
                    self?.mode = .failed
                    self?.isRefreshing = false
                }
            }
            if let openedSession { await openedSession.close() }
        }
        return id
    }

    private func accept(_ batch: WorkspaceKafkaTailBatch) {
        received += batch.received
        cursor = batch.nextOffsets
        let firstBatch = page?.live?.id != streamID
        for row in batch.data.rows {
            let numbered = WorkspaceDatabaseDataRow(id: matched, values: row.values)
            matched += 1
            let bytes = row.values.reduce(0) { sum, value in
                switch value {
                case .text(let text): return sum + text.utf8.count
                case .null: return sum
                case .binary(let count, _): return sum + count
                }
            }
            buffer.append((numbered, bytes))
            bufferBytes += bytes
        }
        var removalCount = 0
        while buffer.count - removalCount > maximumRows || bufferBytes > maximumBytes {
            bufferBytes -= buffer[removalCount].bytes
            removalCount += 1
        }
        if removalCount > 0 { buffer.removeFirst(removalCount); discarded += removalCount }
        if firstBatch || !batch.data.rows.isEmpty { publish(columns: batch.data.columns) }
    }

    private func publish(columns: [WorkspaceDatabaseDataColumn]) {
        var result = WorkspaceDatabaseDataPage(columns: columns, rows: buffer.map(\.row),
                                               offset: 0, limit: maximumRows, hasNextPage: false)
        result.live = .init(id: streamID, firstSequence: firstSequence, scrollRequest: scrollRequest)
        page = result
    }
}
