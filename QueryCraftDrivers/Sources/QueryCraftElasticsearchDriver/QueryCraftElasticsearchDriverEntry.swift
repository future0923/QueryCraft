import Foundation
import QueryCraftFeature

@MainActor
@objc(QueryCraftElasticsearchDriverEntry)
public final class QueryCraftElasticsearchDriverEntry: NSObject,
    QueryCraftDriverBundleEntry
{
    public required override init() {}

    public func activate() async throws {
        await DatabaseDriverRegistry.shared.register(
            ElasticsearchDatabaseDriver()
        )
    }
}
