import Foundation

extension MCPToolCatalog {
    static let exportTools: Set<String> = ["export_query", "get_export_status", "cancel_export", "delete_export"]
    static let exportTitles = ["export_query": "导出 SQL 查询", "get_export_status": "查询导出进度", "cancel_export": "取消导出", "delete_export": "删除导出文件"]
    private static func exportObject(_ properties: [String: MCPJSONValue], required: [String] = []) -> MCPJSONValue {
        .object(["type": "object", "properties": .object(properties), "required": .array(required.map(MCPJSONValue.string)), "additionalProperties": false])
    }
    static let exportDefinitions: [MCPToolDefinition] = {
        let column = exportObject([
            "source_index": integer("Zero-based result column position; never guessed from display names."),
            "title": string("Output header."),
            "type": .object(["type": "string", "enum": .array(["text", "integer", "decimal", "date", "datetime"])]),
            "date_format": .object(["type": "string", "enum": .array(["yyyy-mm-dd", "yyyy-mm-dd hh:mm:ss"])]),
            "width": integer("Optional XLSX width, 8–80.")
        ], required: ["source_index", "title"])
        let query = exportObject([
            "name": string("Unique worksheet name, max 31 UTF-16 units; also used for CSV names."),
            "sql": string("One verified non-locking read-only SELECT. Full values are streamed, never chat-truncated."),
            "columns": .object(["type": "array", "items": column, "minItems": 1, "maxItems": 256]),
            "expected_rows": integer("Optional hard row-count assertion, including zero; mismatch fails the entire export.")
        ], required: ["name", "sql"])
        let ownership: [String: MCPJSONValue] = ["job_id": string("Export job UUID."), "access_token": string("Private export capability returned at submission. Retain securely; never include in SQL.")]
        return [
            .init(name: "export_query", description: "Asynchronously export authorized MySQL queries to a local XLSX workbook or UTF-8 BOM CSV (multiple queries become one ZIP). Requires an updated MySQL driver. Independent hard limits; never silently truncates. Returns job_id/access_token, not rows. Use get_export_status. Files expire after 24h and require a shared local filesystem; remote download is not supported. Whole-file success only, no overwrite or automatic retry. Decimal/unsafe integer values remain text; date formatting is opt-in. Keep idempotency_key to recover a lost submission response.", properties: [
                "connection_id": selector["connection_id"]!, "database": string("Explicit authorized database."),
                "format": .object(["type": "string", "enum": .array(["xlsx", "csv"])]),
                "queries": .object(["type": "array", "items": query, "minItems": 1, "maxItems": 20]),
                "consistency": .object(["type": "string", "enum": .array(["single_snapshot", "per_query"]), "description": "Default single_snapshot: one InnoDB base-table repeatable-read snapshot; unsupported sources/CTEs fail. per_query explicitly allows different snapshots." ]),
                "timezone": string("MySQL UTC offset, default +00:00, e.g. +08:00. Affects TIMESTAMP; DATETIME is not converted."),
                "filename": string("Filename only; xlsx, csv or zip extension must match. No arbitrary path/overwrite."),
                "idempotency_key": string("Fresh random UUID. Same key/request returns the same job; a new key starts a new snapshot."),
                "limits": exportObject(["max_rows": integer("1–1000000 total data rows."), "max_file_bytes": integer("1–536870912 bytes."), "max_raw_bytes": integer("1–2147483648 uncompressed bytes."), "timeout_seconds": integer("1–600 seconds including queueing. Database operations also obey the configured query timeout.")])
            ], required: ["connection_id", "database", "format", "queries", "idempotency_key"]),
            .init(name: "get_export_status", description: "Read export counts and completion state; artifact path/size/SHA-256 only on full success. Requires job capability and current database authorization. No detail rows or SQL returned.", properties: ownership, required: ["job_id", "access_token"]),
            .init(name: "cancel_export", description: "Request cancellation. Wait for cancelled/failed/succeeded before assuming the worker stopped. Capability required; cleanup remains available after grants are revoked. Does not delete completed files.", properties: ownership, required: ["job_id", "access_token"]),
            .init(name: "delete_export", description: "Delete a terminal export and its private files. Active tasks must first be cancelled and reach a terminal state. Requires job capability; does not affect database data.", properties: ownership, required: ["job_id", "access_token"])
        ]
    }()
}
