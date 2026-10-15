# MCP implementation and validation

Reference: DBX commit `0db01f7f284ec6b0b090fe7369de7d05c37b25b0`.
Scope follows QueryCraft's six drivers; Salesforce and other foreign driver ecosystems are excluded.
No Superpowers skills are used. User documentation is in [MCP.md](MCP.md).

## Architecture

- Official Swift MCP SDK at `a0ae212ebf6eab5f754c3129608bc5557637e605`;
  SwiftNIO adapts HTTP sockets to the SDK's stateful Streamable HTTP transport.
- Runtime/policy/authorization live in QueryCraftFeature. A tiny native C launcher
  dynamically links the same framework as external drivers. No second copy of
  the Swift protocol/module metadata is embedded in the distributed executable.
- Each client owns independent database sessions; desktop sessions are never reused.
  stdio uses protocol-only stdout. HTTP requires Bearer auth and Host/Origin checks.
- Policy is a private, atomically replaced JSON file reread on tool calls and SQL
  statement boundaries. Missing/corrupt policy fails closed, while session close/
  rollback remains possible. Scope enforcement also applies to resources and plugin routing.
- Credentials remain in Keychain. MCP has a separately installed, signed caller-checked
  helper under `QueryCraftCredentials/mcp-v1`; the existing desktop helper is preserved.
- Settings download an independently signed MCP component from the component catalog,
  then stage, self-check and atomically activate it. The desktop embeds no MCP package
  or Skill resources. HTTP uses a user launchd job; MCP and Skill have independent versions.

## Implemented

- stdio and authenticated Streamable HTTP; real SDK negotiation, tools and resources.
- 27 tools covering SQL metadata/query/batches/sessions/transactions, Redis commands,
  Elasticsearch REST, Kafka reading/produce/groups, saved connections, driver tool
  discovery/dispatch, and desktop integration.
- Connection/group/database/tool permissions, restrictive permission ceilings, read/data-write/full
  modes, inherited/unlimited/explicit query timeout, bounded result controls and explicit high-risk confirmation arguments.
- MySQL/PostgreSQL readonly SQL uses tracked `START TRANSACTION READ ONLY` / rollback boundaries;
  pinned readonly transactions use the same begin command. Control/unclassified SQL and
  transactional DDL fail before reaching drivers, whose state tracker cannot represent them.
- Session reservation before suspension, capacity limits, idle cleanup, live revocation,
  no automatic retry of failed writes, query/connect/transaction timeout cancellation.
- Native settings with a searchable checkbox table for connection grants, popup selectors for client and permission categories, retained all/selected/deny database modes,
  localized tool grid, permission comparison and 12 client configuration templates;
  database discovery/search,
  install/update/uninstall, credential authorization, HTTP readiness and token rotation.
- Desktop results reuse the existing native query results view. Display failure preserves
  the already-executed query result and reports display status without suggesting retry.
- Dev/release scripts sign the host without embedding MCP/Skill. Required licenses are bundled.

## Independent distribution (2026-10-15)

- `Components/versions.json` defines separate MCP/Skill identities and compatibility
  with the app, Driver API, storage, credentials and desktop bridge. Skill additionally
  declares an MCP version range. The client selects the newest compatible published record.
- CI signs each immutable release record with Ed25519. LicenseServer stores those
  records and ZIPs, and publishes catalogs without holding the release private key.
  It has separate MCP and Skill management pages, draft/publish/retire operations,
  role/CSRF/deployment-token checks and audit records.
- Downloads require HTTPS, exact size/SHA256 and matching embedded compatibility
  metadata. MCP also requires the pinned application signing certificate and a
  successful relocated self-test. ZIP paths and framework symlinks are validated.
- A signed `MCP/bin/querycraft-mcp` launcher executes a canonical immutable version
  under `MCP/Versions`. Atomic `Current`/`Previous` links activate versions and support
  explicit rollback. Existing sessions keep their old frameworks/resources. Legacy
  client paths are retained until the user re-adds their client configuration.
- Standalone `--check-updates`, `--update`, `--rollback` and `--update-skill` management
  commands work without the desktop. Runtime updates restart an existing launchd HTTP
  service using saved configuration. Install operations use cross-process file locks.
- Skill comes from its own signed catalog and resource ZIP. Managed-file hashes prevent
  update/removal from discarding local edits. No personal Skill is installed by tests.
- Actions gates component releases on implementation/compatibility changes. Driver
  version/build-only edits are rejected, and the exact affected-driver list is reused
  for build, server publication, manifest synchronization and GitHub asset upload.
  Main-app or settings changes alone do not bump/release unchanged drivers.

Validation uses isolated catalogs, ephemeral release keys and signed runtime copies;
it does not publish to the production resource server. The online server and initial
signed component releases must be deployed before production download/install is available.

Local Intel validation for this distribution change passed:

- XcodeBuildMCP Debug build; 100 MCP/settings/registry regression tests. After the
  final Skill compatibility-recovery change, 29 component/core MCP tests passed again.
- 14 release-scope/workflow tests, including version/build-only rejection, unchanged
  driver rejection, required shared-driver groups and filtering leftover source-run assets.
- LicenseServer `go test ./...`; real native MCP/Skill packager ZIPs signed through
  Sparkle `sign_update` were accepted and published in an isolated server database.
- Signed independent catalog download/install/update/rollback: existing stdio clients
  completed real tool calls after activation, live HTTP restarted with saved credentials,
  broken packages/forged signatures/concurrent updates/automatic downgrades were rejected,
  and Skill selected a compatible fallback after explicit MCP rollback.
- Relocated standalone protocol/auth/revocation checks and all six API 5 driver loads,
  including MySQL/Doris alone and mixed old/new driver packages.
- Complete signed desktop model/service checks, isolated client registration and Skill
  lifecycle, offscreen light/dark/narrow native settings, post-desktop-exit HTTP and
  saved launchd re-bootstrap. This is not a real computer reboot or physical-input test.
- The signed desktop preview contains no MCP application or Skill installation payload.
  All six driver version/build declarations match HEAD. No production service, installed
  user component, authorization or client configuration was changed by this validation.

Final artifacts and validation record: `.build/mcp-independent-compatible-20261015/`.
Arm64/Universal/Release builds and a real GitHub Actions publication remain release-time checks.

## Verification (local Intel macOS)

- Main QueryCraft Debug scheme built with XcodeBuildMCP.
- `MCPTests`, `MCPSessionTests` and `MCPOptimizationTests`: 37 tests passed, including parameterized negative SQL
  cases, malformed/scoped REST, strict arguments, precision, SDK handshake, process timeout,
  concurrent session exclusion and cleanup after corrupt policy, restrictive global ceilings, all six
  drivers denying disabled database scopes, retained selections, 12 client template formats,
  timeout semantics, realistic SQL transaction state tracking, metadata reuse/caching/DDL invalidation,
  concurrent capacity exclusion, history bounds/privacy and managed Skill lifecycle with local-change
  and symlink protection. Skill frontmatter validation also passed.
- Existing settings/navigation/copy/window and driver registry tests: 45 passed; the final combined regression ran all 82 tests successfully.
- Actual subprocess stdio and HTTP tests passed: initialization instructions, read-only tool hints,
  lazy discovery, scoped Resources, typed errors, history privacy, unauthorized request and Origin
  rejection, session routing, revocation and token rotation. In the protocol fixture (remove_connection
  disabled), discovery shrank from 26 tools / 22,061 JSON bytes to 10 tools / 7,849 bytes.
- Independently built and packaged all six current API 5 drivers, then loaded all six
  into the relocated standalone MCP bundle successfully. The runtime now uses the exact same
  versioned `DriverAPI-5/Drivers` location as the desktop through one shared path resolver.
  Five missing API 5 drivers were subsequently provisioned in the real Dev directory; its existing
  MySQL driver and all older API 4/production directories were preserved. All six loaded there,
  and final live checks used copies of those actual Dev drivers.
- Relocated to a temporary path with spaces, cleared build/runtime override variables,
  checked loaded library paths, SQL grammar resources, signatures and handshake.
  Credential helper rejected an unrelated parent process with exit 77.
- Six real Docker services were exercised through the signed standalone MCP binary and isolated API 5 drivers:
  MySQL 5.6, PostgreSQL 17, Redis 7.4.2, Elasticsearch 8.18.0, Kafka 3.9.1 and Doris 4.1.3.
  SQL checks include metadata, NULL/decimal precision, row bounds, readonly rejection, MySQL/PostgreSQL
  readonly transactions, explicit commit/rollback, atomic batch rollback, real query timeout/reconnection and local DDL cache invalidation.
  Redis SET/GET/SCAN, Elasticsearch index/document/search/mapping, Kafka produce/peek/groups with committed offsets,
  Doris DDL/write/read/metadata, and all six denying revoked database scopes were checked.
  Kafka testing caught and fixed the missing `Kafka` driver namespace when no default database was saved.
- Added connection creation parameters for authentication, TLS and Kafka SASL; credential-free Kafka
  defaults to no authentication. TLS continues to default to verified encryption.
- A signed isolated desktop harness exercised actual installation, repeated update, intentionally failed
  post-replacement self-test with rollback, staging cleanup, uninstall preserving policy, and real launchd
  HTTP readiness/restart/stop. It verifies settings save/history/recheck, preserves unsaved HTTP values during runtime updates,
  and renders native settings offscreen in light/dark and narrow states.
- Signed credential helper save/read/copy/delete passed with new test-only Keychain items. All test
  items were removed. Existing credentials were not read. The versioned MCP helper installs itself.
- Claude Code imported isolated generated stdio and authenticated HTTP configurations and reported Connected for both. Codex CLI
  parsed the generated TOML and selected the expected transport without a model request or config writes.
- Reproducible checks are in `scripts/test-mcp-live.py`, `test-mcp-desktop.py` / `.swift`,
  `test-mcp-credentials.py`, `test-mcp-clients.py`, `test-mcp-protocol.py` and `test-mcp-package.py`.
  Live tests own disposable loopback-only containers and clean up those containers and their volumes.
- Python packaging/test/install scripts compile; release shell syntax and diff whitespace checked.

Follow-up regression on 2026-10-14:

- Intel Debug app and both affected driver builds passed. Fifty related Swift package tests passed
  using the same pinned dependency revisions as the desktop build.
- The shared MariaDB transport now lives in a separate dynamic Swift package. MySQL and Doris
  package that dependency rather than each statically registering the same runtime class. The new
  `MariaDBConnection` runtime identity also coexists with earlier static driver builds. Relocated
  six-driver loading, individual MySQL/Doris loading, and both old/new driver combinations passed
  without duplicate class warnings. No Driver API change was needed.
- `scripts/test-mcp-lifecycle.py` passed five stdio connect/EOF/clean-exit cycles, 30 HTTP
  connect/DELETE/reconnect cycles across six concurrent clients, and process restart with stale-session
  rejection and fresh reconnect from persisted settings.
- `scripts/test-mcp-live.py --drivers mysql,doris --stress` passed the existing real MySQL/Doris
  checks plus four simultaneous HTTP clients opening/querying/closing 40 database sessions and
  repeatedly reading metadata. HTTP session ownership, rollback on DELETE, rollback on stdio EOF,
  profile persistence and stale database-session rejection after process restart also passed.
- The signed desktop harness now leaves its isolated launchd service running when the host exits.
  The parent verified HTTP access after host exit, then booted out and re-bootstrapped the saved
  `RunAtLoad` job and reconnected. This simulates job restoration, not an actual OS reboot/login.
- The existing native SQL protocol fixtures passed PostgreSQL and MySQL/Doris aliases, source
  metadata across schemas/databases, expression types and empty results, plus Doris overview
  comments/statistics/views/legacy metadata fallback.
- The signed desktop harness loaded all six packaged drivers through the desktop registry, including
  the new shared transport. Updated MySQL/Doris bundles are in `.build/mcp-driver-shared-validation`
  and staged in the real Dev `DriverAPI-5/DriverUpdates` directory for its next start. Staged copies
  passed signature, exact-content and isolated loading checks. The running user Dev process and
  its currently installed driver files were preserved; adoption by that existing app still requires
  a restart. Details are in `.build/mcp-review-20261014/dev-driver-pending-updates.json`.
- Real mouse/keyboard interaction remains blocked by the repository's required screen isolation;
  this environment provides no reliable isolation facility.

Final acceptance regression on 2026-10-14:

- The final Intel Debug source and signed preview were rebuilt. All 84 combined MCP,
  settings/navigation/window and driver-registry tests passed. A pre-existing window test
  crashed during AppKit close animation because its standalone window used release-on-close
  ownership; the fixture now matches the controller's ARC ownership, disables animation and
  stays offscreen. The production settings controller already used the correct ownership.
- Stopping HTTP no longer validates or saves unsaved editor values, so an invalid port cannot
  prevent stopping the service. Starting still validates and saves. The save message explicitly
  distinguishes immediate permission changes from listening-address changes requiring restart.
- Credential errors distinguish denied, cancelled and unavailable states without exposing raw
  Keychain details. Typed errors survive the explicit authorizer subprocess boundary into settings.
  Actual test-only saved credentials authorize successfully; missing credentials fail rather than
  report success, and authorization succeeds again after removing the missing fixture. All test
  Keychain items were deleted. Denied/cancelled system statuses and the process-boundary recovery
  were tested with injected errors; pre-existing interactive Keychain dialogs remain untested.
- The signed desktop harness tested HTTP start/stop/recovery, persisted six-driver profiles and
  all four permission steps after reopening, runtime installation/uninstallation through the settings
  model, and managed Skill install/uninstall/local-edit protection/recovery for all three destinations
  in an isolated home. No personal Skill was installed. Startup adopted pending MySQL/Doris updates
  in isolated API 5 storage; the installed files exactly matched the new packaged bundles.
- The final signed package passed relocated signature/resources/protocol checks, all six real
  database fixtures, client import/connection checks, five stdio clean exits, 30 HTTP reconnect
  cycles, standalone process restart, and authenticated launchd access after the desktop host exited.
  Claude Code was checked for real stdio/HTTP connectivity; Codex was checked for configuration
  parsing. Complete tool execution was exercised by the protocol clients against real drivers,
  without launching an additional model agent.
- Final logs are `final-{app-build,tests,package,desktop,credentials,live,clients,lifecycle}.log`
  beside `.build/mcp-review-20261014/validation/summary.json`.


Existing production driver copies on this machine are API 3. MCP correctly rejected them
without deleting them. Validation used API 5 bundles in versioned isolated storage, then provisioned missing Dev drivers as described above.

## Native settings revision (2026-10-15)

- DBX remains a functional reference only. The MCP pane now follows the existing macOS
  settings shell: system segmented navigation, grouped forms, popup menus, radio buttons,
  disclosure groups and native tables. The numbered setup wizard, transfer lists, internal
  connection sidebar, custom selection cards and horizontal client chips were removed.
- Connection grants use a searchable checkbox table, with group and batch authorization
  retained. Database/object scopes and permission ceilings use a connection popup. The six
  drivers retain the same authorization rules; scope descriptions identify Redis DB numbers,
  Elasticsearch indices/aliases/data streams and Kafka topics explicitly.
- Runtime installation and credentials are compact settings rows. Client selection and
  transport use popup menus; configuration text, optional Skill, runtime limits and optimization
  controls are disclosed on demand. Call history uses a native table with detailed records available.
- The bottom action area remains fixed and uses the standard Save command (Command-S).
  Metadata and history retain fixed content areas while loading or retrying. Search prompts,
  checkbox accessibility labels and all/selected/deny scope semantics were preserved.
- Intel Debug build, 84 regression tests, signed package/protocol checks and six-driver loading
  passed. Native settings were rendered offscreen in English and Simplified Chinese, light/dark,
  including narrow database/permission/tool layouts and loading/error states. Desktop model
  installation, persistence, Skill and HTTP lifecycle checks passed. One parallel harness run
  had a readiness failure; a sequential rerun passed, so this is not evidence of a reproducible
  runtime fix. Physical mouse/keyboard interaction remains outside this verification.
- Preview: `.build/mcp-native-20261015/QueryCraftDev.app`. Logs and renderings are retained
  beside it. The earlier preview is retained separately.

Readability follow-up (2026-10-15): MCP disclosure controls were removed after user feedback.
Configuration text, Skill, HTTP options, advanced settings, permission groups and tools are
displayed directly. Body text is 15 pt and supporting text 13 pt; action controls use the large
system size, with a prominent Save button and a fixed 64 pt footer. Runtime uninstall is a
visible action. Call details follow selection in the native history table. This change is scoped
to MCP settings; other settings panes keep their typography. Validation includes offscreen
wide/narrow renders and scrolling to the bottom of the expanded page.
Latest preview: `.build/mcp-readable-20261015/QueryCraftDev.app`.

Settings consistency follow-up (2026-10-15): the MCP pane now follows Appearance's native
body/caption typography and regular control size. The previous 15/13 pt overrides and large
controls were removed across connection, permission and activity sections. The footer is 44 pt,
button widths use their system sizing, and the segmented navigation is compact. The expanded
configuration preview uses 3–6 lines of height instead of a fixed 160 pt; long content scrolls.
No persistence or authorization behavior changed. The offscreen harness now renders Appearance,
MCP and Codex at the same 790×818 pt size, plus narrow access layouts, for direct comparison.
Preview: `.build/mcp-sized-20261015/QueryCraftDev.app`.

Responsive entry follow-up (2026-10-15): SettingsView owns the MCP model for the lifetime of
the settings window. Sidebar navigation keeps drafts and selections and does not recreate the
model or restart signature/version processes. A model-owned, deduplicated activation task survives
the disappearing pane's SwiftUI task cancellation and clears itself after completion.
`MCPSettingsLoader` reads policy and the connection catalog on its actor. The basic snapshot makes
the form editable before the installed runtime's signature/version and HTTP checks finish. Runtime
errors are separate from editor errors; initial failures remain retryable. Recheck refreshes the
connection catalog while preserving the edited policy. Skill resource lookup is deferred to the
installer actor. Client inspection starts only after the basic snapshot and executable path exist;
its status area keeps a stable height while loading and long paths truncate with a full-path help.
Tests suspend runtime checks, cancel/re-enter the pane, verify a single check and preserved drafts,
exercise load/check failures, and refresh profiles for all six drivers. The signed harness records
basic readiness, complete runtime inspection and cached reentry timings with the real packaged runtime.
Preview: `.build/mcp-responsive-20261015/QueryCraftDev.app`.

## Delivery limits

This is not a claim of pixel-identical DBX UI or completed production acceptance.

- Native views were rendered offscreen and service/model actions tested in isolated storage. Physical
  mouse/keyboard interaction and interactive authorization of pre-existing desktop Keychain items were
  not exercised. No desktop input was simulated; no user database was changed. New Keychain items and
  the signed helper path were verified separately.
- Intel Debug is verified; arm64, Universal and Release packaging still require their own
  builds and checks before release. A signed Dev preview was produced under `.build/mcp-review-20261014/QueryCraftDev.app`;
  no app was installed into /Applications or published.
- Installation/update now uses the independent signed component feed. Local signed-catalog
  validation is complete; the production backend and initial signed releases are not deployed
  by this implementation task. There is no npm installation dependency.
- Database scope verifies direct references. Database-side accounts remain necessary for
  strict security isolation across views, aliases, functions and server configuration.
- Conservative SQL predicates/functions and scoped Elasticsearch routes may reject some
  legitimate requests. Redis exposes explicit commands, not an arbitrary scripting/subscription
  tunnel. These restrictions are documented, not silently downgraded.
- Pi requires an MCP bridge; DeepSeek Harness requires its MCP client package. Both currently offer
  stdio templates only. Claude Code stdio/HTTP connectivity and Codex configuration parsing were verified; the other generated templates have not been imported in each real client.
- Query timeout inheritance snapshots the desktop global query setting on save; QueryCraft does not
  currently store per-connection query timeouts.
- Doris has no promised SQL transaction support/transaction-enforced readonly guarantee.
  Routine source is subject to information_schema permissions and length limits.
- Cancellation depends on the driver/network stack acknowledging close; an unconfirmed
  write or commit must be resolved by checking the database, never automatic retry.

## Managed client configuration (2026-10-15)

`MCPClientRegistration` provides one-click user-level add/update/remove for Codex, Claude Code,
Cursor, VS Code's default profile and OpenCode. Other clients retain their export templates.
Codex uses its installed native CLI in a private temporary `CODEX_HOME`; the original file is
never passed to a home-level mutating CLI command. Generated TOML uses unescaped path slashes,
and the real Codex parser validates both stdio and authenticated HTTP configurations.
JSON files are merged semantically; commented JSON/JSONC requires manual merging to preserve comments.

Each edit preserves unrelated settings, creates a private backup, checks for concurrent external
changes, takes a per-file QueryCraft lock and atomically replaces the file with mode 0600.
Private receipts contain entry hashes only, so changing a different MCP server does not prevent
removal. Modified/conflicting QueryCraft entries and symlink paths are refused. An exactly matching
copied entry can be adopted. Repeated add/remove is idempotent; updates can switch transports.
The settings model guards stale inspection responses and exposes the destination and recovery errors.

Validation includes 89 MCP/settings/registry tests, native Codex TOML roundtrips retaining model,
proxy settings and comments, and signed settings-model add/update/remove roundtrips for five clients.
Claude Code actually connects through the resulting user-level configuration over stdio and HTTP.
Cursor, VS Code and OpenCode configuration contents are verified in isolated homes, without claiming
their actual applications have been launched/imported. No personal client entries were written by tests.
HTTP startup readiness now uses a 20-second elapsed-time window instead of fifteen fast retries
(approximately three seconds on connection refusal). The signed launchd harness verifies a native
wrapper that deliberately waits five seconds before executing the real HTTP runtime.
Sources: [Codex MCP](https://developers.openai.com/codex/extend/mcp),
[Claude Code MCP](https://code.claude.com/docs/en/mcp),
[Cursor MCP](https://docs.cursor.com/context/model-context-protocol),
[VS Code MCP](https://code.visualstudio.com/docs/agent-customization/mcp-servers),
[OpenCode config](https://docs.opencode.ai/docs/config/).

## DBX optimization comparison (source review, 2026-10-14)

DBX also ships `skills/dbx/SKILL.md` (version 1.1.0 at the reference commit). This is a
CLI-oriented skill, installed by `dbx agent setup`, with command, workflow and safety
references. MCP does not require that skill. Treat it as reference material, not an
instruction installed into this project or the user's agent environment.

Verified upstream optimizations and current QueryCraft differences:

- Compact schema context: DBX defaults to 8 tables (maximum 20), with column/type/null/key/comment
  text and a truncation notice. QueryCraft now defaults to 8 tables with compact context, explicit truncation and a 16,000-character
  budget. Detailed JSON/DDL remains available on request.
- Result context budget: DBX defaults to 100 SQL rows and 200 characters per string cell,
  with explicit expansion offsets. QueryCraft now defaults to 200 characters per string cell, retaining row/byte limits
  and exposing next_offset for explicit expansion.
- Plugin tool discovery: DBX supports flat/lazy/both. QueryCraft now offers direct/lazy/both modes with the same policy checks on delegated calls.
- Connection pools and schema-cache invalidation after DDL are present in DBX. QueryCraft now reuses clean metadata connections only (default 4 idle, 60-second expiry).
  Arbitrary SQL retains independent/pinned connections. Metadata caching defaults to 30 seconds,
  has a 64-entry / 2 MiB bound, and checks full policy/profile identity. Local DDL invalidates it;
  other clients/external edits converge through TTL or explicit refresh. Redis keys bypass caching.
- DBX has bounded/redacted MCP call history and categorized error codes. QueryCraft now exposes structured errors and a settings history page backed by shared SQLite.
  History retains 500 operational summaries, with no SQL, arguments or response bodies.
- DBX tests client-compatible JSON schemas, and offers metadata Resources. QueryCraft also has
  strict typed arguments and Resources; Claude Code stdio/HTTP and Codex configuration were checked with their real CLIs; other clients remain template-level checks.

For QueryCraft, keep core guidance in MCP server instructions and tool descriptions so clients
can use the service without a skill. The independently downloaded optional QueryCraft skill teaches discovery,
verified schema lookup, bounded queries, transaction cleanup and driver-specific workflows.
Such a skill must never replace server-enforced permissions or imply that every MCP client
loads agent skills. The optional QueryCraft skill has managed install/update/uninstall controls; validation uses isolated destinations and does not alter the user's skill directories.

Sources: [DBX MCP server](https://github.com/t8y2/dbx/blob/0db01f7f284ec6b0b090fe7369de7d05c37b25b0/crates/dbx-mcp/src/server.rs),
[DBX MCP guide](https://github.com/t8y2/dbx/blob/0db01f7f284ec6b0b090fe7369de7d05c37b25b0/docs/content/docs/mcp.cn.mdx),
[DBX CLI skill](https://github.com/t8y2/dbx/blob/0db01f7f284ec6b0b090fe7369de7d05c37b25b0/skills/dbx/SKILL.md).


### Codex conversation handshake compatibility (2026-10-15)

A real Codex desktop failure exposed a gap in the previous client verification: its settings
inventory connected, but its conversation MCP runtime failed before registering any tools.
The captured initialize request advertises `experimental: {"codex/auth-change": {}}`.
The pinned Swift SDK models experimental client capabilities as `[String: String]`, causing a
JSON decoding error for this valid JSON-valued extension. Empty-capability integration clients
and Codex configuration parsing did not exercise this path.

`MCPInitializationTransport` ignores unimplemented experimental values that this SDK cannot
represent, only in initialize requests. Known client capabilities, request IDs, transport framing,
HTTP request context, authentication and SDK lifecycle negotiation remain unchanged. The same
adapter covers stdio and Streamable HTTP; remove it when the SDK accepts JSON-valued experimental
capabilities. No database driver behavior or Driver API changed.

The regression suite uses the captured conversation request, checks actual discovery/calls and
live permission revocation, and ensures malformed or unrelated messages remain untouched.
`scripts/test-mcp-codex.py` additionally runs the installed Codex app-server in an isolated
`CODEX_HOME`, creates ephemeral protocol contexts without model turns, and tests the **conversation**
connection using `mcpServerStatus/list` with a thread ID and `mcpServer/tool/call`.
The pre-fix executable reproduces settings discovery success followed by conversation startup
failure. The signed fixed package passes five independent conversation connections for each
transport, real list_connections calls, and same-connection tool revocation/restoration.
The isolated fixture intentionally authorizes no database connections. Existing storage can be
checked read-only with `--data-dir`; that mode never rewrites its policy or credentials.

Validation: 96 related Swift tests pass; macOS Intel Debug builds; signed relocated package checks
pass with all six drivers. This does not claim a model-generated query, physical UI interaction,
OS login/reboot, or arm64/Release validation.


### MCP settings layout and category switching (2026-10-15)

The activity table previously lived inside a grouped Form at a fixed 300 pt height. Native
inspection found two nested scroll views, with the table's vertical scroller disabled. Activity
now gives the table its own scroll view outside Form, a compact fixed detail area and a viewport
sized to available space. Its summary toggle retains the native grouped Form row above the table. Loading/error feedback has a fixed location and retains existing rows.

Permissions retain the existing native grouped Form: leading labels, trailing controls and the
horizontal execution-access picker. `MCPPermissionsSettingsPane` reuses the project's existing
native tab-host pattern: each of the four categories gets a separate Form, created on first use
and retained until the permission pane is destroyed. Only the selected category is attached;
previously visited categories keep their native controls and scroll positions. Policy remains
in the shared observable model, so retained controls reflect edits made elsewhere. The host
propagates enabled state and color scheme, releases the previous field editor on category
changes, and discards all pages if the model changes. It does not warm hidden pages on the main
thread or change the shared settings window.

A comparison against the restored native Form measured a warm Tools and execution median of
about 527 ms before and 118 ms after (three repeated sequences after the change). First use
still takes roughly 0.5 seconds to create native controls; this is not a claim of zero startup
latency. Light, dark and narrow Tools and execution PNG snapshots were byte-identical to the
previous aligned layout. Tool grouping, catalog semantics and all six drivers remain unchanged.

The signed offscreen harness measures category switches, loads 500 history records, scrolls the
native table to the end, tests 500/1000 pt content sizes and verifies stable layout on refresh
failure. It also checks native page identity reuse, a four-page cache bound, preserved permission
scroll position, visible radio/checkbox values after shared policy edits, busy-state disabling
and release of the old field editor. It does not synthesize native clicks. It changes view state and scroll positions programmatically and sends no system mouse
or keyboard input. These checks do not claim physical wheel/trackpad testing.

The live Codex MCP acceptance also passed explicit session open, begin, SELECT, rollback, begin,
SELECT, commit and close. This is **read-only transaction lifecycle** coverage. The attempted
isolated CREATE TABLE was denied by the documented restricted-database DDL policy; no test table
was created. Data writes and write rollback/persistence remain untested in the user's database.
