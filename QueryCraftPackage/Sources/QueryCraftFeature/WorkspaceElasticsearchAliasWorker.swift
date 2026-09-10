import CoreFoundation
import Foundation

actor WorkspaceElasticsearchAliasWorker {
    enum ReadPurpose { case baseline, verification }

    func readRequest(_ selection: WorkspaceDatabaseObjectSelection) throws -> WorkspaceRequest {
        let path = try WorkspaceElasticsearchIndexName.encodedPath(selection.objectName)
        switch selection.kind {
        case .elasticsearchIndex:
            return .init(method: .get, path: path + "/_alias?expand_wildcards=all")
        case .elasticsearchAlias:
            return .init(method: .get, path: "/_alias" + path + "?expand_wildcards=all")
        default:
            throw WorkspaceElasticsearchAliasError.unsupportedResource
        }
    }

    func load(
        _ selection: WorkspaceDatabaseObjectSelection,
        execute: @Sendable (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult
    ) async throws -> WorkspaceElasticsearchAliasSnapshot {
        let response = try await execute(readRequest(selection))
        return try snapshot(selection: selection, response: response, purpose: .baseline)
    }

    func snapshot(
        selection: WorkspaceDatabaseObjectSelection,
        response: WorkspaceRequestExecutionResult,
        purpose: ReadPurpose
    ) throws -> WorkspaceElasticsearchAliasSnapshot {
        try Task.checkCancellation()
        if response.statusCode == 404, selection.kind == .elasticsearchAlias {
            return .init(selection: selection, bindings: [], rawJSON: response.body)
        }
        guard (200..<300).contains(response.statusCode),
              let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else {
            throw WorkspaceElasticsearchAliasNotSentError(message: responseText(response))
        }
        var bindings: [WorkspaceElasticsearchAliasBinding] = []
        for indexName in root.keys.sorted() {
            try Task.checkCancellation()
            guard let index = root[indexName] as? [String: Any],
                  let aliases = index["aliases"] as? [String: Any]
            else { throw WorkspaceElasticsearchAliasError.unsupportedResource }
            for aliasName in aliases.keys.sorted() {
                guard selection.kind != .elasticsearchAlias || aliasName == selection.objectName,
                      selection.kind != .elasticsearchIndex || indexName == selection.objectName,
                      let rawOptions = aliases[aliasName] as? [String: Any]
                else { continue }
                var options = rawOptions
                let writeIndex = options.removeValue(forKey: "is_write_index").flatMap(Self.boolean)
                let optionsJSON = try JSONSerialization.data(withJSONObject: options, options: [.sortedKeys, .withoutEscapingSlashes])
                bindings.append(.init(indexName: indexName, aliasName: aliasName,
                    isWriteIndex: writeIndex, optionsJSON: optionsJSON))
            }
        }
        return .init(selection: selection, bindings: Self.sorted(bindings), rawJSON: response.body)
    }

    func rows(_ snapshot: WorkspaceElasticsearchAliasSnapshot,
              preserving previous: [WorkspaceElasticsearchAliasEditorRow] = []) -> [WorkspaceElasticsearchAliasEditorRow] {
        let identities = Dictionary(uniqueKeysWithValues: previous.map { ($0.binding.key, $0.id) })
        return snapshot.bindings.map { binding in
            .init(id: identities[binding.key] ?? UUID(), original: binding, binding: binding, isRemoved: false)
        }
    }

    func prepare(snapshot: WorkspaceElasticsearchAliasSnapshot,
                 rows: [WorkspaceElasticsearchAliasEditorRow]) throws -> WorkspacePreparedElasticsearchAliasUpdate {
        try Task.checkCancellation()
        guard [.elasticsearchIndex, .elasticsearchAlias].contains(snapshot.selection.kind) else {
            throw WorkspaceElasticsearchAliasError.unsupportedResource
        }
        let desired = Self.sorted(rows.filter { !$0.isRemoved }.map(\.binding))
        guard Set(desired.map(\.key)).count == desired.count else {
            throw WorkspaceElasticsearchAliasError.duplicateBinding
        }
        for binding in desired {
            _ = try WorkspaceElasticsearchIndexName.encodedPath(binding.indexName)
            _ = try WorkspaceElasticsearchIndexName.encodedPath(binding.aliasName)
            guard snapshot.selection.kind != .elasticsearchIndex || binding.indexName == snapshot.selection.objectName,
                  snapshot.selection.kind != .elasticsearchAlias || binding.aliasName == snapshot.selection.objectName
            else { throw WorkspaceElasticsearchAliasError.invalidName }
        }
        let baseline = Dictionary(uniqueKeysWithValues: snapshot.bindings.map { ($0.key, $0) })
        let updated = Dictionary(uniqueKeysWithValues: desired.map { ($0.key, $0) })
        var actions: [[String: Any]] = []
        for binding in snapshot.bindings {
            try Task.checkCancellation()
            guard let replacement = updated[binding.key] else {
                actions.append(["remove": ["index": binding.indexName, "alias": binding.aliasName]])
                continue
            }
            if replacement != binding { actions.append(["add": try addObject(replacement)]) }
        }
        for binding in desired where baseline[binding.key] == nil {
            try Task.checkCancellation()
            actions.append(["add": try addObject(binding)])
        }
        guard !actions.isEmpty else { throw WorkspaceElasticsearchAliasError.noChanges }
        let body = try JSONSerialization.data(withJSONObject: ["actions": actions],
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        let request = WorkspaceRequest(method: .post, path: "/_aliases", body: body)
        try WorkspaceRequestClassifier.validate(request, policy: .writesAllowed)
        return .init(baseline: snapshot, desiredBindings: desired, request: request)
    }

    func validatePrepared(_ prepared: WorkspacePreparedElasticsearchAliasUpdate) throws {
        let rows = prepared.desiredBindings.map {
            WorkspaceElasticsearchAliasEditorRow(id: UUID(), original: nil, binding: $0, isRemoved: false)
        }
        let expected = try prepare(snapshot: prepared.baseline, rows: rows)
        guard expected.request == prepared.request,
              expected.desiredBindings == prepared.desiredBindings else {
            throw WorkspaceElasticsearchAliasError.conflict
        }
    }

    func validateBaseline(_ prepared: WorkspacePreparedElasticsearchAliasUpdate,
                          response: WorkspaceRequestExecutionResult) throws {
        let current = try snapshot(selection: prepared.baseline.selection, response: response, purpose: .baseline)
        guard current.bindings == prepared.baseline.bindings else {
            throw WorkspaceElasticsearchAliasError.conflict
        }
    }

    func matches(_ prepared: WorkspacePreparedElasticsearchAliasUpdate,
                 response: WorkspaceRequestExecutionResult) throws -> Bool {
        let current = try snapshot(selection: prepared.baseline.selection, response: response, purpose: .verification)
        return current.bindings == prepared.desiredBindings
    }

    func acknowledged(_ response: WorkspaceRequestExecutionResult) -> Bool {
        guard (200..<300).contains(response.statusCode),
              let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        else { return false }
        return root["acknowledged"] as? Bool == true
    }

    func responseText(_ response: WorkspaceRequestExecutionResult) -> String {
        "HTTP \(response.statusCode)\n" + String(decoding: response.body, as: UTF8.self)
    }

    private func addObject(_ binding: WorkspaceElasticsearchAliasBinding) throws -> [String: Any] {
        guard var options = try JSONSerialization.jsonObject(with: binding.optionsJSON) as? [String: Any] else {
            throw WorkspaceElasticsearchAliasError.conflict
        }
        options["index"] = binding.indexName
        options["alias"] = binding.aliasName
        if let isWriteIndex = binding.isWriteIndex { options["is_write_index"] = isWriteIndex }
        return options
    }

    private static func boolean(_ value: Any) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue }
        return nil
    }

    private static func sorted(_ bindings: [WorkspaceElasticsearchAliasBinding]) -> [WorkspaceElasticsearchAliasBinding] {
        bindings.sorted {
            $0.aliasName == $1.aliasName
                ? $0.indexName.localizedStandardCompare($1.indexName) == .orderedAscending
                : $0.aliasName.localizedStandardCompare($1.aliasName) == .orderedAscending
        }
    }
}
