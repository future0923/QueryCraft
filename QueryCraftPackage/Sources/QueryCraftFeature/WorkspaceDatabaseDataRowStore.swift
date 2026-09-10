import Synchronization

final public class WorkspaceDatabaseDataRowStore: Sendable {
    private struct State {
        var chunks: [[WorkspaceDatabaseDataRow]] = []
        var chunkStartIndexes: [Int] = []
        var count = 0
    }

    private let state = Mutex(State())

    convenience init(rows: [WorkspaceDatabaseDataRow]) {
        self.init()
        append(rows)
    }

    var count: Int {
        state.withLock { $0.count }
    }

    var rows: [WorkspaceDatabaseDataRow] {
        state.withLock { state in
            state.chunks.flatMap { $0 }
        }
    }

    func append(_ rows: [WorkspaceDatabaseDataRow]) {
        guard !rows.isEmpty else { return }
        state.withLock { state in
            state.chunkStartIndexes.append(state.count)
            state.chunks.append(rows)
            state.count += rows.count
        }
    }

    func row(at index: Int) -> WorkspaceDatabaseDataRow? {
        state.withLock { state in
            guard index >= 0, index < state.count else { return nil }

            var lowerBound = 0
            var upperBound = state.chunkStartIndexes.count
            while lowerBound < upperBound {
                let middle = (lowerBound + upperBound) / 2
                if state.chunkStartIndexes[middle] <= index {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }

            let chunkIndex = lowerBound - 1
            let rowIndex = index - state.chunkStartIndexes[chunkIndex]
            return state.chunks[chunkIndex][rowIndex]
        }
    }
}
