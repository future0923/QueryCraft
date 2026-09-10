import Foundation
import GRDB
import Synchronization

final class WorkspaceQueryResultStore: Sendable {
    private struct Cache: Sendable {
        var pages: [Int: [WorkspaceDatabaseDataRow]] = [:]
        var order: [Int] = []
    }

    private static let pageSize = 256
    private static let maximumCachedPages = 16
    private static let maximumResidentRowCount = 50_000

    let id = UUID()

    private let diskCoordinator: WorkspaceQueryResultStoreDiskCoordinator
    private let diskBacking = Mutex<WorkspaceQueryResultStoreDiskBacking?>(nil)
    private let cache = Mutex(Cache())
    private let residentRows: Mutex<[WorkspaceDatabaseDataRow]?>
    private let storedRowCount = Mutex(0)

    var rowCount: Int {
        storedRowCount.withLock { $0 }
    }

    var isDiskBacked: Bool {
        diskBacking.withLock { $0 != nil }
    }

    init(temporary: Bool = true) throws {
        var initialResidentRows: [WorkspaceDatabaseDataRow] = []
        initialResidentRows.reserveCapacity(Self.maximumResidentRowCount)
        residentRows = Mutex(initialResidentRows)
        diskCoordinator = WorkspaceQueryResultStoreDiskCoordinator(
            temporary: temporary
        )
    }

    static func makeTemporary() async throws -> WorkspaceQueryResultStore {
        try await WorkspaceQueryResultStoreFactory.shared.makeTemporary()
    }

    deinit {
        guard let diskBacking = diskBacking.withLock({ $0 }) else { return }
        Task {
            await WorkspaceQueryResultStoreCleanup.shared.remove(
                databaseQueue: diskBacking.databaseQueue,
                fileURL: diskBacking.fileURL
            )
        }
    }

    func append(_ rows: [WorkspaceDatabaseDataRow]) async throws {
        guard !rows.isEmpty else { return }
        let appendedInMemory = residentRows.withLock { residentRows in
            guard residentRows != nil else { return false }
            guard
                residentRows!.count + rows.count
                    <= Self.maximumResidentRowCount
            else {
                return false
            }
            residentRows!.append(contentsOf: rows)
            return true
        }
        if appendedInMemory {
            storedRowCount.withLock { $0 += rows.count }
            return
        }

        if let rowsToSpill = residentRows.withLock({ $0 }) {
            try await persist([rowsToSpill, rows])
            residentRows.withLock { $0 = nil }
        } else {
            try await persist([rows])
        }
        cache(rows)
        storedRowCount.withLock { $0 += rows.count }
    }

    func row(at index: Int) -> WorkspaceDatabaseDataRow? {
        guard index >= 0, index < rowCount else { return nil }
        let residentLookup = residentRows.withLock { rows in
            (
                isResident: rows != nil,
                row: rows.flatMap {
                    $0.indices.contains(index) ? $0[index] : nil
                }
            )
        }
        if residentLookup.isResident {
            return residentLookup.row
        }
        let pageIndex = index / Self.pageSize
        if let row = cachedRow(at: index, pageIndex: pageIndex) {
            return row
        }

        let rows: [WorkspaceDatabaseDataRow]
        guard let databaseQueue = databaseQueue() else { return nil }
        do {
            rows = try databaseQueue.read { database in
                try Self.readPage(pageIndex, from: database)
            }
        } catch {
            return nil
        }

        storeCachedPage(rows, at: pageIndex)
        return rows.first { $0.id == index }
    }

    func cachedRow(at index: Int) -> WorkspaceDatabaseDataRow? {
        guard index >= 0, index < rowCount else { return nil }
        let residentLookup = residentRows.withLock { rows in
            (
                isResident: rows != nil,
                row: rows.flatMap {
                    $0.indices.contains(index) ? $0[index] : nil
                }
            )
        }
        if residentLookup.isResident {
            return residentLookup.row
        }
        return cachedRow(at: index, pageIndex: index / Self.pageSize)
    }

    func makeDataExportRowSource(
        rows: WorkspaceGridCopyRows
    ) -> any WorkspaceDataExportRowSource {
        let isResident = residentRows.withLock { $0 != nil }
        let diskBacking = diskBacking.withLock { $0 }
        guard
            !isResident,
            let diskBacking,
            let fileURL = diskBacking.fileURL
        else {
            return WorkspaceSnapshotDataExportRowSource(
                rows: rows,
                rowAt: { [self] in row(at: $0) }
            )
        }
        return WorkspaceQueryResultDataExportRowSource(
            store: self,
            databaseURL: fileURL,
            rows: rows
        )
    }

    func loadPage(containing index: Int) async throws -> Range<Int>? {
        guard index >= 0, index < rowCount else { return nil }
        if residentRows.withLock({ $0 != nil }) {
            return 0..<rowCount
        }
        let pageIndex = index / Self.pageSize
        let start = pageIndex * Self.pageSize
        if cachedRow(at: index, pageIndex: pageIndex) != nil {
            return start..<min(start + Self.pageSize, rowCount)
        }

        guard let databaseQueue = databaseQueue() else { return nil }
        let rows = try await databaseQueue.read { database in
            try Self.readPage(pageIndex, from: database)
        }
        try Task.checkCancellation()
        storeCachedPage(rows, at: pageIndex)
        return start..<min(start + rows.count, rowCount)
    }

    func apply(
        _ mutations: [WorkspaceQueryResultCellMutation]
    ) async throws {
        guard !mutations.isEmpty else { return }
        let grouped = Dictionary(grouping: mutations, by: \.rowIndex)
        var replacements: [WorkspaceDatabaseDataRow] = []
        replacements.reserveCapacity(grouped.count)
        for (rowIndex, rowMutations) in grouped {
            try Task.checkCancellation()
            guard let row = row(at: rowIndex) else { continue }
            var values = row.values
            for mutation in rowMutations
            where values.indices.contains(mutation.dataColumnIndex) {
                values[mutation.dataColumnIndex] = mutation.value
            }
            replacements.append(
                WorkspaceDatabaseDataRow(id: row.id, values: values)
            )
        }
        guard !replacements.isEmpty else { return }
        let persistedReplacements = replacements

        let replacedResidentRows = residentRows.withLock { rows in
            guard var resident = rows else { return false }
            for replacement in persistedReplacements
            where resident.indices.contains(replacement.id) {
                resident[replacement.id] = replacement
            }
            rows = resident
            return true
        }
        if !replacedResidentRows, let databaseQueue = databaseQueue() {
            try await databaseQueue.write { database in
                let encoder = JSONEncoder()
                let statement = try database.makeStatement(
                    sql: "UPDATE queryResultRow SET payload = ? WHERE position = ?"
                )
                for replacement in persistedReplacements {
                    try statement.execute(
                        arguments: [
                            try encoder.encode(replacement),
                            replacement.id,
                        ]
                    )
                }
            }
            cache(persistedReplacements)
        }
    }

    func cachePageIdentifier(containing index: Int) -> Int? {
        guard index >= 0, index < rowCount else { return nil }
        return index / Self.pageSize
    }

    private func cachedRow(at index: Int, pageIndex: Int)
        -> WorkspaceDatabaseDataRow?
    {
        cache.withLock { cache in
            guard let rows = cache.pages[pageIndex] else { return nil }
            cache.order.removeAll { $0 == pageIndex }
            cache.order.append(pageIndex)
            return rows.first { $0.id == index }
        }
    }

    private func cache(_ rows: [WorkspaceDatabaseDataRow]) {
        let rowsByPage = Dictionary(grouping: rows) {
            $0.id / Self.pageSize
        }
        cache.withLock { cache in
            for (pageIndex, newRows) in rowsByPage {
                var rowsByID = Dictionary(
                    uniqueKeysWithValues:
                        (cache.pages[pageIndex] ?? []).map { ($0.id, $0) }
                )
                for row in newRows {
                    rowsByID[row.id] = row
                }
                cache.pages[pageIndex] = rowsByID.values.sorted {
                    $0.id < $1.id
                }
                Self.markRecentlyUsed(pageIndex, in: &cache)
            }
            Self.evictPagesIfNeeded(from: &cache)
        }
    }

    private func storeCachedPage(
        _ rows: [WorkspaceDatabaseDataRow],
        at pageIndex: Int
    ) {
        cache.withLock { cache in
            cache.pages[pageIndex] = rows
            Self.markRecentlyUsed(pageIndex, in: &cache)
            Self.evictPagesIfNeeded(from: &cache)
        }
    }

    private static func markRecentlyUsed(
        _ pageIndex: Int,
        in cache: inout Cache
    ) {
        cache.order.removeAll { $0 == pageIndex }
        cache.order.append(pageIndex)
    }

    private static func evictPagesIfNeeded(from cache: inout Cache) {
        while cache.order.count > maximumCachedPages {
            let removed = cache.order.removeFirst()
            cache.pages[removed] = nil
        }
    }

    private static func readPage(
        _ pageIndex: Int,
        from database: Database
    ) throws -> [WorkspaceDatabaseDataRow] {
        let start = pageIndex * pageSize
        let payloads = try Data.fetchAll(
            database,
            sql: """
            SELECT payload
            FROM queryResultRow
            WHERE position >= ? AND position < ?
            ORDER BY position
            """,
            arguments: [start, start + pageSize]
        )
        let decoder = JSONDecoder()
        return try payloads.map {
            try decoder.decode(
                WorkspaceDatabaseDataRow.self,
                from: $0
            )
        }
    }

    private func persist(
        _ batches: [[WorkspaceDatabaseDataRow]]
    ) async throws {
        let diskBacking = try await diskCoordinator.backing()
        self.diskBacking.withLock { backing in
            if backing == nil {
                backing = diskBacking
            }
        }
        try await diskBacking.databaseQueue.write { database in
            let encoder = JSONEncoder()
            let statement = try database.makeStatement(
                sql: "INSERT INTO queryResultRow (position, payload) VALUES (?, ?)"
            )
            for rows in batches {
                for row in rows {
                    try statement.execute(
                        arguments: [row.id, try encoder.encode(row)]
                    )
                }
            }
        }
    }

    private func databaseQueue() -> DatabaseQueue? {
        diskBacking.withLock { $0?.databaseQueue }
    }
}

struct WorkspaceQueryResultCellMutation: Equatable, Sendable {
    let rowIndex: Int
    let dataColumnIndex: Int
    let value: WorkspaceDatabaseDataCell
}

private struct WorkspaceQueryResultStoreDiskBacking: Sendable {
    let databaseQueue: DatabaseQueue
    let fileURL: URL?

    static func make(temporary: Bool) throws -> Self {
        let databaseQueue: DatabaseQueue
        let fileURL: URL?

        if temporary {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "QueryCraft", directoryHint: .isDirectory)
                .appending(path: "Results", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let temporaryURL = directory
                .appending(path: UUID().uuidString)
                .appendingPathExtension("sqlite")
            var configuration = Configuration()
            configuration.journalMode = .wal
            databaseQueue = try DatabaseQueue(
                path: temporaryURL.path,
                configuration: configuration
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            fileURL = temporaryURL
        } else {
            databaseQueue = try DatabaseQueue()
            fileURL = nil
        }

        try databaseQueue.writeWithoutTransaction { database in
            try database.create(table: "queryResultRow") { table in
                table.primaryKey("position", .integer)
                table.column("payload", .blob).notNull()
            }
        }
        return Self(databaseQueue: databaseQueue, fileURL: fileURL)
    }
}

private actor WorkspaceQueryResultStoreDiskCoordinator {
    private let temporary: Bool
    private var cachedBacking: WorkspaceQueryResultStoreDiskBacking?

    init(temporary: Bool) {
        self.temporary = temporary
    }

    func backing() throws -> WorkspaceQueryResultStoreDiskBacking {
        if let cachedBacking {
            return cachedBacking
        }
        let backing = try WorkspaceQueryResultStoreDiskBacking.make(
            temporary: temporary
        )
        cachedBacking = backing
        return backing
    }
}

private actor WorkspaceQueryResultStoreFactory {
    static let shared = WorkspaceQueryResultStoreFactory()

    func makeTemporary() throws -> WorkspaceQueryResultStore {
        try WorkspaceQueryResultStore()
    }
}

private actor WorkspaceQueryResultStoreCleanup {
    static let shared = WorkspaceQueryResultStoreCleanup()

    func remove(
        databaseQueue: DatabaseQueue,
        fileURL: URL?
    ) {
        try? databaseQueue.close()
        guard let fileURL else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                atPath: fileURL.path + suffix
            )
        }
    }
}
