import Foundation
import CoreFoundation

/// The Milvus REST read surface shared by MCP and the driver. Database and
/// collection identities are bound separately from user-supplied API options.
public enum MilvusReadRequest {
    public enum ValidationError: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case let .invalid(message): message }
        }
    }

    public static func make(operation: String, database: String, collection: String,
                            body: Data, maximumRows: Int) throws -> WorkspaceRequest {
        guard ["query", "get", "search"].contains(operation) else {
            throw ValidationError.invalid("Milvus supports query, get and search read operations.")
        }
        guard !database.isEmpty, !collection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalid("Milvus database and collection are required.")
        }
        guard body.count <= 8 * 1024 * 1024,
              var options = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ValidationError.invalid("Milvus body must be a JSON object of at most 8 MiB.")
        }
        for (key, identity) in [("dbName", database), ("collectionName", collection)] {
            if let supplied = options[key], supplied as? String != identity {
                throw ValidationError.invalid("Milvus body cannot override \(key).")
            }
            options[key] = identity
        }
        for key in ["outputFields", "partitionNames"] where options[key] != nil {
            guard options[key] is [String] else { throw ValidationError.invalid("\(key) must be an array of strings.") }
        }
        if let filter = options["filter"], !(filter is String) {
            throw ValidationError.invalid("Milvus filter must be a string expression.")
        }
        let bound = min(10_000, max(1, maximumRows))
        if operation == "get" {
            guard let ids = options["id"] else { throw ValidationError.invalid("Milvus get requires id.") }
            let values = (ids as? [Any]) ?? [ids]
            guard !values.isEmpty, values.count <= bound, values.allSatisfy(validID) else {
                throw ValidationError.invalid("Milvus get requires 1...\(bound) string or integer IDs. Encode large IDs as strings.")
            }
        } else {
            let requested = try integer(options["limit"], default: bound, name: "limit")
            let offset = try integer(options["offset"], default: 0, name: "offset")
            guard requested > 0, offset >= 0, offset < 16_383 else {
                throw ValidationError.invalid("Milvus limit must be positive and offset must be between 0 and 16382.")
            }
            let limit = min(requested, bound)
            guard limit < 16_384 - offset else {
                throw ValidationError.invalid("Milvus offset + limit must be less than 16384.")
            }
            options["limit"] = limit
            options["offset"] = offset
            if operation == "query", options["filter"] == nil { options["filter"] = "" }
            if operation == "search" {
                let vectors = options["data"] as? [Any]
                let ids = options["ids"] as? [Any]
                guard (vectors != nil) != (ids != nil),
                      (vectors ?? ids)?.count == 1,
                      options["data"] == nil || vectors != nil,
                      options["ids"] == nil || ids != nil else {
                    throw ValidationError.invalid("Milvus search requires exactly one query in data or ids. Submit separate requests for additional vectors.")
                }
                if let ids, !ids.allSatisfy(validID) { throw ValidationError.invalid("Invalid search ID.") }
                // Grouping can multiply topK. Keep this bounded read route to
                // one result per group until it has an explicit grouped model.
                if let groupSize = options["groupSize"], try integer(groupSize, default: 1, name: "groupSize") != 1 {
                    throw ValidationError.invalid("Milvus MCP search supports groupSize=1.")
                }
            }
        }
        return WorkspaceRequest(method: .post, path: "/v2/vectordb/entities/" + operation,
            body: try JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]))
    }

    public static func validate(_ request: WorkspaceRequest, database: String) throws -> WorkspaceRequest {
        let prefix = "/v2/vectordb/entities/"
        guard request.method == .post, request.path.hasPrefix(prefix),
              let body = request.body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let collection = object["collectionName"] as? String else {
            throw ValidationError.invalid("Milvus read requests require an allowed POST route and JSON collectionName.")
        }
        return try make(operation: String(request.path.dropFirst(prefix.count)), database: database,
            collection: collection, body: body, maximumRows: 10_000)
    }

    private static func integer(_ value: Any?, default fallback: Int, name: String) throws -> Int {
        guard let value else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = Int(number.stringValue) else {
            throw ValidationError.invalid("Milvus \(name) must be an integer.")
        }
        return result
    }

    private static func validID(_ value: Any) -> Bool {
        if let text = value as? String { return !text.isEmpty }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return Int64(number.stringValue) != nil || UInt64(number.stringValue) != nil
    }
}
