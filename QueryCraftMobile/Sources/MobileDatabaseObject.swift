import Foundation
import QueryCraftMobileTransport
import QueryCraftMobileCore

struct MobileDatabaseObject: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case table, view }
    let database: String
    let name: String
    let kind: Kind
    let comment: String
    var schemaName: String? = nil
    var displayName: String { schemaName.map { $0 + "." + name } ?? name }
    var id: String { database + "\0" + (schemaName.map { $0 + "\0" } ?? "") + name }
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
    init(name: String, type: String, isNullable: Bool, key: String, defaultValue: String?, extra: String, comment: String) {
        self.name = name; self.type = type; self.isNullable = isNullable; self.key = key
        self.defaultValue = defaultValue; self.extra = extra; self.comment = comment
    }
    init(_ column: WorkspaceDatabaseColumn) {
        self.init(name: column.name, type: column.type, isNullable: column.isNullable, key: column.key,
                  defaultValue: column.defaultValue, extra: column.extra, comment: column.comment)
    }
}

struct MobileTableSnapshot: Sendable {
    let object: MobileDatabaseObject
    let preview: MobileSQLPreview
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
