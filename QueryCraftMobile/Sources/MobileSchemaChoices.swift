import QueryCraftMobileCore
import QueryCraftMobileTransport

enum MobileSchemaChoices {
    static func load(_ client: any MobileMutationConnection, includeEngines: Bool = false) async throws -> WorkspaceDatabaseSchemaChoices {
        let engines: [String]
        if includeEngines {
            let rows = try await client.query("SHOW ENGINES", bindings: []).dictionaryRows
            engines = rows.compactMap { row in
                guard let name = row["Engine"] ?? nil, (row["Support"] ?? nil) != "NO" else { return nil }
                return name
            }
        } else { engines = [] }
        let charset = try await client.query("SHOW CHARACTER SET", bindings: [])
        let collation = try await client.query("SHOW COLLATION", bindings: [])
        return .init(engines: engines, characterSets: charset.dictionaryRows.compactMap { $0["Charset"] ?? nil },
            collations: collation.dictionaryRows.compactMap { row in
                guard let name = row["Collation"] ?? nil, let characterSet = row["Charset"] ?? nil else { return nil }
                return .init(name: name, characterSet: characterSet, isDefault: (row["Default"] ?? nil) == "Yes")
            })
    }
}
