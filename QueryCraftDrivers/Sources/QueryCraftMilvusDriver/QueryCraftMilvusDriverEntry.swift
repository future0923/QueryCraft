import Foundation
import QueryCraftFeature

@MainActor
@objc(QueryCraftMilvusDriverEntry)
public final class QueryCraftMilvusDriverEntry: NSObject, QueryCraftDriverBundleEntry {
    public required override init() {}
    public func activate() async throws { await DatabaseDriverRegistry.shared.register(MilvusDatabaseDriver()) }
}
