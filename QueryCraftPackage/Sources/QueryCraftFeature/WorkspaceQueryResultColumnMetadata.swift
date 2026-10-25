#if os(iOS)
import QueryCraftMobileCore
#endif

/// Physical protocol origins are the only source of field metadata. Projection
/// labels, expressions and similar names never determine a field's comment.
enum WorkspaceQueryResultColumnMetadata {
    static func selections(columns: [WorkspaceDatabaseDataColumn], currentDatabase: String?) -> [WorkspaceDatabaseObjectSelection] {
        Set(columns.compactMap { column in column.origin.flatMap {
            WorkspaceQueryResultEditing.selection(for: $0, currentDatabase: currentDatabase)
        } }).sorted { $0.id < $1.id }
    }
    static func resolve(columns: [WorkspaceDatabaseDataColumn], currentDatabase: String?,
                        details: [WorkspaceDatabaseObjectSelection: [WorkspaceDatabaseColumn]]) -> [Int: WorkspaceDatabaseColumn] {
        Dictionary(uniqueKeysWithValues: columns.compactMap { column in
            guard let origin = column.origin,
                  let selection = WorkspaceQueryResultEditing.selection(for: origin, currentDatabase: currentDatabase),
                  let detail = details[selection]?.first(where: { $0.name == origin.columnName }) else { return nil }
            return (column.id, detail)
        })
    }
}
