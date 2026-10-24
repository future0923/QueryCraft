import QueryCraftMobileCore
import Foundation
import QueryCraftMobileTransport

protocol MobileSQLServicing: Sendable {
    func schemas(configuration: MobileSQLConfiguration, database: String) async throws -> [String]
    func databases(configuration: MobileSQLConfiguration) async throws -> [String]
    func objects(configuration: MobileSQLConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog
    func columns(configuration: MobileSQLConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn]
    func page(configuration: MobileSQLConfiguration, object: MobileDatabaseObject,
              columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot
}

extension MobileSQLServicing {
    func schemas(configuration: MobileSQLConfiguration, database: String) async throws -> [String] { [] }
}

struct MobileMySQLService: MobileSQLServicing {
    let executor: any MobileQueryExecuting
    let isDoris: Bool
    init(executor: any MobileQueryExecuting = MobileMariaDBExecutor(), isDoris: Bool = false) { self.executor = executor; self.isDoris = isDoris }
    private func literal(_ value: String) -> String {
        isDoris ? "UNHEX('" + value.utf8.map { String(format: "%02x", $0) }.joined() + "')" : Self.literal(value)
    }

    static func identifier(_ value: String) -> String { "`" + value.replacingOccurrences(of: "`", with: "``") + "`" }
    static func literal(_ value: String) -> String {
        value.isEmpty ? "''" : "CONVERT(0x" + value.utf8.map { String(format: "%02x", $0) }.joined() + " USING utf8mb4)"
    }

    func catalogConfiguration(_ configuration: MobileSQLConfiguration) -> MobileSQLConfiguration {
        .init(host: configuration.host, port: configuration.port, username: configuration.username,
              password: configuration.password, database: nil, tlsMode: configuration.tlsMode)
    }

    func databases(configuration: MobileSQLConfiguration) async throws -> [String] {
        // Do not bind the initial catalog connection to a database that may have disappeared.
        let config = catalogConfiguration(configuration)
        let result = try await executor.execute(configuration: config, sql: "SHOW DATABASES")
        return result.rows.compactMap { $0.first ?? nil }
    }

    func objects(configuration: MobileSQLConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind? = nil) async throws -> MobileObjectCatalog {
        let typeFilter = kind.map { "TABLE_TYPE = " + literal($0 == .view ? "VIEW" : "BASE TABLE") }
            ?? "TABLE_TYPE IN ('BASE TABLE', 'VIEW')"
        let query = """
        SELECT TABLE_NAME, TABLE_TYPE, TABLE_COMMENT FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = \(literal(database))
        AND \(typeFilter)
        ORDER BY TABLE_NAME
        """
        let result = try await executor.execute(configuration: catalogConfiguration(configuration), sql: query)
        // The executor bounds metadata to 10,000 rows / 8 MiB and fails explicitly
        // on overflow. Never fuzzy-search only a truncated 200-object window.
        let objects = try result.rows.map { row -> MobileDatabaseObject in
            guard row.count >= 3, let name = row[0], let type = row[1] else { throw MobileQueryError.invalidServerMetadata }
            return .init(database: database, name: name, kind: type == "VIEW" ? .view : .table,
                         comment: type == "VIEW" && row[2] == "VIEW" ? "" : (row[2] ?? ""))
        }
        return .init(objects: MobileCatalogSearch.objects(objects, matching: search), hasMore: false)
    }

    func columns(configuration: MobileSQLConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] {
        let query = """
        SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
        FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(literal(object.database))
        AND TABLE_NAME = \(literal(object.name)) ORDER BY ORDINAL_POSITION
        """
        let result = try await executor.execute(configuration: catalogConfiguration(configuration), sql: query)
        guard !result.rows.isEmpty else { throw MobileQueryError.invalidServerMetadata }
        return try result.rows.map { row in
            guard row.count >= 7, let name = row[0], let type = row[1], let nullable = row[2] else {
                throw MobileQueryError.invalidServerMetadata
            }
            return .init(name: name, type: type, isNullable: nullable == "YES", key: row[3] ?? "",
                         defaultValue: row[4], extra: row[5] ?? "", comment: row[6] ?? "")
        }
    }

    func page(configuration: MobileSQLConfiguration, object: MobileDatabaseObject,
              columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter = .empty) async throws -> MobileTableSnapshot {
        let size = max(1, min(size, 200)), offset = max(0, offset)
        try MobileTableFilterDraft.validate(filter, columns: columns)
        let predicate = try MySQLDataFilterPredicate.make(filter, values: isDoris ? .dorisLiterals : .literals)
        let primary = columns.filter { $0.key == "PRI" }.map(\.name)
        var order = primary.map { Self.identifier($0) + " ASC" }
        if let sortColumn {
            guard columns.contains(where: { $0.name == sortColumn }) else { throw MobileQueryError.invalidServerMetadata }
            order = [Self.identifier(sortColumn) + (ascending ? " ASC" : " DESC")]
                + primary.filter { $0 != sortColumn }.map { Self.identifier($0) + " ASC" }
        }
        let ordering = order.isEmpty ? "" : " ORDER BY " + order.joined(separator: ", ")
        let query = "SELECT * FROM \(Self.identifier(object.database)).\(Self.identifier(object.name))\(predicate.sql)\(ordering) LIMIT \(size + 1) OFFSET \(offset)"
        let preview = try await executor.preview(configuration: catalogConfiguration(configuration), sql: query,
            maximumRows: size + 1, maximumBytes: 8_388_608)
        guard !preview.isTruncated else { throw MobileQueryError.resultTooLarge }
        let r = preview.result
        let result = CDatabaseQueryResult(columns: r.columns, columnTypes: r.columnTypes, columnOrigins: r.columnOrigins,
            rows: Array(r.rows.prefix(size)))
        return .init(object: object,
            preview: .init(result: result, cells: Array(preview.cells.prefix(size))), columns: columns,
            offset: offset, pageSize: size, hasNextPage: r.rows.count > size, hasStableOrder: !primary.isEmpty,
            filter: filter, sortColumn: sortColumn, ascending: ascending)
    }
}
