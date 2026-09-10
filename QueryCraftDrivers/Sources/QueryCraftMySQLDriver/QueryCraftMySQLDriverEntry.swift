import Foundation
import QueryCraftFeature

@MainActor
@objc(QueryCraftMySQLDriverEntry)
public final class QueryCraftMySQLDriverEntry: NSObject,
    QueryCraftDriverBundleEntry
{
    public required override init() {}

    public func activate() async throws {
        await DatabaseDriverRegistry.shared.register(MySQLDatabaseDriver())
    }
}
