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
}
