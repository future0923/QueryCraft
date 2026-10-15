# Non-SQL drivers

The installed driver's advertised tools and server policy determine actual support. Database scope means logical DB number for Redis, index name for Elasticsearch, and Topic name for Kafka.

## Redis

Use `execute_redis_command` with an `arguments` string array so keys and values are not split by shell quoting. Pass `database: "0"` or the intended logical DB. Prefer SCAN plus cursor handling over a full key enumeration. Key listings and details are live, not metadata-cache entries.

The server allows an explicit command set. Subscriptions, blocking commands, arbitrary Lua and session-state commands are unavailable. Do not attempt SELECT inside the command array; choose the DB using `database`. FLUSH operations require full access and explicit high-risk confirmation; FLUSHALL also requires unrestricted database scope.

## Elasticsearch

Use `execute_request` with a relative path, method and optional JSON body string. Prefer an explicitly named authorized index. GET alone does not establish that an operation is safe; honor the server's request classification.

Restricted scopes reject encoded paths, cross-index lookups, scripts, pipelines and routes the server cannot verify. Start by inspecting the mapping. Resolve missing fields/types through the actual driver metadata, not a similarly named field.

## Kafka

Use `peek_messages` for bounded reads; it does not commit consumer offsets. `consumer_groups` reports the selected Topic's groups and lag without changing offsets. A specific offset requires a partition.

`send_message` requires write permission and returns the broker-confirmed partition/offset when available. A timeout can mean the broker accepted the message but its acknowledgment was lost. Do not automatically resend. Metadata caching concerns Topic structure only, never messages or consumer lag.
