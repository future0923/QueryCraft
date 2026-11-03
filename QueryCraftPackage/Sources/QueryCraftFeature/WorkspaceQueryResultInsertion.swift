import Foundation

enum WorkspaceQueryResultInsertion {
    /// Protocol origins identify physical columns, but lose relation aliases.
    /// Also check the executed SQL so a self join cannot become an insert target.
    static func selection(
        columns: [WorkspaceDatabaseDataColumn],
        currentDatabase: String?,
        databaseType: DatabaseType,
        supportsDataEditing: Bool,
        syntax: SQLParseSnapshot
    ) -> WorkspaceDatabaseObjectSelection? {
        guard supportsDataEditing,
              databaseType == .mysql || databaseType == .postgresql,
              syntax.isReliable,
              syntax.statements.count == 1,
              syntax.statements.first?.kind == .read,
              syntax.relationReferences.count == 1,
              let relation = syntax.relationReferences.first,
              let origin = columns.compactMap(\.origin).first,
              relation.objectName == origin.tableName,
              relation.databaseName == nil || relation.databaseName == (
                databaseType == .postgresql ? origin.schemaName : origin.databaseName ?? currentDatabase
              )
        else { return nil }
        return WorkspaceQueryResultEditing.selection(
            for: columns, currentDatabase: currentDatabase
        )
    }
}
