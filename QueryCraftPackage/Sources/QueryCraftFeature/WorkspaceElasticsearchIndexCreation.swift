import Foundation

struct WorkspaceElasticsearchIndexInput: Equatable, Sendable {
    var name = ""
    var shards = ""
    var replicas = ""
    var mapping = "{}"
}

struct WorkspacePreparedIndexCreation: Equatable, Sendable {
    let input: WorkspaceElasticsearchIndexInput
    let request: WorkspaceRequest
    var verificationRequest: WorkspaceRequest { .init(method: .head, path: request.path) }
}

enum WorkspaceIndexCreationError: LocalizedError {
    case name, shards, replicas, mapping

    var errorDescription: String? { message(copy: .current) }
    func message(copy: AppCopy) -> String {
        switch self {
        case .name:
            copy.text("请输入有效的小写索引名称（最多 255 字节）；不能包含空白、路径或通配符，也不能以 _、-、+ 开头。",
                      "Enter a valid lowercase index name (up to 255 bytes), without whitespace, paths or wildcards, and not starting with _, - or +.")
        case .shards:
            copy.text("主分片数必须是正整数，留空使用服务器默认值。", "Primary shards must be a positive integer, or empty for the server default.")
        case .replicas:
            copy.text("副本数必须是非负整数，留空使用服务器默认值。", "Replicas must be a nonnegative integer, or empty for the server default.")
        case .mapping:
            copy.text("初始 Mapping 必须是有效的 JSON 对象，例如 {\"properties\":{}}。", "Initial Mapping must be a valid JSON object, such as {\"properties\":{}}.")
        }
    }
}

actor WorkspaceIndexCreationWorker {
    enum Outcome: Sendable {
        case created(waitingForShards: Bool)
        case rejected
        case uncertain
    }

    func prepare(_ input: WorkspaceElasticsearchIndexInput) throws -> WorkspacePreparedIndexCreation {
        try Task.checkCancellation()
        let name = input.name
        let path = try WorkspaceElasticsearchIndexName.encodedPath(name)
        var settings: [String] = []
        if !input.shards.isEmpty {
            guard let count = Int(input.shards), count > 0 else { throw WorkspaceIndexCreationError.shards }
            settings.append("\"number_of_shards\":\(count)")
        }
        if !input.replicas.isEmpty {
            guard let count = Int(input.replicas), count >= 0 else { throw WorkspaceIndexCreationError.replicas }
            settings.append("\"number_of_replicas\":\(count)")
        }
        let mapping = input.mapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = try? JSONSerialization.jsonObject(with: Data(mapping.utf8)),
              object is [String: Any] else { throw WorkspaceIndexCreationError.mapping }
        try Task.checkCancellation()
        // Embed the validated text, without re-encoding user numeric literals,
        // escapes or field order. Unspecified settings belong to the server.
        let members = (settings.isEmpty ? [] : ["\"settings\":{\(settings.joined(separator: ","))}"])
            + ["\"mappings\":\(mapping)"]
        let request = WorkspaceRequest(method: .put, path: path, body: Data(("{" + members.joined(separator: ",") + "}").utf8))
        try WorkspaceRequestClassifier.validate(request, policy: .writesAllowed)
        return WorkspacePreparedIndexCreation(input: input, request: request)
    }

    func outcome(_ response: WorkspaceRequestExecutionResult, name: String) -> Outcome {
        if response.statusCode == 408 || response.statusCode >= 500 { return .uncertain }
        guard (200..<300).contains(response.statusCode) else { return .rejected }
        struct Acknowledgement: Decodable {
            let acknowledged: Bool
            let shards_acknowledged: Bool?
            let index: String?
        }
        guard let acknowledgement = try? JSONDecoder().decode(Acknowledgement.self, from: response.body),
              acknowledgement.acknowledged,
              acknowledgement.index == nil || acknowledgement.index == name else { return .uncertain }
        return .created(waitingForShards: acknowledgement.shards_acknowledged == false)
    }

    func responseText(_ response: WorkspaceRequestExecutionResult) -> String {
        String(decoding: response.body, as: UTF8.self)
    }
}
