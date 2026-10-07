import Foundation
import QueryCraftFeature

@MainActor
@objc(QueryCraftKafkaDriverEntry)
public final class QueryCraftKafkaDriverEntry: NSObject,
    QueryCraftDriverBundleEntry
{
    public required override init() {}

    public func activate() async throws {
        await DatabaseDriverRegistry.shared.register(KafkaDatabaseDriver())
    }
}
