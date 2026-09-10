import Foundation

actor RedisKeyScanLoader {
    typealias PageFetcher = @Sendable (
        _ cursor: UInt64,
        _ pattern: String?,
        _ count: Int
    ) async throws -> RedisKeyScanPage
    typealias ExactLookup = @Sendable (_ key: String) async throws -> Bool
    typealias ProgressHandler = @Sendable (
        RedisKeyScanProgress
    ) async -> Void

    func load(
        existingKeys: [RedisKeyReference],
        cursor: UInt64,
        search: RedisKeySearchRequest,
        databaseIndex: Int,
        scope: RedisKeyLoadScope,
        fetchPage: PageFetcher,
        exactLookup: ExactLookup,
        progress: ProgressHandler
    ) async throws -> RedisKeyScanResult {
        if search.mode == .exact, !search.text.isEmpty {
            try Task.checkCancellation()
            let exists = try await exactLookup(search.text)
            let keys = exists
                ? [RedisKeyReference(databaseIndex: databaseIndex, name: search.text)]
                : []
            await progress(RedisKeyScanProgress(discoveredKeyCount: keys.count))
            return RedisKeyScanResult(keys: keys, nextCursor: 0)
        }

        var uniqueKeys: [String: RedisKeyReference] = [:]
        uniqueKeys.reserveCapacity(existingKeys.count)
        for key in existingKeys {
            uniqueKeys[key.name] = key
        }
        let initialKeyCount = uniqueKeys.count
        var nextCursor = cursor
        repeat {
            try Task.checkCancellation()
            let page = try await fetchPage(
                nextCursor,
                search.mode.scanPattern(for: search.text),
                scanCount(for: search)
            )
            try Task.checkCancellation()
            for key in page.keys {
                uniqueKeys[key.name] = key
            }
            nextCursor = page.nextCursor
            await progress(
                RedisKeyScanProgress(discoveredKeyCount: uniqueKeys.count)
            )
        } while shouldContinue(
            scope: scope,
            nextCursor: nextCursor,
            discoveredMatchCount: uniqueKeys.count - initialKeyCount
        )

        let keys = uniqueKeys.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return RedisKeyScanResult(keys: keys, nextCursor: nextCursor)
    }

    private func shouldContinue(
        scope: RedisKeyLoadScope,
        nextCursor: UInt64,
        discoveredMatchCount: Int
    ) -> Bool {
        guard nextCursor != 0 else { return false }
        switch scope {
        case .nextPage:
            return false
        case .matchingPage:
            return discoveredMatchCount < Self.matchingPageSize
        case .allRemaining:
            return true
        }
    }

    private func scanCount(for search: RedisKeySearchRequest) -> Int {
        search.text.isEmpty ? Self.scanCount : Self.searchScanCount
    }

    private static let scanCount = 500
    private static let searchScanCount = 10_000
    private static let matchingPageSize = 500
}
