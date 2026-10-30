# SQL workflows

MySQL and PostgreSQL provide SQL metadata, queries, batches, sessions and explicit transactions. Doris supports its installed driver's SQL capabilities but has no MCP transaction guarantee.

## Explore and query

1. Resolve the intended connection and database with `list_connections` and `list_databases`.
2. Use `list_tables` when the relevant objects are unknown, then `get_schema_context` for selected tables. For PostgreSQL, pass the intended `schema` and use returned qualified names.
3. Construct SQL from verified metadata. Execute only when execution falls within the user's request.
4. Report the target, relevant result, returned row count and any truncation.

Metadata may be cached briefly. After an external DDL change, use `refresh: true`. An unknown column should lead to refreshed structure inspection rather than repeated guesses.

Use metadata tools instead of `SHOW` within a selected database scope. `plugin_tools(connection_id)` discovers capabilities without a database; a delegated operation then checks its actual database and tool independently.

## Database access modes

| Operation | Read only | Data read/write | Full access |
| --- | --- | --- | --- |
| SELECT and supported safe built-in functions | Yes | Yes | Yes |
| INSERT | No | Yes | Yes |
| UPDATE/DELETE with bounded field-to-literal AND filters | No | Yes | Yes |
| Unbounded or complex UPDATE/DELETE | No | No | Yes, with confirmation |
| Verifiable table/view/index/schema DDL | No | No | Yes, with confirmation |

These modes apply to the actual target database, including when database scope is selected. Explicit cross-database references must all be in scope, and every write target must have the required mode; a full-access source connection cannot override a target database's read-only rule. PostgreSQL `schema.object` stays within the selected database. Use explicitly qualified assignment targets for cross-database multi-table updates.

Full access allows supported SQL functions in the authorized namespace; read-only/data-write calls use the server's safe built-in set (including current database and version probes). SQL session switches and unclassified/procedural commands may be unsupported because the driver cannot track them. Scope checks cannot infer hidden accesses in pre-existing views, triggers or stored routines; native database users/roles remain necessary for server-enforced isolation. Server-file and explicit cross-scope functions remain restricted.

## Scripts and sessions

`execute_batch` parses the entire script before running it. It stops on failure by default. `continue_on_error` permits partial success only outside a transaction. On servers exposing compact batch receipts, inspect `succeeded`, `failed`, `not_executed`, `completed` and `transaction`; counts describe statement execution, not durable writes. A stop-on-error summary may be in `error.details`. Read only needed statement details with `get_batch_results(connection_id, database, batch_id, offset, limit)`; use `next_offset` to continue. Receipts belong to the executing MCP runtime, expire after at most 10 minutes or eviction, and require the original connection/database and unchanged permissions. Never repeat writes to retrieve missing or expired details. Older servers may return inline `results`; follow their actual schema and inspect errors there.

`use_transaction: true` requires an independent MySQL/PostgreSQL connection. Do not combine it with `session_id` or `continue_on_error`. MCP rejects DDL inside transactions on both drivers. Session-control and unclassified SQL are rejected even under full access because the driver cannot reliably track their state.

For a transaction spanning multiple calls: `open_session` → `begin_transaction` → execute statements with the returned `session_id` → `commit_transaction` or `rollback_transaction` → `close_session`. Keep the connection and database fixed. Serialize calls to one session. Permission or connection changes require a new session.

Read-only SQL uses server read-only transactions on MySQL/PostgreSQL. Doris uses classified SQL without the same server guarantee. Data-write mode accepts INSERT and UPDATE/DELETE with conservative field-to-literal filters joined by AND; complex predicates can require full access.

## Failure handling

- `CONNECTION_NOT_FOUND`: rediscover the exact connection ID.
- `SESSION_BUSY`: wait for the existing call; do not start a second operation on that session.
- `SESSION_UNAVAILABLE`: close and reopen if state is still required.
- `ACCESS_DENIED`: explain the applicable restriction and choose an authorized action.
- `CONFIRMATION_REQUIRED`: confirm the exact operation is authorized, then supply `confirm_high_risk: true`; do not change grants.
- `UNSUPPORTED_CAPABILITY`: inspect the actual driver/parser limitation; full access does not add a protocol feature. DDL inside MCP transactions must be executed separately in autocommit.
- `OPERATION_TIMEOUT`, `REQUEST_CANCELLED`, `OUTCOME_UNKNOWN`: determine whether a write committed before considering any retry.
- `RESULT_TOO_LARGE`: narrow a read. A write may already have completed; never repeat it solely to reduce its returned output.

A successful `execute_and_show` database operation can report `display_status: failed`. Preserve its result and resolve desktop display separately; rerunning the SQL can duplicate writes.
