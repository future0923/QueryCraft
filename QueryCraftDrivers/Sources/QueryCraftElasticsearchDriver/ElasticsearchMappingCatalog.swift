import Foundation
import QueryCraftFeature

struct ElasticsearchMappingCatalog: Sendable {
    let fields: [WorkspaceDocumentMappingField]

    var byPath: [String: WorkspaceDocumentMappingField] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.path, $0) })
    }

    static func parse(mappingData: Data, fieldCapsData: Data) throws -> Self {
        guard let mappings = try JSONSerialization.jsonObject(
            with: mappingData
        ) as? [String: Any],
        let capsRoot = try JSONSerialization.jsonObject(
            with: fieldCapsData
        ) as? [String: Any]
        else {
            throw ElasticsearchError.invalidResponse
        }

        var mappedTypes: [String: Set<String>] = [:]
        var keywordPaths: [String: String] = [:]
        for value in mappings.values {
            guard let index = value as? [String: Any],
                  let mapping = index["mappings"] as? [String: Any]
            else { continue }
            flattenProperties(
                mapping["properties"] as? [String: Any] ?? [:],
                prefix: "",
                mappedTypes: &mappedTypes,
                keywordPaths: &keywordPaths
            )
        }

        let caps = capsRoot["fields"] as? [String: Any] ?? [:]
        let sourceFieldCaps = caps.keys.filter { !$0.hasPrefix("_") }
        let paths = Set(mappedTypes.keys).union(sourceFieldCaps).sorted()
        let fields = paths.map { path -> WorkspaceDocumentMappingField in
            let typeCaps = caps[path] as? [String: Any] ?? [:]
            let capTypes = Set(typeCaps.keys)
            let allTypes = mappedTypes[path, default: []].union(capTypes)
            let conflict = allTypes.count > 1
                || typeCaps.values.contains { value in
                    ((value as? [String: Any])?["type_conflicts"] as? Bool)
                        == true
                }
            let type = allTypes.sorted().joined(separator: " | ")
            let searchable = typeCaps.values.contains {
                (($0 as? [String: Any])?["searchable"] as? Bool) == true
            }
            let aggregatable = typeCaps.values.contains {
                (($0 as? [String: Any])?["aggregatable"] as? Bool) == true
            }
            let indexed = typeCaps.isEmpty ? true : searchable
            return WorkspaceDocumentMappingField(
                path: path,
                type: type.isEmpty ? "unknown" : type,
                isIndexed: indexed,
                isSearchable: searchable,
                isAggregatable: aggregatable,
                hasTypeConflict: conflict,
                keywordSubfieldPath: keywordPaths[path]
            )
        }
        return Self(fields: fields)
    }

    private static func flattenProperties(
        _ properties: [String: Any],
        prefix: String,
        mappedTypes: inout [String: Set<String>],
        keywordPaths: inout [String: String]
    ) {
        for name in properties.keys.sorted() {
            guard let definition = properties[name] as? [String: Any] else {
                continue
            }
            let path = prefix.isEmpty ? name : "\(prefix).\(name)"
            if let type = definition["type"] as? String {
                mappedTypes[path, default: []].insert(type)
            } else if definition["properties"] != nil {
                mappedTypes[path, default: []].insert("object")
            }
            if let fields = definition["fields"] as? [String: Any] {
                for (subfield, value) in fields {
                    guard let subdefinition = value as? [String: Any],
                          let type = subdefinition["type"] as? String
                    else { continue }
                    let subpath = "\(path).\(subfield)"
                    mappedTypes[subpath, default: []].insert(type)
                    if type == "keyword", keywordPaths[path] == nil {
                        keywordPaths[path] = subpath
                    }
                }
            }
            flattenProperties(
                definition["properties"] as? [String: Any] ?? [:],
                prefix: path,
                mappedTypes: &mappedTypes,
                keywordPaths: &keywordPaths
            )
        }
    }
}
