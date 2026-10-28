# Non-SQL drivers

The installed driver's advertised tools and server policy determine actual support. Database scope means logical DB number for Redis, index name for Elasticsearch, and Topic name for Kafka.

## Redis

Use `execute_redis_command` with an `arguments` string array so keys and values are not split by shell quoting. Pass `database: "0"` or the intended logical DB. Prefer SCAN plus cursor handling over a full key enumeration. Key listings and details are live, not metadata-cache entries.

Numeric selectors and saved/display names such as `8` and `DB 8` identify the same logical DB for scope and mode checks. `mcp_access` advertises canonical numeric names. If a legacy policy contains conflicting aliases for one DB, the stricter object mode wins; changing the selector's spelling cannot raise access.

The server allows an explicit command set. Subscriptions, blocking commands, arbitrary Lua and session-state commands are unsupported capabilities. Do not attempt SELECT inside the command array; choose the DB using `database`. Ordinary supported writes require data-write/full access to that logical DB. FLUSHDB requires full access to that DB and explicit high-risk confirmation; FLUSHALL requires all-database scope, connection full access, every explicit DB override also full access, and confirmation.

## Elasticsearch

Use `execute_request` with a relative path, method and optional JSON body string. Prefer an explicitly named authorized index. GET alone does not establish that an operation is safe; honor the server's request classification.

Data-write permits ordinary single-document writes. Full access to selected indices also permits supported index creation/deletion, mapping/settings and batch operations, with high-risk confirmation. Explicit multi-index paths and bulk headers are checked against each affected index's own mode; read-only overrides cannot be bypassed through a connection-wide grant.

Restricted scopes reject encoded paths, unauthorized query lookups, ingest pipelines and routes whose target cannot be verified. Supply explicit index names when object overrides exist. Document fields named `index`, `script` or `pipeline` remain document data. Start by inspecting the mapping. Resolve missing fields/types through actual driver metadata, not a similarly named field.

## Kafka

Use `peek_messages` for bounded reads; it does not commit consumer offsets. `consumer_groups` reports the selected Topic's groups and lag without changing offsets. A specific `offset` requires a `partition`; it is mutually exclusive with `timestamp_ms` (Unix milliseconds, per-partition seek) and `latest_count` (last N offset positions per partition). Exact `key` and top-level JSON `event_id` filters match full messages before output truncation; both supplied means AND. `max_scan_messages` bounds work; inspect `scan.complete`/`scan.status` before interpreting an empty result as absence. Use a specific partition/offset plus `cell_char_offset`/`cell_char_limit` to expand the same message. `read_committed=true` enables native transactional isolation, independently of whether consumer offsets are committed. Old drivers reject unsupported filtering/isolation instead of silently degrading.

`consumer_groups` includes decimal-string `beginning_offset`, `end_offset`, `committed_offset` and `lag`. A null lag has `lag_reason` and optional `error`; do not convert missing metadata to zero. Lag counts offset positions, not necessarily message count.

`send_message` requires data-write/full access to the actual Topic and returns the broker-confirmed partition/offset when available; an empty string is a valid empty message value. A connection's full-access default never overrides a Topic's explicit read-only mode. A timeout can mean the broker accepted the message but its acknowledgment was lost. Do not automatically resend. Metadata caching concerns Topic structure only, never messages or consumer lag.
