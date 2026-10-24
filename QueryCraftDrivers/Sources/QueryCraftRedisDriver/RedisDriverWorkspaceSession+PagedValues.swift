import Foundation
import QueryCraftFeature

extension RedisDriverWorkspaceSession {
    private func reader() throws -> RedisCollectionReader {
        if let pagedValueReader { return pagedValueReader }
        let reader = RedisCollectionReader(client: try requireClient())
        pagedValueReader = reader
        return reader
    }
    func fetchRedisStringChunk(_ reference: RedisKeyReference, offset: Int, maximumBytes: Int) async throws -> RedisStringChunk {
        try await reader().fetchRedisStringChunk(reference, offset: offset, maximumBytes: maximumBytes)
    }
    func resolveRedisKeyTypes(_ references: [RedisKeyReference]) async throws -> [RedisKeyReference] {
        try await reader().resolveRedisKeyTypes(references)
    }
    func fetchRedisCollectionPage(_ query: RedisCollectionQuery) async throws -> RedisCollectionPage {
        try await reader().fetchRedisCollectionPage(query)
    }
}
