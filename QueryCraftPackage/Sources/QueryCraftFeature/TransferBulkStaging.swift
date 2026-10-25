#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation

/// Upsert bulk-loads into a private temporary table, then applies the same ordered
/// INSERT batches and conflict clause as the existing path. No REPLACE semantics,
/// deduplication or trigger disabling. The entire operation stays in one transaction.
struct TransferBulkStaging: Sendable {
    let ordinal: WorkspaceDatabaseColumn
    let create: String
    let createIndex: String?
    let drop: String
    let endpoint: TransferEndpoint
    let name: String
    private let prefix: String
    private let suffix: String
    private let ordinalSQL: String

    init(item: TransferPlanItem, target: TransferConnection, columns: [WorkspaceDatabaseColumn]) throws {
        let quote = TransferSQL.dialect(target.type).identifier
        name = "qc_stage_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var field = "qc_order_" + UUID().uuidString.prefix(8).lowercased()
        while columns.contains(where: { $0.name == field }) { field += "_" }
        ordinal = .init(name: field, type: "bigint", collation: nil, isNullable: false, key: "", defaultValue: nil, extra: "", comment: "")
        ordinalSQL = quote(field)
        endpoint = .init(database: target.endpoint.database, schema: target.type == .postgresql ? "pg_temp" : "")
        let table = TransferSQL.qualified(target.endpoint, item.targetName, type: target.type)
        let stage = TransferSQL.qualified(endpoint, name, type: target.type)
        let fields = columns.map { quote($0.name) }.joined(separator: ", ")
        let cast = target.type == .postgresql ? "NULL::bigint" : "CAST(0 AS SIGNED)"
        create = "CREATE TEMPORARY TABLE \(quote(name))\(target.type == .mysql ? " (PRIMARY KEY (\(ordinalSQL))) ENGINE=InnoDB" : "") AS SELECT \(fields), \(cast) AS \(ordinalSQL) FROM \(table) WHERE 1=0"
        createIndex = target.type == .postgresql ? "CREATE UNIQUE INDEX \(quote(name + "_order")) ON \(stage) (\(ordinalSQL))" : nil
        drop = "DROP \(target.type == .mysql ? "TEMPORARY " : "")TABLE \(stage)"
        let identity = target.type == .postgresql && item.targetColumns.contains { column in
            columns.contains { $0.name == column.name } && column.extra.contains("IDENTITY")
        } ? " OVERRIDING SYSTEM VALUE" : ""
        prefix = "INSERT INTO \(table) (\(fields))\(identity) SELECT \(fields) FROM \(stage) WHERE "
        suffix = try TransferSQL.conflictClause(columns: columns, keys: item.primaryKey, type: target.type, strategy: .upsert)
    }

    func merge(offset: Int, count: Int) -> String {
        prefix + "\(ordinalSQL) > \(offset) AND \(ordinalSQL) <= \(offset + count) ORDER BY \(ordinalSQL)" + suffix
    }
}
