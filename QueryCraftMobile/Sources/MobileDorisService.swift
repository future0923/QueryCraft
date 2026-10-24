import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

/// Doris shares the wire protocol, but does not support MySQL's read-only
/// transactions. Match the desktop driver's read-only capability explicitly.
struct MobileDorisExecutor: MobileQueryExecuting {
    func execute(configuration: MobileSQLConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        let page = try await preview(configuration: configuration, sql: sql, maximumRows: 10_000, maximumBytes: 8_388_608)
        guard !page.isTruncated else { throw MobileQueryError.resultTooLarge }
        return page.result
    }
    func preview(configuration: MobileSQLConfiguration, sql: String, maximumRows: Int, maximumBytes: Int) async throws -> MobileSQLPreview {
        guard configuration.tlsMode == .disabled || configuration.tlsMode == .required else { throw MobileQueryError.verifiedTLSUnavailable }
        // Accept either SQL quoting mode conservatively; no session SET/BEGIN is sent.
        try MobileSQLReadPolicy.validate(sql, backslashEscapes: true)
        try MobileSQLReadPolicy.validate(sql, backslashEscapes: false)
        let client = MariaDBClient(configuration: configuration)
        do {
            try Task.checkCancellation(); try await client.connect(); try Task.checkCancellation()
            let result = try await client.mobilePreview(sql, maximumRows: maximumRows, maximumBytes: maximumBytes)
            await client.close(); try Task.checkCancellation(); return result
        } catch { await client.close(); throw error }
    }
}

struct MobileDorisService: MobileSQLServicing, MobileSQLMetadataProviding {
    let executor: any MobileQueryExecuting
    init(executor: any MobileQueryExecuting = MobileDorisExecutor()) { self.executor = executor }
    private var shared: MobileMySQLService { .init(executor: executor, isDoris: true) }
    func databases(configuration: MobileSQLConfiguration) async throws -> [String] { try await shared.databases(configuration: configuration) }
    func objects(configuration: MobileSQLConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog {
        do { return try await shared.objects(configuration: configuration, database: database, search: search, kind: kind) }
        catch {
            try Task.checkCancellation()
            let result = try await executor.execute(configuration: shared.catalogConfiguration(configuration), sql: "SHOW FULL TABLES FROM " + MobileMySQLService.identifier(database))
            let objects = try result.rows.compactMap { row -> MobileDatabaseObject? in
                guard let name = row.first ?? nil else { throw MobileQueryError.invalidServerMetadata }
                let objectKind: MobileDatabaseObject.Kind = row.count > 1 && row[1]?.uppercased() == "VIEW" ? .view : .table
                guard kind == nil || kind == objectKind else { return nil }
                return .init(database: database, name: name, kind: objectKind, comment: "")
            }
            return .init(objects: MobileCatalogSearch.objects(objects, matching: search), hasMore: false)
        }
    }
    func columns(configuration: MobileSQLConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] {
        let result = try await executor.execute(configuration: shared.catalogConfiguration(configuration),
            sql: "SHOW FULL COLUMNS FROM " + MobileMySQLService.identifier(object.database) + "." + MobileMySQLService.identifier(object.name))
        guard !result.rows.isEmpty else { throw MobileQueryError.invalidServerMetadata }
        let columns = DorisSchemaMetadata.columns(result.dictionaryRows)
        guard columns.count == result.rows.count else { throw MobileQueryError.invalidServerMetadata }
        return columns.map { .init(name: $0.name, type: $0.type, isNullable: $0.isNullable, key: $0.key,
            defaultValue: $0.defaultValue, extra: $0.extra, comment: $0.comment) }
    }

    func page(configuration: MobileSQLConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot {
        // Doris key columns are aggregation/duplicate keys, not unique row IDs.
        let neutral = columns.map { MobileTableColumn(name: $0.name, type: $0.type, isNullable: $0.isNullable, key: "", defaultValue: $0.defaultValue, extra: $0.extra, comment: $0.comment) }
        let page = try await shared.page(configuration: configuration, object: object, columns: neutral, offset: offset, size: size, sortColumn: sortColumn, ascending: ascending, filter: filter)
        return .init(object: object, preview: page.preview, columns: columns, offset: page.offset, pageSize: page.pageSize, hasNextPage: page.hasNextPage, hasStableOrder: false, filter: filter, sortColumn: sortColumn, ascending: ascending)
    }
    func editorCatalog(configuration: MobileSQLConfiguration) async throws -> [WorkspaceSchemaDatabase] {
        var output: [WorkspaceSchemaDatabase] = []
        var count = 0, bytes = 0
        for name in try await databases(configuration: configuration) {
            try Task.checkCancellation()
            let catalog = try await objects(configuration: configuration, database: name, search: "", kind: nil)
            count += catalog.objects.count
            bytes += name.utf8.count + catalog.objects.reduce(0) { $0 + $1.name.utf8.count + $1.comment.utf8.count }
            guard count <= 10_000, bytes <= 8_388_608 else { throw MobileQueryError.resultTooLarge }
            output.append(.init(name: name, objects: catalog.objects.map { .init(name: $0.name, kind: $0.kind == .view ? .view : .table, columns: [], comment: $0.comment) }))
        }
        return output
    }
    func editorColumns(configuration: MobileSQLConfiguration, references: [WorkspaceSchemaObjectReference]) async throws -> [WorkspaceSchemaObjectColumns] {
        var result: [WorkspaceSchemaObjectColumns] = []
        for ref in references {
            let columns = try await columns(configuration: configuration, object: .init(database: ref.databaseName, name: ref.objectName, kind: .table, comment: ""))
            result.append(.init(reference: ref, columns: columns.enumerated().map { .init(name: $0.element.name, type: $0.element.type, ordinalPosition: $0.offset + 1, comment: $0.element.comment) }))
        }
        return result
    }
    func editorContext(configuration: MobileSQLConfiguration) async throws -> SQLHighlightContext { .init(databaseType: .doris) }
}
