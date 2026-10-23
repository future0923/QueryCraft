import Foundation
import QueryCraftMobileTransport
import QueryCraftMobileCore

struct MobileDatabaseObject: Hashable, Identifiable, Sendable {
    enum Kind: String, Sendable { case table, view }
    let database: String
    let name: String
    let kind: Kind
    let comment: String
    var id: String { database + "\0" + name }
}

struct MobileTableColumn: Identifiable, Equatable, Sendable {
    let name: String
    let type: String
    let isNullable: Bool
    let key: String
    let defaultValue: String?
    let extra: String
    let comment: String
    var id: String { name }
}

struct MobileTableSnapshot: Sendable {
    let object: MobileDatabaseObject
    let preview: CDatabaseQueryPreview
    let columns: [MobileTableColumn]
    let offset: Int
    let pageSize: Int
    let hasNextPage: Bool
    let hasStableOrder: Bool
    var filter = WorkspaceDatabaseDataFilter.empty
    var sortColumn: String? = nil
    var ascending = true
}

struct MobileObjectCatalog: Sendable {
    let objects: [MobileDatabaseObject]
    let hasMore: Bool
}
