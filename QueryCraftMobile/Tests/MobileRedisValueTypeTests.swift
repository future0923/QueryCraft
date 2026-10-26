import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

struct MobileRedisStringPreviewTests {
    @Test func preservesUTF8AndBinaryBytes() {
        let text = String(repeating: "a", count: 65_535) + "你好"
        let raw = Data(text.utf8)
        let first = MobileRedisStringPreview.aligned(.init(value: .init(data: raw.prefix(65_536)), offset: 0, totalByteCount: raw.count))
        #expect(first.nextOffset == 65_535)
        #expect(first.value.losslessUTF8String == String(repeating: "a", count: 65_535))
        let last = MobileRedisStringPreview.aligned(.init(value: .init(data: Data(raw.dropFirst(first.nextOffset))), offset: first.nextOffset, totalByteCount: raw.count))
        #expect(last.value.losslessUTF8String == "你好")
        #expect(first.value.data + last.value.data == raw)
        let binary = RedisStringChunk(value: .init(data: Data([0xFF, 0, 0xFE])), offset: 0, totalByteCount: 3)
        #expect(MobileRedisStringPreview.aligned(binary) == binary)
        let empty = RedisStringChunk(value: .init(data: Data()), offset: 0, totalByteCount: 0)
        #expect(MobileRedisStringPreview.aligned(empty) == empty)
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil))
@MainActor struct MobileRedisValueTypeTests {
    @Test func realTypesHaveCorrectColumnsStatusAndLosslessStringPaging() async throws {
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:type:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect()
        do {
            let service = MobileResourceService(profile: profile, password: nil)
            let resource = MobileResource(name: key, kind: "key")
            let value = String(repeating: "a", count: 65_535) + "你好🙂"
            _ = try await client.execute(["SET", key, value])
            let first = try await service.details(resource: resource, scope: "0", offset: 0, cursor: 0)
            let firstChunk = try #require(first.redisString)
            #expect(first.data.columns == ["值"])
            #expect(first.status.contains("SCAN") == false)
            #expect(firstChunk.value.losslessUTF8String != nil)
            #expect(first.hasNext)
            let next = try await service.details(resource: resource, scope: "0", offset: first.pageStride, cursor: 0)
            let lastChunk = try #require(next.redisString)
            #expect(lastChunk.value.losslessUTF8String == "你好🙂")
            #expect(firstChunk.value.data + lastChunk.value.data == Data(value.utf8))
            #expect(next.hasNext == false)
            _ = try await client.execute(["SET", key, ""])
            let empty = try await service.details(resource: resource, scope: "0", offset: 0, cursor: 0)
            #expect(empty.redisString?.value.losslessUTF8String == "")
            #expect(empty.redisType == .string)
            _ = try await client.executeRaw([.init(utf8: "SET"), .init(utf8: key), .init(data: Data([255, 0, 254]))])
            let binary = try await service.details(resource: resource, scope: "0", offset: 0, cursor: 0)
            #expect(binary.redisString?.value.data == Data([255, 0, 254]))
            for (command, columns, scan) in [
                (["RPUSH", key, "你好"], ["索引", "值"], false),
                (["HSET", key, "field", "你好"], ["字段", "值"], true),
                (["SADD", key, "你好"], ["成员"], true),
                (["ZADD", key, "1.5", "你好"], ["成员", "分数"], false),
                (["XADD", key, "1-0", "field", "你好"], ["entryID", "fields"], false)
            ] {
                _ = try await client.execute(["DEL", key]); _ = try await client.execute(command)
                let result = try await service.details(resource: resource, scope: "0", offset: 0, cursor: 0)
                #expect(result.data.columns == columns)
                #expect(result.data.rows.allSatisfy { $0.count == columns.count })
                #expect(result.status.contains("SCAN") == scan)
                #expect(result.redisString == nil)
            }
            _ = try await client.execute(["DEL", key])
            let gone = try await service.details(resource: resource, scope: "0", offset: 0, cursor: 0)
            #expect(gone.redisType == RedisKeyType.none)
            #expect(gone.data.rows.isEmpty)
            await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }
}
