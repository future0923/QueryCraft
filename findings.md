# Syntax highlighting findings

## Data transfer — 2026-10-19

- User explicitly requests DBX functionality/configuration parity, native UI, with Tools → Data Transfer as primary entry point; a reduced import-style wizard is not the requested outcome.
- Delivered workbench covers reusable tasks/folders, source/target selection and swapping, grouped objects, filters, content/strategy/name-case/batch/timeout/ownership options, SQL review, background progress and history. Entry is Tools → Data Transfer. Query-grid export-to-database and sidebar copy/paste shortcuts are not implemented; docs/DATABASE_TRANSFER.md explicitly records that boundary and engine/protocol limits.
- Final verification: 84 regression methods, MySQL 5.7→8.0, PostgreSQL 17→17, MySQL→PostgreSQL and PostgreSQL→MySQL live matrices, six-driver loading and Debug build passed. Signed Dev installed with marker 20261019-155653-d6bcfc35, without launching. Visible UI acceptance remains incomplete because user pressed Escape during guarded validation; no further desktop operations followed.
- Local reference is /Users/weilai/.codex/reference-repos/DBX, clean main at 3de07819 (2026-10-16). Remote update interrupted after no response; reference worktree unchanged.
- DBX: reusable task/folder tree, searchable source/target connection/catalog/database/schema and swapping, grouped object selection and bulk-name matching, per-table WHERE/full SELECT filters; structure+data/structure/data modes; append/overwrite/upsert/rebuild; preserve/lower/upper table names; batch=1000; inherit/custom operation timeout 0...3600; task saves include filters and options, never destructive-confirmation authorization.
- Runner handles FK ordering, deferred constraints, backup rename/rebuild, schema objects, persistent task journal and cancellation. QueryCraft existing import/export primitives are reusable but do not themselves provide full transfer semantics.
- Existing project working tree has only unrelated untracked Xcode shared-data folder and earlier planning logs.

## Built-in palette readability correction

- All previous built-ins failed some selected-text combinations (dark comments around 2.9:1). Updated all three presets in both modes: deeper light accents, lower-luminance dark selection fills and brighter weak dark accents/comments while preserving hue families.
- Preset checks now require every normal/current-line/selection/gutter/cursor/search result to meet existing 4.5:1 text or 3:1 cursor targets. Advisory calculation also considers actual unfocused grayscale selection over both normal/current-line backgrounds.
- All six built-in cases and native palette/search rendering passed. User override persistence remains unchanged; applying a pure built-in resolves new constants automatically. Shared theme applies to SQL (MySQL/PostgreSQL/Doris), Redis/Kafka shared JSON, and Elasticsearch request/JSON views; no driver or execution changes.

- SQL uses a pinned tree-sitter grammar with display-only ADD INDEX recovery.
- Current numeric captures cover integers and decimals; scientific notation needs verification.
- MySQL/PostgreSQL/Doris use shared SQL; Redis/Kafka use shared JSON; Elasticsearch combines request lines and JSON.
- No driver protocol or binary changes planned. Test fixtures must not execute database operations.
- First 30-case SQL corpus produced 25 assertion issues. Confirmed missing CTE/constraint/schema/reference captures, uppercase exponent/hex coloring, :: operator and Doris CREATE TABLE tail support.
- Some issues were test assumptions: transaction recovery emits one range for multiple keywords; table qualifiers are objects whereas alias declarations are variables. Assertions now verify coverage per character.
- Bare PostgreSQL double-quoted column expressions remain ambiguous in the shared dialect-free grammar; qualified quoted columns can be tested unambiguously. Do not globally recolor MySQL double-quoted strings as columns.
- Verified upstream JSON v0.24.8 grammar itself omits plus signs in exponents and captures only the Unicode escape prefix. Added reviewed grammar input and reproducible generator with both corrections.
- Elasticsearch query strings were all assigned numeric color. Split into parameter names, scalar values and punctuation; comment lines now receive comment color.
- Elasticsearch body coloring previously depended on successful execution-path validation of the entire document. Added tolerant display-only body boundaries, including CRLF, so editing an invalid path does not clear other JSON highlights.
- Multi-request rendering also required sorted capture output. Bodies now have independent immutable fragment parsers, so an unfinished earlier object cannot consume a later request's JSON. Cached bodies survive unrelated edits; asynchronous results check source revision.
- Completed JSON keys in unfinished object/array values were classified as strings. Added an ERROR-node query anchored to the following colon.
- Expanded regressions found two obsolete light/dark reader assertions expecting JSON keys as type; updated them to the new dedicated property category and verified that category's rendered color.

## Expanded follow-up findings

- 130 annotated fixtures now cover 78 SQL, 28 JSON and 24 Elasticsearch inputs. Both complete and partial captures are checked; empty inputs must produce no stale/out-of-bounds captures.
- New SQL failures were real: CHANGE COLUMN old names and CREATE SCHEMA names lacked specialized captures; typed literal prefixes were ordinary identifiers; upstream quote regexes split doubled quotes/backticks into separate names.
- Added scoped query captures for old column names, schema names and built-in typed-literal prefixes. Fixed both quoted-token regexes and regenerated the pinned parser (only two generated lexer transitions changed).
- Structural regression verifies escaped identifiers/strings containing semicolons, DROP/DELETE and comment markers remain inside the original read statement. This grammar change has structural effects; it is not a display-only fallback. Formatting, completion, execution target and batch preflight tests were therefore included in the expanded suite.
- 216 SQL middle edit/undo transitions and 36 JSON/request edits matched fresh parses. Existing per-character input/deletion and stale asynchronous result tests also passed.
- 300-statement SQL, 180-document JSON and 180-request Elasticsearch sources retained all expected captures and matched full-document clipping across narrow viewports, including UTF-16 interiors. JSON/request large-document middle edits also matched fresh parsing.
- Final expanded verification: 207 tests in 15 suites passed; Debug build passed. No live database/HTTP execution, driver binaries or protocol changes. Existing dialect ambiguity for bare double quotes remains documented.

## Full customization decisions

- Color editing uses a separate bounded history (100 snapshots), coalescing native-well drag changes; editor document undo remains independent. Session restore is itself undoable.
- Personal themes persist separately from active palettes. Strict version-1 JSON import validates all roles, color syntax, name and file size before applying. Export stores resolved light/dark colors and typography.
- Native color wells are keyed by appearance and role and deactivate/detach callbacks on removal. HEX changes commit only when valid. No real desktop input simulation is used.
- Added line numbers/current line numbers, inactive/active search fills and active search text. Search layers recolor in place; original selection color is updated so closing search cannot restore a stale palette.
- Settings now adapt between side-by-side and stacked layouts; five editable previews use actual providers and map caret captures to roles. Readability checks cover normal/current-line/selection backgrounds and search/cursor surfaces without overriding user choices.
- Dialect context comes from the connection type. PostgreSQL and explicit per-connection ANSI_QUOTES use a separate, UTF-16-preserving display tree for quoted identifiers. Execution/formatting trees stay unchanged; the override is a display setting, not a claimed server sql_mode value. MySQL/Doris override is available from the query editor context menu and follows the connection across databases.
- Data-path assessment: MySQL/PostgreSQL/Doris query, DDL and executed-SQL viewers carry display context. Redis/Kafka continue shared JSON; Elasticsearch uses request/body provider. External drivers/protocols are unchanged.
- Theme attribute updates now merge attributes so input-method marked-text decoration survives recoloring.

## Full customization completion

310 tests in 23 suites passed, plus isolated MB performance and six-palette search layer verification. Final design/coverage/limits and Dev marker are recorded in docs/superpowers/plans/2026-10-14-editor-colors.md. Significant performance causes included indexed tree traversal, repeated whole-document scans and Swift canonical Unicode string equality; reuse remains guarded by tree identity and reliable unchanged statement boundaries.
# Final editor regression (2026-10-14 afternoon)

- Live MySQL DDL exposed missing function-index/foreign-key colors after an unsupported grammar construct. Added display-only recovery for CREATE TABLE index expressions and qualified REFERENCES targets, with two corpus fixtures (132 total language fixtures). This does not relax structural parse reliability or execution safety.
- Live Doris DDL additionally exposed inconsistent column/type colors after DATETIME(3). Recovery now recognizes known types at CREATE TABLE column-definition boundaries while keeping quoted/default strings opaque. Two more fixtures bring the corpus to 134; all 15 SQL color/coverage/dialect test methods passed after this fix.
- Final functional run excluded the separately checked timing case: all 317 methods in 24 suites passed. The final search-pixel pass additionally asserts that original colored glyphs cannot bleed through the match overlay; six palette combinations pass.
- The live harness initially used stale Driver API 4 paths from an older script. Current repository and Dev use Driver API 5. The new harness discovers the version from DatabaseDriverPackage.swift, supplies the Debug package-resource path, and uses each driver's appropriate authentication variant (Kafka/ES anonymous; Redis empty username/password).

- Pixel assertions reproduced a search foreground defect that attribute-only assertions missed: AppKit appended native line layers after the emphasis text layers. Refresh now keeps emphasis foreground last in painter order as well as z order. Light/dark pixel tests and six preset snapshots pass.
- Full-suite marked-text stress exposed an out-of-date asynchronous highlighting callback writing beyond the shortened text storage. Added edit revisions, query generations, a parser-edit barrier, valid-range offset adjustment, and defensive document-range clipping. Preview click-role captures also reject old revisions. Deterministic delayed-provider tests cover shorter/equal-length/Unicode replacement, out-of-order edit completion and theme invalidation.
- Executed SQL windows now apply the same bold/italic attributes as the native editor, in addition to colors.
- Theme file handling shares a tested panel-result path, bounds actual reads to 256 KiB + 1, treats cancellation as a no-op, uses security-scoped access for export too, and disambiguates duplicate theme names. Real temporary-file tests cover malformed/oversized/missing files, failed exports, cancellation, persistence and independent deletion.
- Native color-well activation, exclusive retargeting, reopening, detachment and undo boundaries pass through AppKit APIs. Five preview language providers retain Chinese/emoji marked text through theme updates and text undo/redo.
- Full functional run: 317 passed, one timing assertion failed under concurrent machine load (10K-line parse 8.31s vs 5s). The unchanged test passed separately at 2.544s. All 318 checks therefore verified; do not describe this as one entirely green full-suite run.
- MB performance rerun passed unchanged budgets: SQL parse 10.978s/edit 3.402s/viewports 63.6ms; JSON 3.438s/29.1ms/6.4ms; Elasticsearch 9.757s/432ms/116.7ms. Peak RSS growth 243 MB for SQL and 40.6 MB for ES; process high-water marks are not independent per-case memory measurements.
- No reliable desktop input isolation was available and Peekaboo was not installed. Native API/component checks do not validate physical color-wheel drags, actual file-dialog clicking, or a system IME candidate window. No OS mouse/keyboard simulation was performed.

# Final delivery verification — 2026-10-14

- Follow-up layout defect: the sheet chose the previous minimum 600-point width, triggering the vertical layout despite idealWidth 840. Restored explicit 960-point minimum and permanent left/right layout. Readability failures in the supplied preset are selected-text contrast suggestions, not syntax identification errors.

- Six installed Driver API 5 drivers passed read-only smoke against existing local MySQL/PostgreSQL/Doris/Redis/Elasticsearch/Kafka services; no Kafka consumption or offset commits. Eighteen native SQL/JSON snapshots generated.
- Final signed Dev marker 20261014-135801-41722e67 installed and launched successfully. Debug build passed. Functional suite 317 checks passed, isolated 10K timing and MB performance passed without relaxed thresholds; subsequent focused DDL/search fixes passed.
- Physical picker dragging, dialog clicking and system IME candidate interaction remain unverified because reliable desktop-input isolation is unavailable; no OS input was simulated.


- QueryCraft PostgreSQL's SHOW-like table DDL is intentionally minimal, so transfer reads pg_attribute/pg_constraint/pg_index directly rather than trusting that text. Catalog queries keep exact schema/object identities and source OIDs, without splitting display names.
- Existing MySQL executeReadOnlyQuery starts its own transaction per call. Transfer therefore uses controlled executeStatement(read) inside its own repeatable read/read-only transaction to avoid silently replacing the snapshot.
- Existing PostgreSQL driver reports transactionStateUnavailable after a successful DDL in a manual transaction; controlled rename transactions account for this specific post-execution inference error and preserve transaction ownership.
- Native commands builder exceeded its ten-content overload when adding Tools inside the existing block; Tools now registers through a separate Scene.commands modifier.

- A safety review found that comparing only profile IDs/host strings would miss aliases of the same physical database, particularly dangerous for rebuild. Planning now captures server UUID/system identifier (with PostgreSQL/MariaDB fallbacks), rejects the same real namespace across aliases, reserves target objects by physical instance identity, and revalidates that identity at execution.
- Newly copied views/materialized views/triggers/events execute after data and FKs: triggers must not fire on historical copy rows, and materialized views must see populated targets. Routines/sequences needed by defaults remain before table creation.
- MySQL same-named trigger replacement while its original table is retained as a rebuild backup is rejected before mutation; silently dropping that original trigger would damage the backup. PostgreSQL automatic structure migration rejects partition/inheritance graphs; data-only forbids simultaneously selecting ancestors and descendants to avoid duplicate rows.

## Native transfer design — 2026-10-20

- API 5 existing witness tables/layouts remain unchanged. Native write/read protocols and channels are additive. Newly packaged MySQL/PostgreSQL/Doris bundles require host 0.1.10; old installed drivers retain INSERT fallback.
- PostgreSQL COPY IN + matching-layout COPY OUT relay; single-row source reads when conversion is needed. MySQL controlled LOCAL INFILE with in-memory token only, unbuffered source reads, warning rejection and row-count validation.
- Bounded async/C bridges: one prefetch batch (bounded to configured rows or 1 MiB, plus largest row), 256 KiB encoded chunks, 64 KiB native writes. Cancellation wakes both ends; dedicated source connections are discarded on failure rather than draining remaining rows.
- Native Upsert stages into a private temporary table with an indexed ordinal, then merges in original configured ordered batches. No REPLACE, deduplication, disabled triggers, global server configuration changes or client files.
- PostgreSQL RLS/rules/statement-level triggers use existing INSERT semantics. Doris remains source-only; Redis/Elasticsearch/Kafka are not relational transfer endpoints. The modified shared MariaDB transport also requires rebuilding/packaging Doris.
- First focused regression caught an inferred GRDB.SQL interpolation in the new LOAD SET mapping (fixed by explicit String map returns), plus a test endpoint/schema expectation. The remaining 36 methods passed in that first run. Final expanded verification remains pending.

### Native validation follow-up

- V2 solved the loader failure: old Doris then new MySQL, and old MySQL then new Doris, both load successfully with distinct V1/V2 transport identities.
- PostgreSQL live cases now pass actual-rule detection, RLS/statement-trigger fallback and COPY source-error rollback. Wide cross-engine testing exposed the old PG text→MySQL TEXT capacity mismatch; mapping now uses LONGTEXT (also for unbounded varchar and Doris STRING).
- Added native Doris row streaming and fixed its legacy keyless sort to use CAST AS STRING (Doris rejects CAST AS BINARY). Added streamed/batched INSERT fallback when MySQL disables LOCAL, including successful/failed/cancelled fake-session cases.
- Final expanded 44 methods passed; frozen V3 Release rebuild is running. No million/ten-million native benchmark has started before the full edge matrix passes.
- Source channel bounds: one queued batch plus current producer/consumer batches, each capped by configured row count or 1 MiB plus the largest row. Encoded stream chunks are 256 KiB and C writes 64 KiB. Memory is independent of total table cardinality.

## Native bulk transfer completed — 2026-10-20T11:49:11

- Implemented optional API 5 COPY/controlled in-memory LOAD DATA writers and bounded source streaming; PostgreSQL compatible raw COPY relay; transactional indexed Upsert staging and SAVEPOINT-protected permission fallback. Preserved exact values, warning failures, ordering and rollback. No filesystem LOCAL access.
- Final 45 regression methods passed. Live four-direction edges, DML-only users, disabled LOCAL fallback, six-driver loading and three real Doris/mixed-version combinations passed. Shared MariaDB transport uses V2 module/install name so old/new Doris and MySQL can coexist.
- Release million append/Upsert: 8 cases, all full-row values correct. Release ten-million append: MySQL→MySQL 102.057 s / 36.62 MiB; PG→PG 45.746 s / 26.34 MiB; MySQL→PG 48.941 s / 40.05 MiB; PG→MySQL 121.809 s / 40.62 MiB. RSS is one-second engine-harness sampling, not full app memory. Native path proven by progress messages.
- Six real cancellation cases passed with zero committed rows; overwrite restored sentinel, staged Upsert restored all 1M original rows. MySQL cancellation took 0.722/0.724/4.280 s; PG 0.109/0.109/0.107 s. All owned Docker containers/volumes removed.
- Artifact roots: .build/validation/transfer-performance/20261020-113229-5a65b4 and 20261020-113616-289698; include results, logs/RSS, environment and host/driver fingerprints. Full results and limits: docs/DATABASE_TRANSFER.md. Doris real small samples only, MariaDB server untested; Redis/ES/Kafka outside relational transfer. No visible UI/physical-input verification.
- Installed and launched signed Release Dev 20261020-114655-8a63b4d1, feature UUID 3CDC441A-DED7-3F94-8738-401A8C71EC0C, MySQL/PG/Doris local 1.0.6 build 8 (API5, min app0.1.10). Installed full-bundle hashes and six driver binary hashes match benchmark artifacts; installed-host six-driver load passed; actual Dev PID68023 loaded six installed drivers and V2 framework. Normal quit only; old app/driver backups retained. No commit/tag/public release.


## iOS / iPad proof — 2026-10-22

- Managed worktree: ios-ipad-proof/QueryCraftPublic from current HEAD; primary checkout has unrelated uncommitted planning records.
- Local TablePro is a source snapshot without .git or prebuilt iOS libraries. It separates iOS UI/core and statically links C libraries. Reference only; implement original project code.
- Existing MariaDB transport directly imports Feature and uses shared bulk-transfer/session models. Need a narrow source-sharing proof without migrating published Driver API types between modules.

- iPad simulator tests: 14 passed, including five real MySQL/TLS/error/cancellation checks, explicit refusal of unimplemented verified-TLS modes, and eight deterministic UI-state checks. First duplicate static test dependencies caused error-type identity mismatch; tests now link through their app host only.
- Discovered Connector/C 3.4.9 loopback TLS behavior in plugins/auth/my_auth.c: certificate verification flags omit trust/hostname without explicit CA. Mobile proof now advertises encrypted-but-unverified mode honestly and rejects verifyCA/verifyIdentity before connecting. Desktop TLS unchanged.
- All native slices built/checksummed: x86_64 simulator, arm64 device and arm64 simulator. Final unsigned device target compiled without warnings.
- Real iPad screenshot shows 2 rows / 4 columns from the isolated read-only MySQL fixture; no physical desktop input. Native accessibility snapshot tool returned a translation error despite successful screenshot, so physical interaction is not claimed.

- Fresh MySQL/Doris local packages passed signature validation and mixed activation with the other four existing API5 drivers. Fresh MySQL read 2 rows over TLS with alias origin preserved. These were isolated worktree packages; installed Dev unchanged and Doris live server untested.


## MySQL mobile first usable version — 2026-10-22

- Current prototype stores credentials only in memory, opens one connection per SQL execution, and collects unbounded query results before rendering 500 rows. These need explicit persistence and bounded loading for daily use.
- Keep desktop type/module identity and existing transport query behavior unchanged; introduce additive bounded result APIs for mobile rather than changing CDatabaseQueryResult layout.
- Existing MySQL metadata uses real protocol origins and information_schema; do not infer origin/comments from display names. Mobile table browsing can use explicit schema/name and ordinal metadata, while arbitrary query expressions retain no guessed comments.

### MySQL mobile first version / native UI findings (2026-10-22)

- Ported only MySQL for mobile: connection/Keychain, catalog/schema, native paged table/record views, read-only SQL/history and cancellation. Kept original desktop query semantics and Feature nominal types; shared bounded column sampling/cell preview.
- Native row/byte-bounded preview must close a truncated unbuffered MariaDB socket before free_result; row/byte cap tests and explicit reconnect passed. Zero retained rows caused by truncation are not a successful empty result.
- Real simulator Keychain tests require a signed host: disabled-signing proof returned -34018. Simulator-only ad-hoc signing fixed read/update/delete; device signing remains the user's developer configuration.
- Actual UI inspection caught unchanged headers preventing first-row auto-sizing and old native cells persisting after model object changes. Added native UICollectionView update regression; shared async state tests cover late replies and retained refresh.
- UI references are TablePro mobile source snapshot information architecture. Current implementation is native SwiftUI/UIKit with independently written data/grid/state code and system Liquid Glass controls on OS26; structured metadata uses native grouped lists.
- Final functional matrix: 32 tests per iPhone/iPad, fresh Mac build, old six-driver loading, new MySQL/Doris package signatures, fresh mixed-driver loading and true MySQL TLS/alias-origin query passed. Native device target remains unsigned, physical touch/IME/rotation not verified. Exact evidence is in QueryCraftMobile/VALIDATION.md.


### 2026-10-22 — Mobile system Glass navigation

Native SwiftUI TabView with iOS18 Tab declarations automatically renders the iOS26 Glass navigation requested by the user; no custom tab background or drawing is needed. iPhone places tabs at the bottom while iPad adapts them to the top. Object browsing stays in NavigationSplitView; query is a separate NavigationStack. Table and view filtering belongs in the metadata SQL before its 201-row limit, otherwise a view-only UI could silently omit views after 200 table rows.

Swift 6.2.4 on Intel crashed in IR generation when passing the actor-isolated selectTab method reference directly as a Binding setter. An explicit closure `{ app.selectTab($0) }` compiles successfully for simulator and ARM64 device. This changes no behavior.

This follow-up modifies only mobile code. MySQL is covered by the fixture; PostgreSQL/Doris/Redis/Elasticsearch/Kafka desktop driver chains and UI are unaffected and remain outside the mobile scope. The new native navigation is real rendering, not a screenshot mockup; no physical desktop input or real-device touch validation was performed.

### Mobile data/search follow-up — 2026-10-22

User clarified ordered-subsequence search: admin_user must match ad and amu. The actual Mac object list (WorkspaceDatabaseItems) uses CompletionLabelMatcher; visibleDatabases' contains check is only the database visibility layer. Reuse that existing Foundation-only matcher source in the mobile application target without editing desktop semantics. Cached complete bounded metadata is needed so local fuzzy matching does not silently miss objects beyond a 200-item catalog window. Default native grid and an inline status/pagination footer remove repeated wide-record cards and the extra floating Glass control layer above the native navigation tabs.

### Final shared-search and compact-detail findings — 2026-10-22

- The user explicitly requires mobile functionality to follow existing desktop implementations without repeated explanations. Persisted this in the primary checkout and managed worktree AGENTS.md. Primary checkout changes are limited to this requested instruction section.
- Matching and ranking are now one shared CompletionLabelMatcher.matching implementation used by both desktop WorkspaceDatabaseItems and mobile. Desktop original tiers, scores, stable ties and empty order are preserved; tested the actual compiled desktop entry independently.
- A Mac test attempt found that QueryCraftFeature's Xcode scheme has no test action. It did not run any tests and is not a pass. The full desktop app build succeeded; a small isolated executable invoked the compiled @testable desktop entry and passed the existing bo regression and requested admin_user/ad/amu ranking across table/view/ES resource kinds.
- Full local metadata search removes the SQL LOCATE collation dependency and the 200-object search window. Existing metadata row/byte limits explicitly fail instead of silently returning incomplete search results. Repeated typing makes no network calls.
- iPhone landscape orientations were missing from generated Info.plist. Added the standard portrait/left/right set while keeping iPad's four orientations. Native phone right-landscape rendering and grid viewport changes were checked without desktop input simulation. The iPad geometry request did not rotate the simulator window, so its screenshot validates split layout, not physical rotation.
- Final table detail uses the system title menu for Data/Structure, hides the main tabs in compact width/height, keeps regular iPad top tabs, and leaves only one status/pagination footer. This prevents both wasted phone space and a navigation dead end in an iPad split view.

### Mobile fullscreen and strict drag axis — 2026-10-22

The SDK describes isDirectionalLockEnabled as trying to lock direction, which does not guarantee a single axis for diagonal drags. Keep it enabled and additionally constrain scroll offsets and deceleration targets in the shared mobile grid delegate. Determine the dominant starting pan translation/velocity, wait out tiny ambiguous motion, hold the axis across an ongoing same-object refresh, and release on ending/cancel/context or explicit viewport restoration. Header-only resizing must not intercept data-cell swipes.

Full screen is a native cover without a navigation container, using the existing renderer and current typed page/result. Share non-observable viewport state with an owner token so background layout callbacks cannot overwrite full-screen scrolling. Normal mode applies that state after dismissal, preserving widths/selection/context. A hidden exit button remains structurally present for keyboard Escape, and accessibility escape is available; VoiceOver retains the visible control. Screenshot probes use Debug-only launch environment flags and do not supply those flags to the user's real device install.

### Fullscreen follow-up: hardware occlusion and retained keyboard

User screenshots show readable grid content extending beneath hardware occlusion and a third-party search keyboard in landscape. Fullscreen grid currently ignores all safe areas; the background can extend to edges, but readable content must honor the system safe area. Catalog has no explicit search focus binding/reset on navigation; results search and SQL editor also have no explicit focus reset before fullscreen. Fix these related entry paths and enforce no text input only within the fullscreen presentation's own window, without changing Mac/driver/business logic or clearing search data.

### Next parity increment: actual grid find

Mac uses WorkspaceGridSearchController + WorkspaceGridSearchWorker, not row filtering: contains/equals/beginsWith/endsWith, case-sensitive option, all/selected column, per-cell matches, wraparound next/previous, 10,000-match cap, 180 ms debounce/cancellation/generation checks. NULL and binary are searchable using original typed cell display semantics. Mobile currently filters rows with localizedStandardContains, renumbering visible rows and offering none of these controls. Share the existing worker/controller through a Sendable source protocol; keep Mac concrete enum convenience overloads so existing callers retain source syntax. SQL MySQL/PG/Doris, ES/Kafka grid pages and Redis collection local find share this worker; protocol/bindings/external drivers do not change. Mobile remains bounded to loaded table page or query result, as before.

## Timestamp display parity

- Mac's actual renderer calls WorkspaceTimestampDisplayFormatter through WorkspaceDirectDrawTableView.cellPreview; mode state resets only when scope or complete metadata changes. Header menu selects automatic/raw/seconds/milliseconds; lookup/copy/export continue using original typed cells.
- Formatter checks protocol type plus displayed/origin field name, recognizes bounded integer epochs, uses current time zone and caches up to 4,096 values. Mobile previously discarded workspaceColumns metadata and rendered only raw previews.
- Mobile can directly compile this formatter and use the transport's existing workspaceColumns adapter, without driver/API changes. SQL aliases retain source hints, expressions never acquire guessed origins. MySQL is the only mobile driver. Desktop MySQL/PostgreSQL/Doris and ES/Kafka grids keep existing formatter settings; Redis custom views retain their current path. No other driver mobile support is implied.

## MySQL server filter parity

- Actual Mac source: MySQLWorkspaceSession.makeFilterPredicate builds typed string bindings and SQL WHERE using WorkspaceDatabaseDataFilter/Condition/Operator/ColumnKind; all/any logic and enabled conditions, three LIKE operations with explicit backslash ESCAPE, numeric validation, NULL/between. Shared default enum/bool values and condition setup currently live in WorkspaceDatabaseColumn+DataFilter.
- Mobile table service currently issues SELECT * with ORDER/LIMIT/OFFSET but no WHERE. The existing bounded preview transport has no binding overload. Keep that bounded transport unchanged: shared predicate generator will support rendering its same string values as UTF-8 hex literals for mobile, while desktop retains existing bindings. This also supports identifiers containing '?' without using the desktop placeholder scanner. No user text enters SQL quoting directly.
- Shared SQL source belongs to the MySQL driver target and is directly compiled into mobile. This avoids new host ABI dependencies; only MySQL driver needs rebuilding/packaging. PG/Doris use independent predicate implementations; ES/Kafka have separate semantics; Redis does not use this SQL table path. Existing shared models/validation remain unchanged, other mobile drivers deferred.

## Loaded-data export parity

- Actual Mac WorkspaceDataExportController takes immutable raw typed rows/column mapping and preferences; WorkspaceDataExporter is a Foundation/zlib actor supporting XLSX/CSV/JSON/SQL, atomic replacement and cancellation. CSV BOM/CRLF/formula sanitization and JSON strings/duplicate names/binary descriptions must remain unchanged. SQL binary values are explicitly unsupported.
- Copy column/row range/snapshot types are currently embedded in an AppKit encoder. Extract only these unchanged types into a Foundation file, keep nominal module identity. Directly compile writer/request/format/preferences/dialect into mobile; conditional Core imports only. Mac preferences default JSON objects (not the lower-level options default tabular), transaction wrapping false.
- MySQL mobile only: current committed page/result raw values, no automatic whole-table fetch or SQL rewrite. PostgreSQL/Doris retain SQL dialect semantics; Redis/ES/Kafka nonSQL exports retain desktop behavior and unavailable SQL; no driver/API change. All six shared exporter consumers need Mac build/compatibility evaluation, no new other-driver mobile support.

## SQL editor parity

- Actual Mac completion: WorkspaceSQLLanguageService -> SQLStructuralParser -> SQLCompletionWorker/Engine/Ranker; WorkspaceSQLCompletionService requests referenced relation columns lazily and repeats completion against newer schema. Completion apply validates source revision, caret/replacement boundary and marked text, then applies insertion/cursor offset/placeholder ranges.
- Parser is Foundation + SwiftTreeSitter + local CodeEditLanguages SQL grammar/highlight resource, no AppKit implementation dependency. Language package only declares macOS but its source is portable; add iOS platform declaration. Share complete source/parser/query/recovery/context logic, not a regex keyword approximation. Mac adapter remains intact.
- Mobile needs a UIKit UITextView adapter for attributed syntax, caret/IME/undo, and anchored touch completion presentation. Same completion engine/catalog types/dialect; metadata fetched from existing bounded MySQL catalog/column service, generation-bound to connection/database. SQL read-only execution policy unchanged; no additional mobile drivers.

- Both platforms use the Mac parser/completion suites directly (conditional imports and same fixture files), rather than copied approximations. Theme source uses conditional UIKit/AppKit adapters; default palette hex and semantics unchanged.
- Native long-draft verification now uses the exact product UITextView factory; targeted five-case native editor suite passed (22.778s), including viewport offset preservation. First full iPad attempt with a default-font test view failed and remains recorded. Mac native three-dialect/highlight/source guards and six-driver/new-MySQL catalog metadata checks passed.

## Whole-table export parity

- Mac grid path: WorkspaceModel.dataExportAllRowsProvider captures configuration/selection/sort/filter, supplies WorkspaceTableDataExportRowSource to the same WorkspaceDataExporter. Direct sidebar table export separately validates lossless values and generated columns; it is not the grid scope path.
- Current Mac table source paginates 5,000 rows, writes each batch and closes its independent session. Mobile uses its existing read-only page executor, 200 rows / 8 MiB cap, independent connections; no accumulation of all pages. Extract batch progression/schema checks into a common source, keep Mac page-size/session/validation unchanged.
- Scope semantics: current loaded data remains default, all matched rows starts offset zero with committed filter and sort, includes views on their data pages. Loaded SQL query exports stay bounded previews; no arbitrary-query rerun or write operation. OFFSET paging is not a snapshot against concurrent server writes; document this existing limitation.
- MySQL mobile only. Desktop MySQL/PostgreSQL/Doris use paged adapter; Redis/ES/Kafka writer and existing adapters remain unchanged, no mobile support implied and no driver protocol change.

## Mobile MySQL data editing

- Actual Mac uses WorkspaceDatabaseDataCellEditRequest/RowInsertRequest/RowDeleteRequest, groups cell updates per original primary key, previews MySQL statement tokens and uses WorkspaceSafetyLock before a fresh change-session applyDataChanges transaction. Delete → grouped updates → inserts, exact affected-row checks, COMMIT or ROLLBACK. WHERE currently uses primary keys, not optimistic original-value comparisons; retain/document actual semantics.
- Share column-array overloads for request preparation so mobile need not compile desktop page-store/schema-detail UI; keep old Mac signatures as wrappers. Compile the same data changes/models/SQL generators. Extract exact MySQL transactional runner into shared Foundation source used by driver/mobile; no arbitrary write SQL bypass of mobile read-only query editor.
- Base tables only; generated columns and preview-only binary cells/keys rejected; missing PK blocks update/delete. Inserts use shared default/NULL/unfilled semantics. Mobile needs drafts retained per object across page/filter/navigation, committed metadata/raw key matching, no automatic write retry. Unknown COMMIT outcomes must not be blindly resubmitted.
- MySQL mobile scope only. PostgreSQL/Doris retain separate mutation execution, Redis/ES their own operations, Kafka unported per user. Shared request wrappers/selection models must preserve six desktop drivers; driver build/package/load and real owned MySQL writes will be verified separately.

- Confirmed the existing transport uses typed placeholder resolution plus MariaDB's server-status-aware escape implementation (connector mariadb_lib.c switches to quote escaping under NO_BACKSLASH_ESCAPES), not server prepared statements. Kept transport behavior unchanged. Its inherited placeholder resolver does not skip `?` inside quoted identifiers, so such identifiers remain a documented unsupported case rather than a false parity claim.

## SQL result editing investigation

- Mac WorkspaceQueryResultEditing resolves a single physical table from non-nil column origins; query expressions have nil origin. Metadata comes from an independently validated base-table session. Pending updates/deletes use original raw primary keys, same safety lock and mutation transaction; success patches the captured result store, never executes the draft SQL.
- Mobile will reuse resolver and existing table staging/request/preview/transaction UI. Keep executed configuration separate from editor draft, fence metadata responses, block destructive result replacement while changes exist. Query result path does not offer inserts.
- Query PK resolution must not accept a nil-origin expression called id, or differing duplicate PK projections. Guard these in shared query preparation, without changing ordinary table requests. Protocol origin lacks relation alias: mobile only enables editing for a reliably parsed single physical relation; joins/CTEs/subqueries remain readable and explicitly outside this editing increment.

- Actual owned MySQL tests confirm quoted Unicode/duplicate aliases keep physical origins; an expression named id has nil origin and must never supply a key even before a real aliased id. Shared Mac/mobile query preparation now enforces this. Self-join metadata uses the same original physical table and cannot retain relation aliases, so mobile restricts reliable single-relation edit scope.
- Submitted result patches keep executed identity separate from data revision, preserving history/draft/timestamp scope; defaults are unknown until requery, and an uncertain commit is never replayed. Native tap-to-editor/Done/pending geometry verified on both simulator sizes.

## Fullscreen and record editing investigation

- Mac table coordinator prepareCellEdit/Async and query inspector withDataEditing both use the same raw row/column target and common requests; field edits become staged mutations then shared pending preview/lock/session submission. No independent per-inspector SQL writer.
- Mobile regular grid already uses those shared requests; fullscreen and record inspectors currently freeze displayed data. Fullscreen input guard dismisses all responders in its window, including a future sheet editor, so it must suspend only for its own sheet lifecycle.
- Add a UI-only observable source adapter with raw result/page revision distinct from pending revision. Same context refresh updates live data and invalidates captured edit generations; object/query/page changes invalidate and dismiss old presentations. Derive pending data through the existing MobileTableChanges instance; no driver or transaction implementation changes.
- Applies to MySQL table pages and supported single-relation query results on mobile. Existing readonly views/joins/expressions/no-key/binary/generated guard behavior remains. PostgreSQL/Doris desktop requests, Redis/ES specialized mutations and Kafka are untouched; no new mobile support claimed for those five.

- Native validation reproduced keyboard-driven background viewport movement; fullscreen now ignores only keyboard safe-area changes (hardware safe areas retained), freezes viewport writes during its sheet and restores on dismissal. Guard authorizes input by actual presented controller/responder ancestry, so UIKit sheet dismissal and delayed keyboard notifications cannot leave suppression disabled or close the legitimate editor.
- The initial iPad native offset assertion used x=50 even when all four fixture columns fit its viewport; normal grid correctly clamps this invalid offset to zero on pending repaint. Test now starts with a valid horizontal offset; separate existing narrow-grid tests already cover nonzero horizontal restoration.
- Render review found the inherited medium-height record sheet showed only two fields on a landscape iPad. Record details now opens at the large detent (medium still available), preserving its native layout and giving the field list useful height.

## Mobile connection/background reliability — 2026-10-22

- Actual Mac refreshDatabases validates the session and returns reconnectRequired; connectedDataSession replaces dead data sessions. Mobile already opens a fresh connection per read/transaction, so public refresh is the reconnect path. No reachability-derived online badge or automatic replay. Shared Connector/C timeouts remain unchanged.
- Found rollback was gated by UI authorization: background relocking could prevent explicit ROLLBACK. Mobile cleanup now bypasses authorization/cancellation and closes in all exits. COMMIT checks authorization/cancellation before invocation; invocation failure is uncertain.
- Found ordinary table uncertain-draft discard could permit editing stale data after failed verification. Reload fence now clears only on successful table data/metadata receipt; query explicit-rerun fence remains.
- Background cancels read generations, retains data/drafts, relocks and cancels writes, with bounded UIApplication cleanup time. Schema tasks pause; export cancels unfinished generation and retains completed Files input. No persistent recovery requested.
- Initial focused state run: 5/0/0. First full phone: 259 pass / 1 fail / 0 skipped: standalone export UIHostingController inherited background scenePhase. Its visible-window test now supplies the foreground environment; production guards remain. Initial previewSQL compiler expression-timeout diagnostic fixed by splitting preview arrays. Neither failure is counted as acceptance.
- Final phone: 261/0/0, 47.524 seconds. Actual MySQL transactions exercise rollback after a write, disconnect before COMMIT, server commit with lost acknowledgement and cancellation while COMMIT acknowledgement is withheld. Lost acknowledgement is deliberately injected after real COMMIT, not a claim of physical packet-loss testing. Native fixed-frame/viewport/selection and Files lifetime checks pass. ARM64 signed build: 30.283 seconds, strict deep signature verification passed. Physical phone currently disconnected, latest build not installed.

- Final follow-up also fences confirmed table commits finishing in background until explicit successful reload. Final phone/iPad each 262/0/0 (49.511 / 49.744 s); signed ARM64 final build 22.346 s and strict deep signature passed. Only retained experience container remains after fixture cleanup.

## SQL selection/current statement — 2026-10-22

- Traced the real Mac command/language-service/resolver/preflight/document flow. Seven exact source files and 24 unchanged shared behavior tests now compile in mobile; four source files only add conditional iOS Core imports, desktop logic untouched.
- Captured actual UIKit selection/IME plus document revision, with model-owned selection for navigation recreation. Preflight runs before connecting; all pending, context, background and stale response guards remain. Metadata/history use the executed fragment, not the full multi-statement draft. Public refresh reuses the displayed/attempted SQL independently of edits/caret, resetting on endpoint change.
- Initial compile missed an iOS Core import in preflight; fixed. First focused run was terminated because reused parser instances reject equal revisions and an existing continuation-based test waited for a second request that could not start. Planner now uses an independent bounded parser per explicit run; no analysis cache is shared across overlapping executions. Fake execution tests explicitly inject fake metadata, preventing incidental local service access.
- First focused native/state run 42 pass / 2 fail: whitespace fixture selected a comment (Mac treats it as explicit meaningful selection), and test incorrectly assumed a derived-table subquery was reliably classified. Corrected fixtures against the actual Mac plan and added explicit identical rejection coverage; no parser rules were loosened. Native actual-selection/Cmd-Return and IME tests passed.
- Final phone full: 302/0/0, 44.046 s. Actual MySQL current statement, selected prefix, quoted semicolons/Unicode/null/empty, physical editing source and unsafe batch preservation passed. Mac full build 56.001 s; actual compiled mysql/PG/Doris range/preflight and unchanged document batch checks passed. Six driver bundles loaded/activated/session factories created. Command-line Mac harness initially lacked grammar bundle lookup; rerun with PACKAGE_RESOURCE_BUNDLE_PATH pointed to actual built product resources passed; app resources were already correct.

- Final iPad 302/0/0 (49.880 s), signed ARM64 17.587 s and strict deep signature passed; phone disconnected. Three-statement MySQL phone/iPad renders inspected, only owned retained experience container remains.

## Six table operations — 2026-10-23

- Traced actual Mac menu/sheet/model/session chain; shared its six-action SQL, input validation/copy/capabilities unchanged. Added portable WorkspaceDatabaseObject to mobile Core and exposed the same selection.object accessor there; Mac body unchanged. Original six pure/parameterized action tests run on mobile; two Mac-specific model tests remain Mac-only.
- Native confirmation uses exact table name for destructive operations, SQL preview and shared safety lock. Fresh server table identity/actual auto-column check precedes action SQL. DELETE/TRUNCATE remain distinct; all writes are single captured shared commands on a fresh connection, with no transaction/rollback claim for DDL.
- Found comment-sensitive equality could miss pending edits on the same physical table. Fixed this chain to compare database/name/kind selections in pending-query guard, affected-query/browser invalidation and navigation. Added regression preserving unrelated query drafts.
- Initial compile had a let-root Binding path, fixed to explicit sheet binding. Initial test compile had a configuration-name shadow and wrong error-domain constructor, fixed. First native/state had identity guard failure and a keyboard assertion; identity fix verified. Keyboard test had called only delegate.shouldReturn, omitting UIKit's editingDidEndOnExit control event; now exercises the real submit event chain, keeping the close assertion. Product also synchronously ends its app responder when native submit precedes focus binding publication.
- First full phone: 322/1/0, only the incomplete synthetic Return event failed; all seven/six live-operation behaviors passed. Subsequent full phone .build/table-actions-phone-final.json: 323/0/0, 49.146 s. Added a real App-route rename/drop check afterwards for final acceptance. Actual clear preserves next ID and DELETE trigger effects, truncate restarts ID=1, rename preserves data with quoted identifier, auto values follow server rules, no-auto/view/permission/FK reject without bypass. Lost acknowledgement after real autocommitted TRUNCATE fences repeated writes and survives reopen.
- Mac full build .build/table-actions-mac-build.json: success 136.968 s. Actual compiled six-driver action capability/SQL check and all six isolated driver activation/session factories passed; no external driver source/package replacement. Only owned test database received DDL grants; retained simulator experience uses a separate owned table-action DB and memory-only profile.

- Final acceptance after adding actual App-route rename/drop: phone 324/0/0 (46.238 s), iPad 324/0/0 (57.002 s). Signed ARM64 36.617 s and strict deep signature passed, physical disconnected. Native six-operation previews and normal owned table experiences inspected; transient fixture cleanup and final whitespace/shell checks passed.


## Schema editing exploration — 2026-10-23

Mac has portable WorkspaceDatabaseSchemaEditorState + editing descriptor + provider/execution plan and MySQLSchemaEditingProvider. Mobile structure currently only MobileTableColumn from SHOW FULL COLUMNS, no index snapshot. Need actual full metadata (including generation expression/visibility/options) before editing to avoid destructive omission. User explicitly requests both grid and list like data, backed by the same drafts.

- Mac MySQL fetchDetails had generationExpression hardcoded empty; extracted its real field/index conversion into MySQLTableSchemaMetadata with generation expression included, consumed by both platforms. Shared provider, statement and schema editor compile unchanged except conditional imports; catalog UI option bridge is platform-neutral. External MySQL driver must be rebuilt/packaged/loaded this increment.

- User also requests catalog/sidebar background matching detail in dark appearance. Catalog now hides the default scroll background and explicitly uses systemBackground plus the navigation bar background, preserving native search/button materials and light/dark adaptation. Include dark native render acceptance in this increment.

- Implemented common per-object schema draft, native field/index sheets and two presentations. Shared grid retains one-axis scrolling, widths/viewport; list uses stable row IDs. Submission uses exact Mac plans on fresh connections, revalidates complete field/index metadata and authorization before sends; confirmed prefixes/unknown acknowledgement fence replays. Initial simulator compilation succeeded (50.889 s), tests and desktop build now running.

- First full owned MySQL phone run passed 338/0/0 (93.550 s). Covers real field/default/null/comment/rename/generated/hidden preservation, index expression/prefix/descending/invisible/unique preservation, add/drop, stale/permission/auth guards, actual partial DDL and injected lost acknowledgement after real DDL. Two native schema presentation checks were added afterwards, so final acceptance must regenerate project and rerun.

- Corrected a read-only regression before acceptance: reading view fields must not add a SHOW VIEW privilege requirement. View structure uses real shared column metadata and no table/index mutation/DDL. Added actual SELECT-only view metadata coverage, background-cancel state and actual cancellation between two DDL statements. Partial errors preserve the single original error/count instead of nested wrapping.

- Native follow-up underlying test report passed 340/0/0 (59.464 s), no diagnostics. Its wrapper failed after tests with an unexpected EOF because the fixture script was edited while Bash was still reading it; source now passes bash -n. Treat wrapper as failed, preserve report, freeze fixture script during final runs. Three additional view/cancellation regressions require final 343-case acceptance.


## Continuation audit — 2026-10-23

The mobile catalog already uses opaque semantic systemBackground for content/navigation/footer in the recovered source. Verify split sidebar native rendering in dark mode. Mac Settings currently leaves both List sidebar and grouped Form detail backgrounds transparent, allowing the split-view material/window backing to appear brighter. Apply a consistent opaque semantic background while keeping native grouped controls and the existing settings/navigation architecture.

- Recovery removed ignored native SDK slices and prior test reports; rebuilt isolated CMake dependency and started checksum-verified OpenSSL/MariaDB slices for simulator/device. Docker was not running, so started it in background for the existing disposable test fixture. The installed Docker CLI predates `docker desktop start`; no user containers or databases were changed.
- iPad UIKit split sidebars may resolve systemBackground using elevated appearance. Resolve the sidebar surface with base interface level plus the current SwiftUI color scheme/contrast, including navigation/footer, so it follows light/dark without a brighter elevated backing.

- Continuation phone full acceptance passed 343/0/0. Initial iPad run 342/1/0: `MobileSQLEditorTests.testStaleSuggestionsCannotChangeMovedCaretOrNewTextAndCommandsRemainNative` exposed stale completion candidates remaining visible while replacement parsing/debounce ran. Acceptance was already guarded, but display invalidation waited for async completion. Retire text/caret-mismatched candidates synchronously and assert that immediate invariant; preserve candidates on same-context metadata work. Rerun final native/full suites.
- iPad native dark catalog render confirms matching black sidebar/detail canvases; native schema field/grid/list renders captured. Mac native cacheDisplay attempt produced an incomplete offscreen image, so it is not visual acceptance; switch to a properly sized on-screen background window capture without desktop input. Mac complete build passed 582.420 s and signed ARM64 149.519 s, strict deep signature verified.

- Final acceptance resolved the sole iPad completion failure; phone/iPad each 343/0/0. Post-test wrapper render shutdown errors were handled by separate boot/install/capture, not hidden as passes. Actual schema index capture initially showed a field editor due DEBUG setup ordering; selected presentation/section before loading and inspected corrected index forms on both devices. Final fixture-only source change rebuilt for simulator and ARM64.
- Newly packaged MySQL actual registry/TLS smoke confirmed generation expression, hidden columns and prefix/direction/visibility/comment preservation plus generated-column edit SQL. Six original and six mixed-package factories passed. Both physical devices reconnected; latest signed product installed and launched successfully on each. No physical interaction acceptance inferred from launch.


## iPad completion visibility report

User reports SQL candidates at the very bottom, clipped and unusable. Current implementation always assigns a horizontal 44-point UIInputView as UITextView.inputAccessoryView, so iPad candidates follow keyboard location instead of caret. Geometry tests did not verify this actual presentation. Keep shared Mac completion engine/catalog/UTF-16 guards; iPad needs its own window-contained caret overlay that avoids keyboard and keeps selection reachable. Phone's existing accessory remains appropriate and must be checked.

- Actual Mac SuggestionController uses a caret anchor and constrains its popup above/below visible screen bounds. New iPad presentation follows that behavior using the actual editor window/safe area and keyboard geometry, without a second completion engine. Popup touch hit testing passes outside events through, vertically reusable rows expose details, selected rows scroll into view, and blur/Escape/deactivation remove the overlay. Phone keeps its native accessory.
- First native baseline 5/0/0 passed. Cancelled an accidentally duplicated test build before running tests concurrently on the same simulator; not acceptance. Docker was stopped, so the first full wrapper could not start; restarted the owned fixture service. An owned demo setup attempted before MySQL was ready failed; readiness checked before the successful retry. No user databases involved.

- Final iPad completion full run passed 345/0/0, including new native scroll-to-last/touch/lifecycle and portrait/landscape/narrow/floating/docked invariants. Actual SQL alias field candidates render adjacent to the caret with type details. Physical installation was attempted but failed because the previously connected iPad disconnected; user asked to reconnect. ARM64 and signature already pass.


## Touch-first iPad keyboard follow-up

Actual software keyboard was absent from the previous live render. Set Simulator ConnectHardwareKeyboard=false and reopened Simulator without synthetic desktop input; the first reopen raced asynchronous quit (-600), subsequent reopen succeeded. Actual keyboard render confirms the floating caret panel overlays the result area. User wants the software keyboard and dislikes below-SQL prompts; offered keyboard-top shelf versus a smaller caret list, proceeding with the stated keyboard-top recommendation while retaining hardware/floating-keyboard caret mode.

The iPad shelf is 76 points high with 64-point two-line touch targets and horizontal scrolling. Docked software-keyboard frames select it; external/floating modes use the existing caret popup. Candidate invalidation preserves shelf height while typing/metadata resolve so keyboard geometry does not bounce. Empty shelf is removed when the keyboard mode changes back, and all existing source/selection/IME guards remain.


Touch completion acceptance: user delegated placement. A docked full iPad software keyboard now uses a 76-point accessory shelf with 64-point two-line candidate cards and horizontal scrolling. Retaining the empty shelf while typing prevents keyboard layout jumps during parsing/metadata work; switching to hardware mode retires it and restores the caret overlay. Actual software-keyboard screenshot `ipad-completion-software-shelf.jpg` confirms three real field candidates above the keyboard without covering SQL. Floating-keyboard placement remains covered by injected geometry rather than a physical floating-keyboard session. Native transition tests remove real keyboard notification observers before injected frames, preventing mixed real/synthetic geometry from invalidating the test. Final iPad full 346/0/0 and phone focused 8/0/0, no diagnostics.


## Accepted completion repetition and shelf readability (2026-10-23)

Traced actual Mac `WorkspaceSQLCompletionService` and CodeEdit trigger model: original items insert exact text, function cursor offsets/placeholders are explicit, and the shared engine already returns contextual candidates at an empty prefix when explicitly requested. Mobile immediately rescheduled at the inserted word end, recreating the same-prefix candidates, while its display filter rejected empty-prefix next-context results. Keyboard UIInputView and collection had transparent surfaces.

Added an opt-in shared insertion plan for mobile token separation; default insertion remains exact for desktop. It appends one separator at document end or advances across an existing space/tab, without splitting punctuation/identifier suffixes, consuming newlines or moving function/placeholder/database carets. Continuation display is tied to the exact resulting text/caret, and accepted non-advancing tokens are dismissed at the new revision. Manual completion now also respects subsequent Escape dismissal during late work. Full docked shelf and collection use opaque semantic backgrounds with a top separator. First native 13/0/0; final full rerun additionally dispatches the shelf's actual collection selection callback.

Scope evaluation: MySQL/PG/Doris shared matching/ranking/context and Mac insertion entry remain unchanged; optional separator plan is currently selected only by the mobile MySQL editor. Redis/Elasticsearch/Kafka do not use SQL completion; no external driver protocol/model/package or result/table page changes.


## Mobile SQL snippets — 2026-10-23

User confirmed Mac SQL snippets (trigger expansion plus editable placeholders) and requested latest completion behavior on iPhone as well as iPad. Previous completion fix installed successfully on iPhone, but launch timed out and retry could not discover the device; final snippet delivery must recheck.

Traced Mac settings/store, `SQLSnippetTemplate`, completion sources/ranking, `WorkspaceSQLCompletionService` and `SQLSnippetSession`. Mobile now compiles the actual store and session with conditional native view adapters; placeholder ownership, range shifts, empty stops, Tab/backtab wrapping, filled hints and exit positions remain one shared implementation. Mac trigger validation now also delegates to a shared store rule without changing whitespace/case/duplicate behavior. Mobile uses the same eleven built-ins and native CRUD/toggle/restore UI with per-device persistence (no cloud sync), and existing SQL header touch controls. Read-only execution policy is unchanged by templates.

First focused run 38 passed / 1 failed: UIKit IME emits repeated selection/text callbacks while parser source is intentionally frozen during composition. Using parser source to derive every session edit replayed the same mutation and ended the snippet. Added a separate last-observed native text for snippet edit extraction, updated before callbacks, leaving parsing/highlighting/completion suppression during marked text intact. Native template-content input also disables smart quotes/dashes and autocorrection to retain literal SQL and placeholder punctuation. First native dark/light navigation and manager/template renders inspected; final acceptance pending.

## Large SQL and transactions discovery — 2026-10-23

Mac uses WorkspaceQueryResultStore (GRDB, Mutex, 50k resident rows then SQLite spill, 256-row pages/16-page LRU) and WorkspaceQueryResultDataExportRowSource. Mobile currently owns full preview arrays (500 rows/4 MiB, 8 MiB batch), MobileGridData currently array-backed. Existing MariaDB transport exposes queryWithTransactionState and streaming transfer rows; transfer streaming only builds names/text and is unsuitable for SQL result types/binary/origin and no-row write results without enhancement. Mac SQL executeStatement currently calls buffered queryWithTransactionState then emits one batch, so true SQL streaming should be a shared transport enhancement used by desktop and mobile, not a mobile-only protocol implementation. Driver API must retain public ABI; transport changes affect MySQL and Doris independently packaged bundles.

### SQL session implementation boundary
- Use paged 500-row mobile windows over the exact shared GRDB store, with mobile resident threshold zero; Mac keeps 50,000-row default. Entire cached results must export through store row source, not materialize all rows.
- Existing query helper remains read-only for metadata. A separate persistent SQL session owns advanced execution, transaction state and cancellation. Public refresh must classify captured SQL again and never replay writes.
- New typed stream preserves columns/types/origins, NULL/binary, empty results and affected rows; MySQL Mac execution adopts it. Transport is shared with Doris, requiring independent validation of both bundles.

### Cache disk lifecycle and memory bounds
- User asked whether disk caching leaves garbage. Normal result release closes/removes SQLite/WAL/SHM; process-scoped mobile cache directories are swept once at next application startup, only within this app's sandbox-owned Results folder.
- Mobile batch cache budgets actual encoded payload sizes + row overhead at 256 MiB total, shared across all statements. SQLite page/WAL overhead is additional. Query refresh temporarily retains the prior snapshot; export sheets retain caches they are reading.
- Mobile windows and cache export batches are bounded to ~4 MiB (one large row may exceed that, max raw row 8 MiB). Added shared cursor-based bounded disk window reads so neither pages nor exports fetch all large rows into memory. Mac defaults stay unchanged.
- Transport product must move V3→V4 for MySQL and Doris together: additive new stream symbol cannot safely bind to an older V3 loaded first by a separately installed driver. Public Driver API unchanged.
