import Foundation
import QueryCraftFeature

@MainActor
@objc(QueryCraftDorisDriverEntry)
public final class QueryCraftDorisDriverEntry: NSObject,
    QueryCraftDriverBundleEntry
{
    public required override init() {}

    public func activate() async throws {
        await DatabaseDriverRegistry.shared.register(DorisDatabaseDriver())
    }
}
