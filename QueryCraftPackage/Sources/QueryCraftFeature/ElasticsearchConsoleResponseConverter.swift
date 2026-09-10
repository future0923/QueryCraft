import CoreFoundation
import Foundation

enum WorkspaceElasticsearchConsoleOutput: Sendable {
    case grid(WorkspaceDatabaseDataPage)
    case json(String)
}

enum ElasticsearchConsoleResponseConverter {
    static func output(
        from response: WorkspaceRequestExecutionResult,
        maximumRows: Int
    ) throws -> WorkspaceElasticsearchConsoleOutput {
        try Task.checkCancellation()
        if !(200..<300).contains(response.statusCode) {
            return .json(String(decoding: response.body, as: UTF8.self))
        }
        let root = try JSONSerialization.jsonObject(with: response.body)
        try Task.checkCancellation()
        if let object = root as? [String: Any],
           let hitsObject = object["hits"] as? [String: Any],
           let hits = hitsObject["hits"] as? [[String: Any]]
        {
            let rows = try hits.prefix(max(0, maximumRows)).map { hit -> [String: Any] in
                try Task.checkCancellation()
                var result: [String: Any] = [
                    "_id": hit["_id"] ?? NSNull(),
                    "_index": hit["_index"] ?? NSNull(),
                    "_score": hit["_score"] ?? NSNull(),
                ]
                try flatten(
                    hit["_source"] as? [String: Any] ?? [:],
                    prefix: "",
                    output: &result
                )
                // These hit sections are independent of _source and also work
                // when a request explicitly disables _source.
                for section in ["fields", "highlight"] {
                    if let values = hit[section] as? [String: Any] {
                        for (name, value) in values {
                            try Task.checkCancellation()
                            result["\(section).\(name)"] = value
                        }
                    }
                }
                for section in ["inner_hits", "sort", "_explanation"] {
                    if let value = hit[section] { result[section] = value }
                }
                return result
            }
            return .grid(try makePage(rows: rows))
        }
        if let rows = root as? [[String: Any]] {
            return .grid(try makePage(rows: Array(rows.prefix(max(0, maximumRows)))))
        }
        return .json(try ElasticsearchJSONWhitespaceFormatter.format(response.body))
    }

    private static func makePage(
        rows: [[String: Any]]
    ) throws -> WorkspaceDatabaseDataPage {
        let names = Set(rows.flatMap(\.keys)).sorted { left, right in
            let priority = ["_id", "_index", "_score"]
            let leftPriority = priority.firstIndex(of: left) ?? Int.max
            let rightPriority = priority.firstIndex(of: right) ?? Int.max
            return leftPriority == rightPriority
                ? left.localizedStandardCompare(right) == .orderedAscending
                : leftPriority < rightPriority
        }
        let columns = names.enumerated().map {
            WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element)
        }
        let dataRows = try rows.enumerated().map { rowIndex, row in
            try Task.checkCancellation()
            return WorkspaceDatabaseDataRow(
                id: rowIndex,
                values: names.map { cell(row[$0]) }
            )
        }
        return WorkspaceDatabaseDataPage(
            columns: columns,
            rows: dataRows,
            offset: 0,
            limit: max(dataRows.count, 1),
            hasNextPage: false
        )
    }

    private static func flatten(
        _ object: [String: Any],
        prefix: String,
        output: inout [String: Any]
    ) throws {
        for key in object.keys.sorted() {
            try Task.checkCancellation()
            guard let value = object[key] else { continue }
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                try flatten(nested, prefix: path, output: &output)
            } else {
                output[path] = value
            }
        }
    }

    private static func cell(_ value: Any?) -> WorkspaceDatabaseDataCell {
        guard let value, !(value is NSNull) else { return .null }
        if value is [Any] || value is [String: Any],
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.sortedKeys, .withoutEscapingSlashes]
           )
        {
            return .text(String(decoding: data, as: UTF8.self))
        }
        // NSNumber also bridges numeric 0/1 to Bool; only JSON booleans have CFBoolean identity.
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .text(number.boolValue ? "true" : "false")
        }
        return .text(String(describing: value))
    }
}
