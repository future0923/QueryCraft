import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobilePostgreSQLExecutor: MobileQueryExecuting {
    func execute(configuration: MobileSQLConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        let preview = try await read(configuration: configuration, sql: sql, maximumRows: 10_000, maximumBytes: 8_388_608, includeComments: false)
        guard !preview.isTruncated else { throw MobileQueryError.resultTooLarge }
        return preview.result
    }
    func preview(configuration: MobileSQLConfiguration, sql: String, maximumRows: Int, maximumBytes: Int) async throws -> MobileSQLPreview {
        try await read(configuration: configuration, sql: sql, maximumRows: maximumRows, maximumBytes: maximumBytes, includeComments: true)
    }
    private func read(configuration: MobileSQLConfiguration, sql: String, maximumRows: Int, maximumBytes: Int, includeComments: Bool) async throws -> MobileSQLPreview {
        let plan = try await MobileSQLExecutionPlanner().planDocument(source: .init(revision: .init(0), text: sql))
        guard plan.statements.count == 1, plan.statements[0].kind == .read else { throw MobileQueryError.readOnlySQLRequired }
        let client = LibPQClient(configuration: configuration.postgreSQL)
        do {
            try await client.connect(); try Task.checkCancellation()
            _ = try await client.query("SET statement_timeout TO '30s'")
            _ = try await client.query("SET standard_conforming_strings TO on")
            _ = try await client.query("BEGIN READ ONLY")
            if let schema = configuration.schemaName {
                // A single quoted identifier, including dots/quotes, is one search_path entry.
                _ = try await client.query(PostgreSQLCatalog.searchPathQuery(schema: schema, local: true))
            }
            let result = try await client.queryPreview(sql, maximumRows: maximumRows, maximumBytes: maximumBytes)
            var preview = MobileSQLPreview(postgreSQL: result, database: configuration.database ?? "postgres")
            if includeComments, !result.isTruncated {
                preview.columnDetails = try await MobilePostgreSQLColumnDetails.resolve(preview.workspaceColumns, client: client)
            }
            await client.close(); try Task.checkCancellation()
            return preview
        } catch { await client.close(); throw error }
    }
    func batch(configuration: MobileSQLConfiguration, statements: [SQLExecutionStatement], receive: @escaping @Sendable (MobileQueryBatchEvent) async throws -> Void) async throws {
        try MobileQueryBatchLimits.validate(statements)
        var remaining = MobileQueryBatchLimits.maximumBytes
        for statement in statements {
            try Task.checkCancellation(); try await receive(.started(statement.index))
            let result = try await preview(configuration: configuration, sql: statement.sql, maximumRows: 500, maximumBytes: min(remaining, 4_194_304))
            remaining -= MobileQueryBatchLimits.retainedBytes(result)
            try await receive(.completed(statement.index, result))
            if result.isTruncated, statement.index != statements.last?.index { throw MobileQueryBatchError.truncatedSession }
            if remaining <= 0, statement.index != statements.last?.index { throw MobileQueryBatchError.resultBudget }
        }
    }
}

struct MobilePostgreSQLService: MobileSQLServicing, MobileSQLMetadataProviding {
    let executor: any MobileQueryExecuting
    init(executor: any MobileQueryExecuting = MobilePostgreSQLExecutor()) { self.executor = executor }
    func databases(configuration: MobileSQLConfiguration) async throws -> [String] {
        let sql = "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        return try await executor.execute(configuration: configuration, sql: sql).rows.compactMap { $0.first ?? nil }
    }
    func schemas(configuration: MobileSQLConfiguration, database: String) async throws -> [String] {
        try await executor.execute(configuration: configuration.selecting(database: database), sql: PostgreSQLCatalog.schemasQuery).rows.compactMap { $0.first ?? nil }
    }
    func objects(configuration: MobileSQLConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog {
        let result = try await executor.execute(configuration: configuration.selecting(database: database), sql: PostgreSQLCatalog.objectsQuery)
        let objects = try result.dictionaryRows.compactMap { row -> MobileDatabaseObject? in
            guard let schema = row["schema_name"] ?? nil, let name = row["object_name"] ?? nil, let type = row["object_kind"] ?? nil else { throw MobileQueryError.invalidServerMetadata }
            let objectKind: MobileDatabaseObject.Kind = type == "v" || type == "m" ? .view : .table
            guard kind == nil || kind == objectKind else { return nil }
            return .init(database: database, name: name, kind: objectKind, comment: (row["object_comment"] ?? nil) ?? "", schemaName: schema)
        }
        return .init(objects: MobileCatalogSearch.objects(objects, matching: search), hasMore: false)
    }
    func columns(configuration: MobileSQLConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] {
        guard let schema = object.schemaName else { throw MobileQueryError.invalidServerMetadata }
        let result = try await executor.execute(configuration: configuration.selecting(database: object.database), sql: PostgreSQLCatalog.columnsQuery(schema: schema, name: object.name))
        let columns = result.dictionaryRows.compactMap(PostgreSQLCatalog.column)
        guard !columns.isEmpty, columns.count == result.rows.count else { throw MobileQueryError.invalidServerMetadata }
        return columns.map(MobileTableColumn.init)
    }
    func page(configuration: MobileSQLConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot {
        guard let schema = object.schemaName else { throw MobileQueryError.invalidServerMetadata }
        try MobileTableFilterDraft.validate(filter, columns: columns)
        let size = max(1, min(size, 200)), offset = max(0, offset), quote = PostgreSQLCatalog.identifier
        let primary = columns.filter { $0.key == "PRI" }.map(\.name)
        var order = primary.map { quote($0) + " ASC" }
        if let sortColumn {
            guard columns.contains(where: { $0.name == sortColumn }) else { throw MobileQueryError.invalidServerMetadata }
            order = [quote(sortColumn) + (ascending ? " ASC" : " DESC")] + primary.filter { $0 != sortColumn }.map { quote($0) + " ASC" }
        }
        let ordering = order.isEmpty ? "" : " ORDER BY " + order.joined(separator: ", ")
        let sql = "SELECT * FROM \(quote(schema)).\(quote(object.name))" + (try PostgreSQLCatalog.filterPredicate(filter)) + ordering + " LIMIT \(size + 1) OFFSET \(offset)"
        let preview = try await executor.preview(configuration: configuration.selecting(database: object.database), sql: sql, maximumRows: size + 1, maximumBytes: 8_388_608)
        guard !preview.isTruncated else { throw MobileQueryError.resultTooLarge }
        let r = preview.result
        let trimmed = MobileSQLPreview(result: .init(columns: r.columns, columnTypes: r.columnTypes, rows: Array(r.rows.prefix(size))), cells: Array(preview.cells.prefix(size)), metadata: preview.workspaceColumns)
        return .init(object: object, preview: trimmed, columns: columns, offset: offset, pageSize: size, hasNextPage: r.rows.count > size, hasStableOrder: !primary.isEmpty, filter: filter, sortColumn: sortColumn, ascending: ascending)
    }
    func editorCatalog(configuration: MobileSQLConfiguration) async throws -> [WorkspaceSchemaDatabase] {
        let database = configuration.database ?? "postgres"
        let catalog = try await objects(configuration: configuration, database: database, search: "", kind: nil)
        return [.init(name: database, objects: catalog.objects.map { .init(name: $0.displayName, kind: $0.kind == .view ? .view : .table, columns: [], comment: $0.comment) })]
    }
    func editorColumns(configuration: MobileSQLConfiguration, references: [WorkspaceSchemaObjectReference]) async throws -> [WorkspaceSchemaObjectColumns] {
        guard !references.isEmpty else { return [] }
        let database = configuration.database ?? "postgres"
        let catalog = try await objects(configuration: configuration, database: database, search: "", kind: nil)
        var result: [WorkspaceSchemaObjectColumns] = []
        for ref in references {
            guard ref.databaseName == database else { throw MobileQueryError.invalidServerMetadata }
            let matches = catalog.objects.filter { $0.displayName == ref.objectName }
            guard matches.count == 1, let object = matches.first else { throw MobileQueryError.invalidServerMetadata }
            let columns = try await columns(configuration: configuration, object: object)
            result.append(.init(reference: ref, columns: columns.enumerated().map { .init(name: $0.element.name, type: $0.element.type, ordinalPosition: $0.offset + 1, comment: $0.element.comment) }))
        }
        return result
    }
    func editorContext(configuration: MobileSQLConfiguration) async throws -> SQLHighlightContext { .init(databaseType: .postgresql) }
}

/// Both previews and cached session results resolve comments from protocol origins.
enum MobilePostgreSQLColumnDetails {
    static func resolve(_ fields: [WorkspaceDatabaseDataColumn], client: LibPQClient) async throws -> [String] {
        var comments: [String: [WorkspaceDatabaseColumn]] = [:]
        for field in fields {
            guard let origin = field.origin, let schema = origin.schemaName else { continue }
            let key = schema + "\0" + origin.tableName
            guard comments[key] == nil else { continue }
            if let columns = try? await client.query(PostgreSQLCatalog.columnsQuery(schema: schema, name: origin.tableName)) {
                comments[key] = columns.dictionaryRows.compactMap(PostgreSQLCatalog.column)
            }
            try Task.checkCancellation()
        }
        return fields.map { field in
            guard let origin = field.origin, let schema = origin.schemaName,
                  let column = comments[schema + "\0" + origin.tableName]?.first(where: { $0.name == origin.columnName }) else { return field.type ?? "" }
            return (field.type ?? column.type) + (column.comment.isEmpty ? "" : " · " + column.comment)
        }
    }
}
