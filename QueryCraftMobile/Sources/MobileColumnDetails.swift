import QueryCraftMobileTransport

/// Only physical origins returned by the protocol may receive schema comments.
/// Names and aliases alone never establish an origin.
enum MobileColumnDetails {
    static func resolve(result: CDatabaseQueryResult, object: MobileDatabaseObject,
                        columns: [MobileTableColumn]) -> [String] {
        result.columns.indices.map { index in
            let fallback = result.columnTypes.indices.contains(index) ? result.columnTypes[index] ?? "" : ""
            guard result.columnOrigins.indices.contains(index), let origin = result.columnOrigins[index],
                  origin.databaseName == object.database, origin.tableName == object.name,
                  let column = columns.first(where: { $0.name == origin.columnName }) else { return fallback }
            return column.type + (column.comment.isEmpty ? "" : " · " + column.comment)
        }
    }
}
