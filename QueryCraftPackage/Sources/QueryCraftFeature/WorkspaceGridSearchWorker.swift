import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

/// Immutable typed snapshots let all platforms use the same matching/state path.
protocol WorkspaceGridSearchDataSource: Sendable {
    var revision: UUID { get }
    var columns: [WorkspaceDatabaseDataColumn] { get }
    var rowCount: Int { get }
    func row(at index: Int) -> WorkspaceDatabaseDataRow?
}

struct WorkspaceGridSearchRequest: Sendable {
    let query: String
    let dataColumnIndex: Int?
    let searchOperator: WorkspaceGridSearchOperator
    let isCaseSensitive: Bool
}

struct WorkspaceGridSearchResult: Equatable, Sendable {
    let matches: [WorkspaceGridSearchMatch]
    let hasAdditionalMatches: Bool
}

actor WorkspaceGridSearchWorker {
    static let maximumMatchCount = 10_000
    private static let cancellationCheckInterval = 128

    func search(
        source: any WorkspaceGridSearchDataSource,
        request: WorkspaceGridSearchRequest
    ) async throws -> WorkspaceGridSearchResult {
        guard !request.query.isEmpty else {
            return WorkspaceGridSearchResult(
                matches: [],
                hasAdditionalMatches: false
            )
        }

        let columnIndexes: [Int]
        if let selectedColumn = request.dataColumnIndex,
           source.columns.indices.contains(selectedColumn)
        {
            columnIndexes = [selectedColumn]
        } else {
            columnIndexes = Array(source.columns.indices)
        }

        var matches: [WorkspaceGridSearchMatch] = []
        matches.reserveCapacity(min(source.rowCount, 512))

        for rowIndex in 0..<source.rowCount {
            if rowIndex.isMultiple(
                of: Self.cancellationCheckInterval
            ) {
                try Task.checkCancellation()
                await Task.yield()
            }
            guard let row = source.row(at: rowIndex) else { continue }

            for dataColumnIndex in columnIndexes {
                let text = searchableText(
                    for: row.value(at: dataColumnIndex)
                )
                guard doesMatch(
                    text,
                    query: request.query,
                    searchOperator: request.searchOperator,
                    isCaseSensitive: request.isCaseSensitive
                ) else {
                    continue
                }
                if matches.count == Self.maximumMatchCount {
                    return WorkspaceGridSearchResult(
                        matches: matches,
                        hasAdditionalMatches: true
                    )
                }
                matches.append(
                    WorkspaceGridSearchMatch(
                        rowIndex: rowIndex,
                        dataColumnIndex: dataColumnIndex
                    )
                )
            }
        }

        try Task.checkCancellation()
        return WorkspaceGridSearchResult(
            matches: matches,
            hasAdditionalMatches: false
        )
    }

    private func searchableText(
        for cell: WorkspaceDatabaseDataCell
    ) -> String {
        switch cell {
        case .null:
            "NULL"
        case let .text(value):
            value
        case let .binary(byteCount, _):
            "<BINARY \(byteCount) bytes>"
        }
    }

    private func doesMatch(
        _ candidate: String,
        query: String,
        searchOperator: WorkspaceGridSearchOperator,
        isCaseSensitive: Bool
    ) -> Bool {
        let options: String.CompareOptions =
            isCaseSensitive ? [] : [.caseInsensitive]
        return switch searchOperator {
        case .contains:
            candidate.range(of: query, options: options) != nil
        case .equals:
            candidate.compare(query, options: options) == .orderedSame
        case .beginsWith:
            candidate.range(
                of: query,
                options: options.union(.anchored)
            ) != nil
        case .endsWith:
            candidate.range(
                of: query,
                options: options.union([.anchored, .backwards])
            ) != nil
        }
    }
}
