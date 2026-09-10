import Foundation
import QueryCraftFeature
import Testing

@testable import QueryCraftRedisDriver

struct RedisPipelineIntegrationTests {
    @Test
    func pipelinePreservesReplyOrderAgainstConfiguredRedis() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["QUERYCRAFT_REDIS_TEST_HOST"],
              let password = environment["QUERYCRAFT_REDIS_TEST_PASSWORD"]
        else { return }
        let databaseIndex = Int(
            environment["QUERYCRAFT_REDIS_TEST_DATABASE"] ?? "10"
        ) ?? 10
        let configuration = try RedisConnectionConfiguration(
            DatabaseConnectionConfiguration(
                databaseType: .redis,
                host: host,
                port: 6_379,
                username: "",
                password: password,
                database: "DB \(databaseIndex)",
                tlsMode: .disabled
            )
        )
        let client = RedisClient(configuration: configuration)
        try await client.connect()
        let prefix = "querycraft:pipeline-test:\(UUID().uuidString)"
        let keys = ["str", "hash", "list", "set", "zset"].map {
            "\(prefix):\($0)"
        }

        do {
            let setupReplies = try await client.executePipeline(
                [
                    ["SET", keys[0], "value"],
                    ["HSET", keys[1], "field", "value"],
                    ["RPUSH", keys[2], "value"],
                    ["SADD", keys[3], "value"],
                    ["ZADD", keys[4], "1", "value"],
                ],
                databaseIndex: databaseIndex
            )
            #expect(setupReplies.count == keys.count)

            let typeReplies = try await client.executePipeline(
                keys.map { ["TYPE", $0] },
                databaseIndex: databaseIndex
            )
            #expect(typeReplies.compactMap(\.stringValue) == [
                "string", "hash", "list", "set", "zset",
            ])

            _ = try await client.executePipeline(
                keys.map { ["DEL", $0] },
                databaseIndex: databaseIndex
            )
            await client.close()
        } catch {
            _ = try? await client.executePipeline(
                keys.map { ["DEL", $0] },
                databaseIndex: databaseIndex
            )
            await client.close()
            throw error
        }
    }
}
