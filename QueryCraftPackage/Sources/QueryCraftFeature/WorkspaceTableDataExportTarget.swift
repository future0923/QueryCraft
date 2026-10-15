import Foundation

/// Captured at the menu action, independent of the currently selected page.
struct WorkspaceTableDataExportTarget: Sendable {
    let sessionFactory: any WorkspaceSessionFactory
    let configuration: DatabaseConnectionConfiguration
    let selection: WorkspaceDatabaseObjectSelection

    func makeRequest(
        format: WorkspaceDataExportFormat,
        preferences: WorkspaceDataExportPreferences
    ) async throws -> WorkspaceDataExportRequest {
        guard selection.kind == .table,
              let dialect = WorkspaceSQLExportDialect(databaseType: configuration.databaseType)
        else { throw WorkspaceDataExportError.unsupportedSQLValue }
        let source = WorkspaceTableDataExportRowSource(
            sessionFactory: sessionFactory,
            configuration: configuration.selecting(database: selection.databaseName),
            selection: selection,
            sort: .none,
            requiresCompleteValues: true
        )
        do {
            let metadata = try await source.prepareColumns()
            var options = preferences.options(for: format)
            options.scope = .allTableRows
            options.sqlTableName = selection.objectName
            options.sqlDialect = dialect
            options.sqlWrapsInTransaction = preferences.sqlWrapsInTransaction && dialect != .doris
            // PostgreSQL's catalog represents objects as schema.name. Prefer protocol origins,
            // which keep literal dots in names intact; fetchObjects primes the driver's identity map.
            let origin = metadata.compactMap(\.origin).first
            if dialect == .postgresql {
                let schema = origin?.schemaName ?? selection.object.schemaName ?? "public"
                let table = origin?.tableName ?? selection.object.nameWithinSchema
                options.sqlTableIdentifierParts = preferences.sqlIncludesDatabaseName ? [schema, table] : [table]
            } else {
                options.sqlTableIdentifierParts = preferences.sqlIncludesDatabaseName
                    ? [selection.databaseName, selection.objectName] : [selection.objectName]
            }
            var columns = metadata.enumerated().map {
                WorkspaceGridCopyColumn(name: $0.element.name, dataIndex: $0.offset)
            }
            if format == .sql {
                let details = try await source.sqlColumns()
                let generated = Set(details.filter(\.isGenerated).map(\.name))
                columns.removeAll { generated.contains($0.name) }
                options.sqlOverridesIdentity = dialect == .postgresql
                    && details.contains { $0.extra.uppercased().contains("IDENTITY") }
                if dialect == .doris, details.contains(where: { column in
                    ["HLL", "BITMAP", "AGG_STATE", "ARRAY", "MAP", "STRUCT"].contains { type in
                        column.type.uppercased().hasPrefix(type)
                    }
                }) {
                    throw WorkspaceDataExportError.unsupportedSQLValue
                }
            }
            guard !columns.isEmpty else { throw WorkspaceDataExportError.missingColumns }
            try Task.checkCancellation()
            return WorkspaceDataExportRequest(
                columns: columns,
                options: options,
                estimatedRowCount: nil,
                worksheetName: selection.objectName,
                source: source
            )
        } catch {
            await source.finish()
            throw error
        }
    }
}
