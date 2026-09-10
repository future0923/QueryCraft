import Foundation
import GRDB

actor WorkspaceQueryResultDataExportRowSource:
    WorkspaceDataExportRowSource
{
    private static let rangeBatchSize = 5_000
    private static let sparseBatchSize = 900

    private let store: WorkspaceQueryResultStore
    private let databaseURL: URL
    private let rows: WorkspaceGridCopyRows
    private var nextRowIndex: Int?
    private var databaseQueue: DatabaseQueue?

    init(
        store: WorkspaceQueryResultStore,
        databaseURL: URL,
        rows: WorkspaceGridCopyRows
    ) {
        self.store = store
        self.databaseURL = databaseURL
        self.rows = rows
        nextRowIndex = rows.first
    }

    func nextBatch() async throws -> [WorkspaceDatabaseDataRow]? {
        try Task.checkCancellation()
        guard let positions = nextPositions(), !positions.isEmpty else {
            return nil
        }
        let databaseQueue = try reader()
        let payloads = try await databaseQueue.read { database in
            switch rows {
            case .range:
                try Data.fetchAll(
                    database,
                    sql: """
                    SELECT payload
                    FROM queryResultRow
                    WHERE position >= ? AND position <= ?
                    ORDER BY position
                    """,
                    arguments: [positions[0], positions[positions.count - 1]]
                )
            case .indexes:
                try Data.fetchAll(
                    database,
                    sql: """
                    SELECT payload
                    FROM queryResultRow
                    WHERE position IN (
                        \(Array(repeating: "?", count: positions.count).joined(separator: ","))
                    )
                    ORDER BY position
                    """,
                    arguments: StatementArguments(positions)
                )
            }
        }
        try Task.checkCancellation()
        guard payloads.count == positions.count else {
            throw WorkspaceDataExportError.missingRow
        }
        let decoder = JSONDecoder()
        return try payloads.map {
            try decoder.decode(
                WorkspaceDatabaseDataRow.self,
                from: $0
            )
        }
    }

    func finish() {
        nextRowIndex = nil
        guard let databaseQueue else { return }
        self.databaseQueue = nil
        try? databaseQueue.close()
    }

    private func nextPositions() -> [Int]? {
        guard var rowIndex = nextRowIndex else { return nil }
        let batchSize: Int = switch rows {
        case .range:
            Self.rangeBatchSize
        case .indexes:
            Self.sparseBatchSize
        }
        var positions: [Int] = []
        positions.reserveCapacity(min(batchSize, rows.count))
        while positions.count < batchSize {
            positions.append(rowIndex)
            guard let followingIndex = followingIndex(after: rowIndex) else {
                nextRowIndex = nil
                return positions
            }
            rowIndex = followingIndex
        }
        nextRowIndex = rowIndex
        return positions
    }

    private func followingIndex(after index: Int) -> Int? {
        switch rows {
        case let .range(range):
            guard index < range.upperBound else { return nil }
            return index + 1
        case let .indexes(indexes):
            return indexes.integerGreaterThan(index)
        }
    }

    private func reader() throws -> DatabaseQueue {
        if let databaseQueue {
            return databaseQueue
        }
        var configuration = Configuration()
        configuration.readonly = true
        let databaseQueue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: configuration
        )
        self.databaseQueue = databaseQueue
        return databaseQueue
    }
}
