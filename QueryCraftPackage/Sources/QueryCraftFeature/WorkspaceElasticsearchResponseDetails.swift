import CoreFoundation
import Foundation

struct WorkspaceElasticsearchResponseDetails: Sendable {
    let fullResponse: String
    let totalHits: String?
    let totalIsLowerBound: Bool
    let returnedHits: Int?
    let displayedRows: Int?
    let tookMilliseconds: String?
    let timedOut: Bool?
    let totalShards: Int?
    let successfulShards: Int?
    let skippedShards: Int?
    let failedShards: Int?
    let hasAggregations: Bool
    let diagnostics: [WorkspaceElasticsearchConsoleDiagnostic]
    let failureMessage: String?
    let acceptedTask: String?

    var prefersJSON: Bool { hasAggregations && returnedHits == 0 }

    func summary(copy: AppCopy) -> String {
        var parts: [String] = []
        if let totalHits {
            let count = (totalIsLowerBound ? "≥ " : "") + totalHits
            parts.append(copy.text("命中 \(count)", "Hits \(count)"))
        }
        if let returnedHits { parts.append(copy.text("返回 \(returnedHits)", "Returned \(returnedHits)")) }
        if let displayedRows, displayedRows != returnedHits {
            parts.append(copy.text("表格 \(displayedRows)", "Grid \(displayedRows)"))
        }
        if let tookMilliseconds { parts.append("ES \(tookMilliseconds) ms") }
        return parts.joined(separator: " · ")
    }

    static func read(response: WorkspaceRequestExecutionResult, displayedRows: Int?,
                     parsed: ElasticsearchConsoleParsedRequest?, source: String?) throws -> Self {
        try Task.checkCancellation()
        let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        let hits = root["hits"] as? [String: Any]
        let total = hits?["total"] as? [String: Any]
        let shards = root["_shards"] as? [String: Any]
        let timedOut = root["timed_out"] as? Bool
        let failedShards = integer(shards?["failed"])
        let failures = root["failures"] as? [Any] ?? []
        let responses = root["responses"] as? [[String: Any]] ?? []
        var responseFailed = false
        for (index, item) in responses.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if integer(item["status"]).map({ $0 >= 400 }) == true || item["error"] != nil {
                responseFailed = true
            }
        }
        var errors: [Any] = []
        if let error = root["error"] { errors.append(error) }
        errors.append(contentsOf: failures.prefix(16))
        errors.append(contentsOf: (shards?["failures"] as? [Any] ?? []).prefix(16))
        for item in responses.prefix(16) {
            if let error = item["error"] { errors.append(error) }
        }
        for item in (root["items"] as? [[String: Any]] ?? []).prefix(16) {
            for operation in item.values {
                if let error = (operation as? [String: Any])?["error"] { errors.append(error) }
            }
        }
        // NDJSON sub-response line numbers describe a subrequest, not the full
        // console body. Keep their error text but never guess an editor location.
        let canLocate = parsed.map {
            let path = URLComponents(string: $0.request.path)?.path ?? ""
            return !WorkspaceRequestClassifier.isNDJSON(path: path)
                && !path.hasPrefix("/_sql") && !path.hasSuffix("/_eql/search")
        } ?? false
        let diagnostics = try WorkspaceElasticsearchConsoleDiagnostic.extract(
            errors, parsed: canLocate ? parsed : nil, source: canLocate ? source : nil)
        let copy = AppCopy.current
        let failure: String?
        if !(200..<300).contains(response.statusCode) {
            failure = (diagnostics.first(where: { $0.documentRange != nil }) ?? diagnostics.last).map { "HTTP \(response.statusCode) · \($0.message)" }
                ?? "HTTP \(response.statusCode)"
        } else if let failedShards, failedShards > 0 {
            failure = copy.text("\(failedShards) 个分片失败，结果可能不完整。", "\(failedShards) shards failed; results may be incomplete.")
        } else if timedOut == true {
            failure = copy.text("查询超时，结果可能不完整。", "Query timed out; results may be incomplete.")
        } else if root["errors"] as? Bool == true || !failures.isEmpty || responseFailed {
            failure = copy.text("部分操作失败；后续请求未执行。", "Some operations failed; remaining requests were not executed.")
        } else if root["acknowledged"] as? Bool == false {
            failure = copy.text("确认超时，请检查服务器状态。", "Acknowledgement timed out. Check server state.")
        } else { failure = nil }
        try Task.checkCancellation()
        return .init(fullResponse: String(decoding: response.body, as: UTF8.self),
            totalHits: number(total?["value"] ?? hits?["total"]),
            totalIsLowerBound: total?["relation"] as? String == "gte",
            returnedHits: (hits?["hits"] as? [Any])?.count, displayedRows: displayedRows,
            tookMilliseconds: number(root["took"]), timedOut: timedOut,
            totalShards: integer(shards?["total"]), successfulShards: integer(shards?["successful"]),
            skippedShards: integer(shards?["skipped"]), failedShards: failedShards,
            hasAggregations: root["aggregations"] != nil || root["aggs"] != nil,
            diagnostics: diagnostics, failureMessage: failure, acceptedTask: root["task"] as? String)
    }

    private static func number(_ value: Any?) -> String? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.stringValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = number(value) else { return nil }
        return Int(value)
    }
}
