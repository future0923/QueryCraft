import Foundation

struct WorkspaceIndexSettingsSnapshot: Equatable, Sendable {
    struct Index: Equatable, Sendable {
        let name: String
        let settings: [String: String]
        let defaults: [String: String]
        func effective(_ key: String) -> String? { settings[key] ?? defaults[key] }
    }
    let selection: WorkspaceDatabaseObjectSelection
    let indices: [Index]
    let documentCount: Int64?
    let storeBytes: Int64?
    let health: String?
    let warnings: [String]
    /// Complete server response, including arrays, unknown settings and defaults.
    /// Never reconstruct this from the scalar summary used by the inspector.
    let rawJSON: Data

    var editableIndex: Index? {
        guard selection.kind == .elasticsearchIndex, !selection.objectName.hasPrefix(".ds-"),
              indices.count == 1, indices[0].name == selection.objectName,
              indices[0].settings["index.uuid"] != nil else { return nil }
        return indices[0]
    }
}

struct WorkspacePreparedIndexSettings: Equatable, Sendable {
    let baseline: WorkspaceIndexSettingsSnapshot
    let changes: [String: String]
    let request: WorkspaceRequest
}

enum WorkspaceIndexSettingsError: LocalizedError {
    case unavailable, invalidReplicas, invalidInterval, conflict, uncertain
    var errorDescription: String? { message(copy: .current) }
    func message(copy: AppCopy) -> String {
        switch self {
        case .unavailable: copy.text("无法编辑此资源的索引设置。仅支持已核对的普通索引。", "Settings can only be edited for a verified ordinary index.")
        case .invalidReplicas: copy.text("副本数必须是非负整数。", "Replicas must be a nonnegative integer.")
        case .invalidInterval: copy.text("刷新间隔请输入 -1、0 或带单位的非负整数，例如 1s、500ms、1m。", "Enter -1, 0, or a nonnegative integer with a time unit, such as 1s, 500ms, or 1m.")
        case .conflict: copy.text("索引或待改设置已被外部修改。草稿已保留，请放弃并刷新后重新核对。", "The index or edited settings changed externally. Your draft is retained; discard and refresh to review the server state.")
        case .uncertain: copy.text("无法确认设置是否生效。草稿已保留，禁止直接重试；请放弃并刷新，核对服务器状态。", "The settings outcome could not be confirmed. Your draft is retained and retry is blocked; discard and refresh to review the server state.")
        }
    }
}

/// A preflight error means the PUT was never sent; transport errors after it are uncertain.
struct WorkspaceIndexSettingsNotSentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor WorkspaceIndexSettingsWorker {
    static let replicasKey = "index.number_of_replicas"
    static let intervalKey = "index.refresh_interval"

    func settingsRequest(_ selection: WorkspaceDatabaseObjectSelection) throws -> WorkspaceRequest {
        .init(method: .get, path: try WorkspaceElasticsearchIndexName.encodedPath(selection.objectName)
            + "/_settings?flat_settings=true&include_defaults=true")
    }

    func load(_ selection: WorkspaceDatabaseObjectSelection,
              execute: @Sendable (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult) async throws -> WorkspaceIndexSettingsSnapshot {
        let path = try WorkspaceElasticsearchIndexName.encodedPath(selection.objectName)
        let settings = try await execute(settingsRequest(selection))
        let indices = try parseSettings(settings)
        var count: Int64?, bytes: Int64?, health: String?
        var warnings: [String] = []
        // Four bounded metadata requests, never document materialization. An optional
        // metric permission failure must not hide authoritative index settings.
        for (suffix, label) in [("/_count", AppCopy.current.text("文档数", "Documents")),
                                ("/_stats/store?filter_path=_all.total.store.size_in_bytes", AppCopy.current.text("存储大小", "Storage")),
                                ("health", AppCopy.current.text("健康状态", "Health"))] {
            try Task.checkCancellation()
            do {
                let request = WorkspaceRequest(method: .get, path: suffix == "health"
                    ? "/_cluster/health" + path + "?filter_path=status" : path + suffix)
                let root = try object(await execute(request))
                switch suffix {
                case "/_count": count = (root["count"] as? NSNumber)?.int64Value
                case "health": health = root["status"] as? String
                default:
                    let all = root["_all"] as? [String: Any]
                    let total = all?["total"] as? [String: Any]
                    let store = total?["store"] as? [String: Any]
                    bytes = (store?["size_in_bytes"] as? NSNumber)?.int64Value
                }
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append(label + ": " + error.localizedDescription) }
        }
        try Task.checkCancellation()
        return .init(selection: selection, indices: indices, documentCount: count, storeBytes: bytes, health: health, warnings: warnings, rawJSON: settings.body)
    }

    func rawSettingsText(_ snapshot: WorkspaceIndexSettingsSnapshot) throws -> String {
        try Task.checkCancellation()
        return String(decoding: snapshot.rawJSON, as: UTF8.self)
    }

    func consoleSource(_ snapshot: WorkspaceIndexSettingsSnapshot, prepared: WorkspacePreparedIndexSettings? = nil) throws -> String {
        try Task.checkCancellation()
        if let prepared {
            guard prepared.baseline == snapshot else { throw WorkspaceIndexSettingsError.conflict }
            try validatePrepared(prepared)
            return "\(prepared.request.method.rawValue) \(prepared.request.path)\n" + String(decoding: prepared.request.body ?? Data(), as: UTF8.self)
        }
        if let index = snapshot.editableIndex {
            // Do not submit read-only settings (UUID, creation date, etc.) or
            // defaults from a GET response as a write. Start with a minimal body.
            return "PUT " + (try WorkspaceElasticsearchIndexName.encodedPath(index.name)) + "/_settings\n{\n  \"index\": {}\n}"
        }
        let request = try settingsRequest(snapshot.selection)
        return "\(request.method.rawValue) \(request.path)"
    }

    func parseSettings(_ response: WorkspaceRequestExecutionResult) throws -> [WorkspaceIndexSettingsSnapshot.Index] {
        let root = try object(response)
        return try root.keys.sorted().map { name in
            try Task.checkCancellation()
            guard let entry = root[name] as? [String: Any], let settings = entry["settings"] as? [String: Any] else {
                throw WorkspaceIndexSettingsError.unavailable
            }
            func strings(_ object: [String: Any]) -> [String: String] {
                object.reduce(into: [:]) { result, pair in
                    if let value = pair.value as? String { result[pair.key] = value }
                    else if let value = pair.value as? NSNumber { result[pair.key] = value.stringValue }
                }
            }
            return .init(name: name, settings: strings(settings), defaults: strings(entry["defaults"] as? [String: Any] ?? [:]))
        }
    }

    func prepare(_ baseline: WorkspaceIndexSettingsSnapshot, replicas: String, interval: String) throws -> WorkspacePreparedIndexSettings {
        try Task.checkCancellation()
        guard let index = baseline.editableIndex else { throw WorkspaceIndexSettingsError.unavailable }
        guard !replicas.isEmpty, replicas.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(replicas), number >= 0 else { throw WorkspaceIndexSettingsError.invalidReplicas }
        let validInterval = interval == "-1" || interval == "0" || interval.range(of: #"^[0-9]+(nanos|micros|ms|s|m|h|d)\z"#, options: .regularExpression) != nil
        guard validInterval else { throw WorkspaceIndexSettingsError.invalidInterval }
        var changes: [String: String] = [:]
        if String(number) != index.effective(Self.replicasKey) { changes[Self.replicasKey] = String(number) }
        if interval != index.effective(Self.intervalKey) { changes[Self.intervalKey] = interval }
        var body: [String: Any] = [:]
        for (key, value) in changes { body[String(key.dropFirst("index.".count))] = key == Self.replicasKey ? number : value }
        let request = WorkspaceRequest(method: .put, path: try WorkspaceElasticsearchIndexName.encodedPath(index.name) + "/_settings",
            body: try JSONSerialization.data(withJSONObject: ["index": body], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]))
        return .init(baseline: baseline, changes: changes, request: request)
    }

    func validatePrepared(_ prepared: WorkspacePreparedIndexSettings) throws {
        guard let index = prepared.baseline.editableIndex, !prepared.changes.isEmpty else { throw WorkspaceIndexSettingsError.unavailable }
        let expected = try prepare(prepared.baseline,
            replicas: prepared.changes[Self.replicasKey] ?? index.effective(Self.replicasKey) ?? "",
            interval: prepared.changes[Self.intervalKey] ?? index.effective(Self.intervalKey) ?? "")
        guard expected == prepared else { throw WorkspaceIndexSettingsError.unavailable }
    }

    func validateBaseline(_ prepared: WorkspacePreparedIndexSettings, response: WorkspaceRequestExecutionResult) throws {
        let current = try parseSettings(response)
        guard let original = prepared.baseline.editableIndex, current.count == 1, let index = current.first,
              index.name == original.name, index.settings["index.uuid"] == original.settings["index.uuid"],
              prepared.changes.keys.allSatisfy({ index.settings[$0] == original.settings[$0] && index.effective($0) == original.effective($0) })
        else { throw WorkspaceIndexSettingsError.conflict }
        // Settings API has no CAS; this is a preflight check, not atomic protection.
    }

    func matches(_ prepared: WorkspacePreparedIndexSettings, response: WorkspaceRequestExecutionResult) throws -> Bool {
        let current = try parseSettings(response)
        guard let original = prepared.baseline.editableIndex, current.count == 1, let index = current.first,
              index.name == original.name, index.settings["index.uuid"] == original.settings["index.uuid"] else { return false }
        return prepared.changes.allSatisfy { index.effective($0.key) == $0.value }
    }

    func acknowledged(_ response: WorkspaceRequestExecutionResult) -> Bool {
        guard (200..<300).contains(response.statusCode),
              let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else { return false }
        return root["acknowledged"] as? Bool == true
    }
    func responseText(_ response: WorkspaceRequestExecutionResult) -> String {
        "HTTP \(response.statusCode)\n" + String(decoding: response.body, as: UTF8.self)
    }
    private func object(_ response: WorkspaceRequestExecutionResult) throws -> [String: Any] {
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw WorkspaceIndexSettingsNotSentError(message: responseText(response))
        }
        guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw WorkspaceIndexSettingsError.unavailable }
        return root
    }
}
