import Foundation

struct WorkspaceElasticsearchIndexTemplateSnapshot: Equatable, Identifiable, Sendable {
    let name: String
    let source: String
    let canonicalBody: Data
    let indexPatterns: [String]
    let priority: Int?
    let isDataStream: Bool

    var id: String { name }
}

struct WorkspaceElasticsearchIndexTemplateInput: Equatable, Sendable {
    var name = ""
    var source = ""
}

enum WorkspaceElasticsearchIndexTemplateOperation: Equatable, Sendable {
    case save
    case delete
}

struct WorkspacePreparedElasticsearchIndexTemplateMutation: Equatable, Sendable {
    let operation: WorkspaceElasticsearchIndexTemplateOperation
    let input: WorkspaceElasticsearchIndexTemplateInput
    let baseline: WorkspaceElasticsearchIndexTemplateSnapshot?
    let request: WorkspaceRequest

    var verificationRequest: WorkspaceRequest {
        .init(method: .get, path: request.path)
    }
}

enum WorkspaceElasticsearchIndexTemplateError: LocalizedError {
    case invalidName
    case invalidBody
    case noChanges
    case conflict
    case pendingChanges
    case unsupportedResponse
    case uncertain

    var errorDescription: String? { message(copy: .current) }

    func message(copy: AppCopy) -> String {
        switch self {
        case .invalidName:
            copy.text(
                "请输入有效的模板名称；不能包含空白、路径、逗号或通配符。",
                "Enter a valid template name without whitespace, paths, commas, or wildcards."
            )
        case .invalidBody:
            copy.text(
                "模板内容必须是非空的 JSON 对象。",
                "The template body must be a nonempty JSON object."
            )
        case .noChanges:
            copy.text("模板没有更改。", "The template has no changes.")
        case .conflict:
            copy.text(
                "模板已在服务器上发生变化。未发送请求，请重新加载后核对。",
                "The template changed on the server. No request was sent; reload and review it."
            )
        case .pendingChanges:
            copy.text(
                "工作区有未提交的文档、Mapping、索引设置或 Alias 更改。请先提交或放弃。",
                "The workspace has pending document, Mapping, index-setting, or Alias changes. Commit or discard them first."
            )
        case .unsupportedResponse:
            copy.text("服务器返回了无法识别的模板响应。", "The server returned an unrecognized template response.")
        case .uncertain:
            copy.text(
                "请求结果未确认。已重新读取模板列表；不会自动重试。",
                "The request outcome is unconfirmed. The template list was reloaded; no automatic retry occurred."
            )
        }
    }
}

struct WorkspaceElasticsearchIndexTemplateNotSentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor WorkspaceElasticsearchIndexTemplateWorker {
    enum Outcome: Equatable, Sendable {
        case acknowledged
        case rejected
        case uncertain
    }

    var listRequest: WorkspaceRequest {
        .init(method: .get, path: "/_index_template")
    }

    func templates(from response: WorkspaceRequestExecutionResult) throws
        -> [WorkspaceElasticsearchIndexTemplateSnapshot]
    {
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode),
              let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let rows = root["index_templates"] as? [[String: Any]]
        else { throw WorkspaceElasticsearchIndexTemplateError.unsupportedResponse }

        var templates: [WorkspaceElasticsearchIndexTemplateSnapshot] = []
        templates.reserveCapacity(rows.count)
        for row in rows {
            try Task.checkCancellation()
            guard let name = row["name"] as? String,
                  let body = row["index_template"] as? [String: Any]
            else { throw WorkspaceElasticsearchIndexTemplateError.unsupportedResponse }
            templates.append(try snapshot(name: name, body: body))
        }
        return templates.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func template(
        named name: String,
        from response: WorkspaceRequestExecutionResult
    ) throws -> WorkspaceElasticsearchIndexTemplateSnapshot? {
        try Task.checkCancellation()
        if response.statusCode == 404 { return nil }
        let templates = try templates(from: response)
        guard templates.count == 1, templates[0].name == name else {
            throw WorkspaceElasticsearchIndexTemplateError.unsupportedResponse
        }
        return templates[0]
    }

    func prepareSave(
        input: WorkspaceElasticsearchIndexTemplateInput,
        baseline: WorkspaceElasticsearchIndexTemplateSnapshot?
    ) throws -> WorkspacePreparedElasticsearchIndexTemplateMutation {
        try Task.checkCancellation()
        let path = try encodedPath(input.name)
        let sourceData = Data(input.source.utf8)
        let canonical = try canonicalBody(sourceData)
        if let baseline, baseline.name == input.name,
           baseline.canonicalBody == canonical {
            throw WorkspaceElasticsearchIndexTemplateError.noChanges
        }
        let request = WorkspaceRequest(method: .put, path: path, body: sourceData)
        try WorkspaceRequestClassifier.validate(request, policy: .writesAllowed)
        return .init(operation: .save, input: input, baseline: baseline, request: request)
    }

    func prepareDeletion(
        _ baseline: WorkspaceElasticsearchIndexTemplateSnapshot
    ) throws -> WorkspacePreparedElasticsearchIndexTemplateMutation {
        try Task.checkCancellation()
        let request = WorkspaceRequest(method: .delete, path: try encodedPath(baseline.name))
        try WorkspaceRequestClassifier.validate(request, policy: .writesAllowed)
        return .init(
            operation: .delete,
            input: .init(name: baseline.name, source: baseline.source),
            baseline: baseline,
            request: request
        )
    }

    func validatePrepared(
        _ prepared: WorkspacePreparedElasticsearchIndexTemplateMutation
    ) throws {
        let expected: WorkspacePreparedElasticsearchIndexTemplateMutation
        switch prepared.operation {
        case .save:
            expected = try prepareSave(input: prepared.input, baseline: prepared.baseline)
        case .delete:
            guard let baseline = prepared.baseline else {
                throw WorkspaceElasticsearchIndexTemplateError.conflict
            }
            expected = try prepareDeletion(baseline)
        }
        guard expected == prepared else {
            throw WorkspaceElasticsearchIndexTemplateError.conflict
        }
    }

    func validateBaseline(
        _ prepared: WorkspacePreparedElasticsearchIndexTemplateMutation,
        response: WorkspaceRequestExecutionResult
    ) throws {
        let current = try template(named: prepared.input.name, from: response)
        switch (prepared.baseline, current) {
        case (nil, nil):
            return
        case let (baseline?, current?) where baseline.canonicalBody == current.canonicalBody:
            return
        default:
            throw WorkspaceElasticsearchIndexTemplateError.conflict
        }
    }

    func outcome(_ response: WorkspaceRequestExecutionResult) -> Outcome {
        if response.statusCode == 408 || response.statusCode >= 500 { return .uncertain }
        guard (200..<300).contains(response.statusCode),
              let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let acknowledged = root["acknowledged"] as? Bool
        else { return .rejected }
        return acknowledged ? .acknowledged : .uncertain
    }

    func formatted(_ source: String) throws -> String {
        let data = Data(source.utf8)
        _ = try canonicalBody(data)
        let object = try JSONSerialization.jsonObject(with: data)
        let formatted = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        return String(decoding: formatted, as: UTF8.self)
    }

    func bodyMatches(
        _ snapshot: WorkspaceElasticsearchIndexTemplateSnapshot,
        input: WorkspaceElasticsearchIndexTemplateInput
    ) throws -> Bool {
        guard snapshot.name == input.name else { return false }
        return snapshot.canonicalBody == (try canonicalBody(Data(input.source.utf8)))
    }

    func responseText(_ response: WorkspaceRequestExecutionResult) -> String {
        "HTTP \(response.statusCode)\n" + String(decoding: response.body, as: UTF8.self)
    }

    private func snapshot(name: String, body: [String: Any]) throws
        -> WorkspaceElasticsearchIndexTemplateSnapshot
    {
        let canonical = try JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let formatted = try JSONSerialization.data(
            withJSONObject: body,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        let patterns = body["index_patterns"] as? [String] ?? []
        let priority = (body["priority"] as? NSNumber)?.intValue
        return .init(
            name: name,
            source: String(decoding: formatted, as: UTF8.self),
            canonicalBody: canonical,
            indexPatterns: patterns,
            priority: priority,
            isDataStream: body["data_stream"] is [String: Any]
        )
    }

    private func canonicalBody(_ data: Data) throws -> Data {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any]
        else { throw WorkspaceElasticsearchIndexTemplateError.invalidBody }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func encodedPath(_ name: String) throws -> String {
        let forbidden = CharacterSet(charactersIn: "\\/*?,#")
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        guard !name.isEmpty, name.utf8.count <= 255,
              name.rangeOfCharacter(from: forbidden) == nil else {
            throw WorkspaceElasticsearchIndexTemplateError.invalidName
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw WorkspaceElasticsearchIndexTemplateError.invalidName
        }
        return "/_index_template/" + encoded
    }
}
