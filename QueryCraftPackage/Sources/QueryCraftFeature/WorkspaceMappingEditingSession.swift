import Foundation
import CoreFoundation

public struct WorkspaceMappingTarget: Equatable, Sendable {
    public let resource: String
    public let kind: WorkspaceDatabaseObjectKind
    public init(resource: String, kind: WorkspaceDatabaseObjectKind) {
        self.resource = resource; self.kind = kind
    }
}

public struct WorkspaceMappingFieldNode: Equatable, Sendable {
    public let path: [String]
    public let definitionJSON: Data
    public let hasConflict: Bool
    public var name: String { path.last ?? "" }
    public var displayPath: String { path.enumerated().filter { $0.offset % 2 == 1 }.map(\.element).joined(separator: ".") }
    public init(path: [String], definitionJSON: Data, hasConflict: Bool) {
        self.path = path; self.definitionJSON = definitionJSON; self.hasConflict = hasConflict
    }
}

public struct WorkspaceMappingSnapshot: Equatable, Sendable {
    public let target: WorkspaceMappingTarget
    public let indexMappings: [String: Data]
    public let fields: [WorkspaceMappingFieldNode]
    public let rawJSON: Data
    public let fieldCapabilities: [WorkspaceDocumentMappingField]
    public init(target: WorkspaceMappingTarget, indexMappings: [String: Data], fields: [WorkspaceMappingFieldNode], rawJSON: Data, fieldCapabilities: [WorkspaceDocumentMappingField] = []) {
        self.target = target; self.indexMappings = indexMappings; self.fields = fields; self.rawJSON = rawJSON
        self.fieldCapabilities = fieldCapabilities
    }
}

public struct WorkspaceMappingFieldChange: Equatable, Sendable {
    public let path: [String]
    public let definitionJSON: Data
    public let isNew: Bool
    public init(path: [String], definitionJSON: Data, isNew: Bool) {
        self.path = path; self.definitionJSON = definitionJSON; self.isNew = isNew
    }
}

public struct WorkspaceMappingDraft: Equatable, Sendable {
    public let baseline: WorkspaceMappingSnapshot
    public let changes: [WorkspaceMappingFieldChange]
    public init(baseline: WorkspaceMappingSnapshot, changes: [WorkspaceMappingFieldChange]) {
        self.baseline = baseline; self.changes = changes
    }
}

public struct WorkspacePreparedMappingUpdate: Equatable, Sendable {
    public let draft: WorkspaceMappingDraft
    public let request: WorkspaceRequest
    public init(draft: WorkspaceMappingDraft, request: WorkspaceRequest) {
        self.draft = draft; self.request = request
    }
}

public protocol WorkspaceMappingEditingSession: WorkspaceSession {
    func fetchMappingSnapshot(_ target: WorkspaceMappingTarget) async throws -> WorkspaceMappingSnapshot
    func prepareMappingUpdate(_ draft: WorkspaceMappingDraft) async throws -> WorkspacePreparedMappingUpdate
    func commitMappingUpdate(_ prepared: WorkspacePreparedMappingUpdate) async throws -> WorkspaceRequestExecutionResult
}

public enum WorkspaceMappingError: LocalizedError {
    case invalidDraft
    case conflict
    case uncertain
    public var errorDescription: String? {
        switch self {
        case .invalidDraft: AppCopy.current.text("Mapping 草稿无效，请检查字段名、类型、父节点和参数。", "Invalid Mapping draft. Check names, types, parents and parameters.")
        case .conflict: AppCopy.current.text("目标或相关字段已变化。草稿已保留，请重新加载核对后编辑。", "The target or affected fields changed. Your draft is retained; reload and review before editing.")
        case .uncertain: AppCopy.current.text("Mapping 结果尚未确认。请重新加载核对；不要直接重复提交。", "Mapping outcome is not confirmed. Reload and review before submitting again.")
        }
    }
}

/// Pure Mapping transformations; callers run these on their owned worker/session actor.
public enum WorkspaceMappingCodec {
    public static let newTypes = ["text", "keyword", "integer", "long", "float", "double", "boolean", "date", "ip", "object", "nested"]
    public static func editableParameters(type: String, isNew: Bool) -> [String] {
        let numeric = ["byte", "short", "integer", "long", "half_float", "float", "double", "scaled_float", "unsigned_long"].contains(type)
        var keys: [String] = []
        if type == "keyword" { keys += ["ignore_above", "eager_global_ordinals"] }
        if type == "text" { keys += ["eager_global_ordinals"] }
        if numeric { keys += ["coerce", "ignore_malformed"] }
        if type == "date" || type == "ip" { keys += ["ignore_malformed"] }
        if isNew, !["object", "nested"].contains(type) {
            keys += ["index", "store"]
            if type != "text" { keys += ["doc_values"] }
            if type == "text" { keys += ["analyzer"] }
            if type == "keyword" { keys += ["normalizer"] }
            if type == "date" { keys += ["format"] }
        }
        return keys
    }

    public static func snapshot(target: WorkspaceMappingTarget, data: Data, fieldCapabilities: [WorkspaceDocumentMappingField] = []) throws -> WorkspaceMappingSnapshot {
        let root = try object(data)
        var mappings: [String: Data] = [:]
        var definitions: [[String]: [Data]] = [:]
        func walk(_ definition: [String: Any], path: [String]) throws {
            try Task.checkCancellation()
            for container in ["properties", "fields"] {
                for (name, value) in definition[container] as? [String: Any] ?? [:] {
                    guard let field = value as? [String: Any] else { continue }
                    let key = path + [container, name]
                    definitions[key, default: []].append(try json(field))
                    try walk(field, path: key)
                }
            }
        }
        for (index, value) in root {
            guard let mapping = (value as? [String: Any])?["mappings"] as? [String: Any] else { throw WorkspaceMappingError.invalidDraft }
            mappings[index] = try json(mapping)
            try walk(mapping, path: [])
        }
        let fields = definitions.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { path in
            let values = definitions[path]!
            return WorkspaceMappingFieldNode(path: path, definitionJSON: values[0], hasConflict: Set(values).count > 1 || values.count != mappings.count)
        }
        return WorkspaceMappingSnapshot(target: target, indexMappings: mappings, fields: fields, rawJSON: data, fieldCapabilities: fieldCapabilities)
    }

    public static func prepare(_ draft: WorkspaceMappingDraft) throws -> WorkspacePreparedMappingUpdate {
        guard !draft.changes.isEmpty, !draft.baseline.indexMappings.isEmpty,
              [.elasticsearchIndex, .elasticsearchDataStream].contains(draft.baseline.target.kind),
              !draft.baseline.target.resource.isEmpty,
              !draft.baseline.target.resource.contains("*"), !draft.baseline.target.resource.contains(",") else { throw WorkspaceMappingError.invalidDraft }
        var result: [String: Any] = [:]
        var paths = Set<[String]>()
        let fields = Dictionary(uniqueKeysWithValues: draft.baseline.fields.map { ($0.path, $0) })
        for change in draft.changes.sorted(by: { $0.path.count < $1.path.count }) {
            try Task.checkCancellation()
            let path = change.path
            guard !path.isEmpty, path.count % 2 == 0, paths.insert(path).inserted else { throw WorkspaceMappingError.invalidDraft }
            for offset in stride(from: 0, to: path.count, by: 2) {
                guard ["properties", "fields"].contains(path[offset]), !path[offset + 1].isEmpty,
                      !path[offset + 1].contains("."), !path[offset + 1].contains("\n") else { throw WorkspaceMappingError.invalidDraft }
            }
            guard path[0] == "properties" else { throw WorkspaceMappingError.invalidDraft }
            let definition = try object(change.definitionJSON)
            let old = try fields[path].map { try object($0.definitionJSON) }
            let type = definition["type"] as? String ?? old?["type"] as? String ?? (old?["properties"] != nil ? "object" : "")
            guard !type.isEmpty, fields[path]?.hasConflict != true else { throw WorkspaceMappingError.invalidDraft }
            if change.isNew {
                guard old == nil, newTypes.contains(type) else { throw WorkspaceMappingError.invalidDraft }
            } else {
                guard let old, type == (old["type"] as? String ?? "object") else { throw WorkspaceMappingError.invalidDraft }
            }
            if path.count > 2 {
                let parentPath = Array(path.dropLast(2))
                let parent = try fields[parentPath].map { try object($0.definitionJSON) }
                    ?? value(at: parentPath, in: result) as? [String: Any]
                let parentType = parent?["type"] as? String ?? (parent?["properties"] != nil ? "object" : "")
                let container = path[path.count - 2]
                guard container == "fields" ? ["text", "keyword"].contains(parentType) && ["text", "keyword"].contains(type)
                    : ["object", "nested"].contains(parentType) else { throw WorkspaceMappingError.invalidDraft }
            }
            let allowed = Set(editableParameters(type: type, isNew: change.isNew) + ["type"])
            for (key, value) in definition {
                guard allowed.contains(key) else { throw WorkspaceMappingError.invalidDraft }
                if ["type", "analyzer", "normalizer", "format"].contains(key) {
                    guard let text = value as? String, !text.isEmpty else { throw WorkspaceMappingError.invalidDraft }
                } else if key == "ignore_above" {
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue >= 0, number.doubleValue <= Double(Int32.max), number.doubleValue.rounded() == number.doubleValue else { throw WorkspaceMappingError.invalidDraft }
                } else {
                    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw WorkspaceMappingError.invalidDraft }
                }
            }
            var patch = definition
            patch["type"] = type
            set(patch, path: path, in: &result, baseline: fields)
        }
        let target = draft.baseline.target.resource.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
        let request = WorkspaceRequest(method: .put, path: "/\(target)/_mapping", body: try json(result))
        return WorkspacePreparedMappingUpdate(draft: draft, request: request)
    }

    public static func validateBaseline(_ draft: WorkspaceMappingDraft, current: WorkspaceMappingSnapshot) throws {
        guard draft.baseline.target == current.target,
              Set(draft.baseline.indexMappings.keys) == Set(current.indexMappings.keys) else { throw WorkspaceMappingError.conflict }
        for (index, oldData) in draft.baseline.indexMappings {
            let old = try object(oldData)
            let new = try object(current.indexMappings[index]!)
            for change in draft.changes {
                try Task.checkCancellation()
                let oldValue = value(at: change.path, in: old)
                let newValue = value(at: change.path, in: new)
                guard try json(oldValue ?? NSNull()) == json(newValue ?? NSNull()) else { throw WorkspaceMappingError.conflict }
                if change.path.count > 2 {
                    let parentPath = Array(change.path.dropLast(2))
                    let oldType = (value(at: parentPath, in: old) as? [String: Any])?["type"] as? String
                    let newType = (value(at: parentPath, in: new) as? [String: Any])?["type"] as? String
                    guard oldType == newType else { throw WorkspaceMappingError.conflict }
                }
            }
        }
    }

    public static func containsChanges(_ draft: WorkspaceMappingDraft, current: WorkspaceMappingSnapshot) throws -> Bool {
        guard Set(draft.baseline.indexMappings.keys) == Set(current.indexMappings.keys) else { return false }
        for data in current.indexMappings.values {
            let mapping = try object(data)
            for change in draft.changes {
                guard let actual = value(at: change.path, in: mapping) as? [String: Any] else { return false }
                for (key, expected) in try object(change.definitionJSON) {
                    // Elasticsearch omits the explicit object type once properties exist.
                    if key == "type", expected as? String == "object", actual["type"] == nil, actual["properties"] != nil { continue }
                    guard try json(actual[key] ?? NSNull()) == json(expected) else { return false }
                }
            }
        }
        return true
    }

    private static func set(_ value: [String: Any], path: [String], in root: inout [String: Any], baseline: [[String]: WorkspaceMappingFieldNode], prefix: [String] = []) {
        let key = path[0]
        if path.count == 1 {
            var existing = root[key] as? [String: Any] ?? [:]
            existing.merge(value) { _, new in new }; root[key] = existing; return
        }
        var child = root[key] as? [String: Any] ?? [:]
        if let field = baseline[prefix + [key]], let definition = try? object(field.definitionJSON), let type = definition["type"] { child["type"] = type }
        set(value, path: Array(path.dropFirst()), in: &child, baseline: baseline, prefix: prefix + [key])
        root[key] = child
    }
    private static func value(at path: [String], in root: [String: Any]) -> Any? {
        path.reduce(root as Any?) { ($0 as? [String: Any])?[$1] }
    }
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkspaceMappingError.invalidDraft }
        return value
    }
    public static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
}
