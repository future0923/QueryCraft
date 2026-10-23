import Foundation
#if canImport(QueryCraftFeature)
import QueryCraftFeature
#elseif canImport(QueryCraftMobileCore)
import QueryCraftMobileCore
#endif

/// Additive bounded result; existing desktop result layout and query API stay intact.
public struct CDatabaseQueryPreview: Sendable {
    public let result: CDatabaseQueryResult
    public let cells: [[WorkspaceDatabaseDataCell]]
    public let isTruncated: Bool

    public init(result: CDatabaseQueryResult, cells: [[WorkspaceDatabaseDataCell]] = [], isTruncated: Bool = false) {
        self.result = result
        self.cells = cells
        self.isTruncated = isTruncated
    }
}
