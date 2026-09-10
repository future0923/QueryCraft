import Foundation
import QueryCraftFeature

@MainActor
@objc(QueryCraftRedisDriverEntry)
public final class QueryCraftRedisDriverEntry: NSObject,
    QueryCraftDriverBundleEntry
{
    public required override init() {}

    public func activate() async throws {
        await DatabaseDriverRegistry.shared.register(RedisDatabaseDriver())
    }
}
