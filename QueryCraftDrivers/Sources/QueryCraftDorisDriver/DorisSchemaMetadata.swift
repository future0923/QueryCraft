#if canImport(QueryCraftFeature)
import QueryCraftFeature
#else
import QueryCraftMobileCore
#endif

enum DorisSchemaMetadata {
    static func columns(_ rows: [[String: String?]]) -> [WorkspaceDatabaseColumn] {
        rows.compactMap { row in
            func value(_ key: String) -> String? { row[key] ?? row[key.lowercased()] ?? nil }
            guard let name = value("Field"), let type = value("Type") else { return nil }
            return .init(name: name, type: type, collation: value("Collation"), isNullable: value("Null") == "YES",
                key: value("Key") ?? "", defaultValue: value("Default"), extra: value("Extra") ?? "", comment: value("Comment") ?? "")
        }
    }

    static func indexes(_ rows: [[String: String?]]) -> [WorkspaceDatabaseIndex] {
        var names: [String] = []
        var columns: [String: [WorkspaceDatabaseIndexColumn]] = [:]
        var properties: [String: (Bool, String, String)] = [:]
        for row in rows {
            guard let name = value(in: row, keys: ["Key_name", "KeyName"]),
                  let column = value(in: row, keys: ["Column_name", "Column"])
            else { continue }
            let sequence = value(in: row, keys: ["Seq_in_index", "Seq"])
                .flatMap(Int64.init) ?? Int64(columns[name, default: []].count + 1)
            if properties[name] == nil {
                names.append(name)
                properties[name] = (
                    value(in: row, keys: ["Non_unique"]).flatMap(Int.init) == 0,
                    value(in: row, keys: ["Index_type", "IndexType"]) ?? "",
                    value(in: row, keys: ["Comment", "Index_comment"]) ?? ""
                )
            }
            columns[name, default: []].append(
                WorkspaceDatabaseIndexColumn(
                    sequence: sequence,
                    name: column,
                    prefixLength: nil,
                    direction: nil,
                    isExpression: false
                )
            )
        }
        return names.compactMap { name in
            guard let property = properties[name] else { return nil }
            return WorkspaceDatabaseIndex(
                name: name,
                columns: columns[name, default: []],
                isUnique: property.0,
                isPrimary: name.uppercased() == "PRIMARY",
                type: property.1,
                cardinality: nil,
                isVisible: true,
                comment: property.2
            )
        }
    }

    private static func value(
        in row: [String: String?],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = row[key] ?? nil { return value }
        }
        return nil
    }

}
