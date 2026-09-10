import Foundation

struct WorkspaceElasticsearchTemplateSimulationResult: Equatable, Sendable {
    let indexName: String
    let matchedTemplates: [String]
    let hasTemplate: Bool
    let settings: String
    let mappings: String
    let aliases: String
    let response: String
    let error: String?
}

actor WorkspaceElasticsearchTemplateSimulationWorker {
    func request(indexName: String) throws -> WorkspaceRequest {
        // A concrete future index name, never a URL, path, pattern or date-math expression.
        let forbidden = CharacterSet(charactersIn: "\\/*?\"<>| ,#:").union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        guard !indexName.isEmpty, indexName.utf8.count <= 255,
              indexName == indexName.lowercased(), indexName != ".", indexName != "..",
              !["-", "_", "+"].contains(indexName.prefix(1)),
              indexName.rangeOfCharacter(from: forbidden) == nil,
              let encoded = indexName.addingPercentEncoding(withAllowedCharacters:
                .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else {
            throw SimulationError.invalidName
        }
        return .init(method: .post, path: "/_index_template/_simulate_index/" + encoded)
    }

    func result(indexName: String, response: WorkspaceRequestExecutionResult,
                templates: WorkspaceRequestExecutionResult) throws -> WorkspaceElasticsearchTemplateSimulationResult {
        try Task.checkCancellation()
        let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let responseText = try root.map(pretty) ?? String(decoding: response.body, as: UTF8.self)
        if !(200..<300).contains(response.statusCode) {
            return .init(indexName: indexName, matchedTemplates: [], hasTemplate: false,
                settings: "{}", mappings: "{}", aliases: "{}", response: responseText,
                error: AppCopy.current.text("模拟请求失败（HTTP \(response.statusCode)）。请查看完整响应。",
                    "Simulation failed (HTTP \(response.statusCode)). See the full response."))
        }
        guard let root else { throw SimulationError.invalidResponse }
        let template = root["template"] as? [String: Any]
        guard root.isEmpty || template != nil else { throw SimulationError.invalidResponse }
        guard (200..<300).contains(templates.statusCode),
              let catalog = try? JSONSerialization.jsonObject(with: templates.body) as? [String: Any],
              let rows = catalog["index_templates"] as? [[String: Any]] ?? (catalog.isEmpty ? [] : nil) else {
            throw SimulationError.catalogUnavailable
        }
        var matches: [(name: String, priority: Int)] = []
        for row in rows {
            try Task.checkCancellation()
            guard let name = row["name"] as? String,
                  let body = row["index_template"] as? [String: Any],
                  let patterns = body["index_patterns"] as? [String] else { throw SimulationError.invalidResponse }
            if try patterns.contains(where: { try matchesPattern($0, name: indexName) }) {
                matches.append((name, (body["priority"] as? NSNumber)?.intValue ?? 0))
            }
        }
        matches.sort { $0.priority == $1.priority ? $0.name < $1.name : $0.priority > $1.priority }
        try Task.checkCancellation()
        return .init(indexName: indexName, matchedTemplates: matches.map(\.name), hasTemplate: template != nil,
            settings: try pretty(template?["settings"] ?? [:]), mappings: try pretty(template?["mappings"] ?? [:]),
            aliases: try pretty(template?["aliases"] ?? [:]), response: responseText, error: nil)
    }

    private func pretty(_ object: Any) throws -> String {
        try Task.checkCancellation()
        if let dictionary = object as? [String: Any], dictionary.isEmpty { return "{}" }
        return String(decoding: try JSONSerialization.data(withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    // Elasticsearch index_patterns uses simple '*' wildcard matching, not regex.
    private func matchesPattern(_ pattern: String, name: String) throws -> Bool {
        let pattern = Array(pattern.utf8), name = Array(name.utf8)
        var p = 0, n = 0, star: Int?, restart = 0, iterations = 0
        while n < name.count {
            iterations += 1
            if iterations.isMultiple(of: 128) { try Task.checkCancellation() }
            if p < pattern.count, pattern[p] == 42 {
                star = p; p += 1; restart = n
            } else if p < pattern.count, pattern[p] == name[n] {
                p += 1; n += 1
            } else if let star {
                restart += 1; n = restart; p = star + 1
            } else { return false }
        }
        while p < pattern.count, pattern[p] == 42 { p += 1 }
        return p == pattern.count
    }
}

private enum SimulationError: LocalizedError {
    case invalidName, invalidResponse, catalogUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidName:
            AppCopy.current.text("请输入有效的小写索引名称，不含路径、空格或通配符，且不超过 255 字节。",
                "Enter a valid lowercase index name without paths, spaces or wildcards, up to 255 bytes.")
        case .invalidResponse:
            AppCopy.current.text("服务器返回了无法识别的模板模拟结果。", "The server returned an unrecognized template simulation result.")
        case .catalogUnavailable:
            AppCopy.current.text("无法读取模板列表，请确认当前账户具有读取索引模板的权限。",
                "Unable to read index templates. Check that the account can read index templates.")
        }
    }
}
