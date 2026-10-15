# SQL workflows

MySQL and PostgreSQL provide SQL metadata, queries, batches, sessions and explicit transactions. Doris supports its installed driver's SQL capabilities but has no MCP transaction guarantee.

## Explore and query

1. Resolve the intended connection and database with `list_connections` and `list_databases`.
2. Use `list_tables` when the relevant objects are unknown, then `get_schema_context` for selected tables. For PostgreSQL, pass the intended `schema` and use returned qualified names.
3. Construct SQL from verified metadata. Execute only when execution falls within the user's request.
4. Report the target, relevant result, returned row count and any truncation.

Metadata may be cached briefly. After an external DDL change, use `refresh: true`. An unknown column should lead to refreshed structure inspection rather than repeated guesses.

## Scripts and sessions

`execute_batch` parses the entire script before running it. It stops on failure by default. `continue_on_error` permits partial success only outside a transaction: inspect every statement result.

`use_transaction: true` requires an independent MySQL/PostgreSQL connection. Do not combine it with `session_id` or `continue_on_error`. MCP rejects DDL inside transactions on both drivers. Session-control and unclassified SQL are rejected even under full access because the driver cannot reliably track their state.

For a transaction spanning multiple calls: `open_session` → `begin_transaction` → execute statements with the returned `session_id` → `commit_transaction` or `rollback_transaction` → `close_session`. Keep the connection and database fixed. Serialize calls to one session. Permission or connection changes require a new session.

Read-only SQL uses server read-only transactions on MySQL/PostgreSQL. Doris uses classified SQL without the same server guarantee. Data-write mode accepts INSERT and UPDATE/DELETE with conservative field-to-literal filters joined by AND; complex predicates can require full access.

## Failure handling

- `CONNECTION_NOT_FOUND`: rediscover the exact connection ID.
- `SESSION_BUSY`: wait for the existing call; do not start a second operation on that session.
- `SESSION_UNAVAILABLE`: close and reopen if state is still required.
- `ACCESS_DENIED`: explain the applicable restriction and choose an authorized action.
- `OPERATION_TIMEOUT`, `REQUEST_CANCELLED`, `OUTCOME_UNKNOWN`: determine whether a write committed before considering any retry.
- `RESULT_TOO_LARGE`: narrow a read. A write may already have completed; never repeat it solely to reduce its returned output.

A successful `execute_and_show` database operation can report `display_status: failed`. Preserve its result and resolve desktop display separately; rerunning the SQL can duplicate writes.
