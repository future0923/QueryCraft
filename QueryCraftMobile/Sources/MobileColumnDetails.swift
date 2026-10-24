import QueryCraftMobileTransport

/// Only complete physical protocol origins may receive schema comments.
enum MobileColumnDetails {
    static func resolve(result: CDatabaseQueryResult, object: MobileDatabaseObject, columns: [MobileTableColumn]) -> [String] {
        resolve(preview: .init(result: result), object: object, columns: columns)
    }
    static func resolve(preview: MobileSQLPreview, object: MobileDatabaseObject, columns: [MobileTableColumn]) -> [String] {
        preview.workspaceColumns.map { field in
            guard let origin = field.origin, origin.databaseName == object.database,
                  origin.schemaName == object.schemaName, origin.tableName == object.name,
                  let column = columns.first(where: { $0.name == origin.columnName }) else { return field.type ?? "" }
            return column.type + (column.comment.isEmpty ? "" : " · " + column.comment)
        }
    }
}
