# Syntax highlighting audit

## macOS softer backgrounds and empty header comments — 2026-11-04
1. Complete: user approved macOS soft dark gray; audit all shared and hard-coded black base surfaces, preserving mobile pure black, controls and custom editor themes.
2. Complete: shared header hides the comment row when visible columns have no nonblank comments; preserve preference, column alignment and same-object metadata retention.
3. Complete: nine focused header/canvas native methods and Debug build passed; persistently signed Dev installed with backup (20261104-112017-6d57f42d). Milvus read-only live recheck passed for both collections, schema, two 25-row pages and repeated first page.
# Milvus research — 2026-11-04
Scope: research only, comparing DBX and C/C++/REST options for macOS/iOS/iPadOS. Preserve historical notes; no product changes, commits, releases or desktop input.
1. Complete: inspect QueryCraft contracts/mobile source sharing and pinned DBX implementation.
2. Complete: verify official client license, C/C++ surface, REST coverage and Apple build constraints.
3. Complete: deliver feature scope, transport recommendation and validation gaps.
Research error: initial multi-file patch used an incorrect historical heading; nothing was applied. Corrected with exact file headings.

## Milvus implementation v1 — 2026-11-04

Mac run follow-up: signed Dev and Milvus installed and launched, profile/keychain prepared. Current proxy 502/direct timeout blocks real Collection/schema/paging acceptance. Desktop isolation has been removed. Detailed incident/recovery notes are in progress.md.

Scope: implement a REST v2 Milvus driver and first browse/search experience, preserving existing six-driver behavior and keeping relational editing semantics out of Milvus.
1. Complete browse milestone: shared type/configuration, REST session and driver package.
2. Complete browse milestone: catalogs/activation, Collection sidebar and Data/Schema tabs.
3. Complete source integration: mobile shares session/parser and grid; four focused driver tests pass. Full mobile linking still requires the existing native libraries.
4. macOS build/package/loading checks passed. Current live acceptance remains incomplete (proxy 502/direct timeout); mobile complete linking needs existing native libraries. Search UI remains a later milestone. See docs/MILVUS_V1.md.


## MCP transfer byte-limit diagnostics — 2026-10-29

4. Complete: installed and launched persistently signed Release /Applications/QueryCraft.app, marker 20261029-103048-e41132b; original app retained in .build/formal-app-backups/20261029-103048-e41132b/. Native MCPInstallation activated local-D7F17301-0CA3-46C0-ACFD-E251A6CE0D21, runtime 20261029-024352-b67dffb3; Previous points to original 0.1.3-4. Release relocation/signature/stdio/HTTP/six-driver and full loopback tests passed. Fresh installed-launcher runtime/schema and actual app/Feature loaded paths verified, saved policy/SSH configuration unchanged. Existing stdio sessions preserved; current client correctly reports reconnect_required=true. No online release or remote environment mutations.

1. Complete: confirm original Auth upload omitted max_transfer_bytes; 221054869-byte source exceeded default 67108864-byte cap.
2. Complete: preflight oversized regular uploads before SSH/record creation; contextual transfer failures/recovery and retained background diagnostics; preserve default cap and native safeguards.
3. Complete: 72 focused tests passed (zero failures/skips); native app and independent MCP builds passed. Signed component passed relocated stdio/HTTP and full temporary loopback SFTP/tasks/reconnect/cleanup acceptance with installed SSH 0.9.0. No test-server upload, user-component replacement, deployment, commit or release.
Build notes: corrected unavailable skill path; used JSON CLI arguments after array flag was parsed as one build action. Standalone fresh SwiftPM dependency resolution hit GitHub timeout; switched to the existing Xcode workspace cache with automatic resolution disabled.

## MCP permission contract and exhaustive combinations — 2026-10-26

Objective: audit and fix the complete MCP authorization contract, including all six drivers and shipped/installed skill instructions. Preserve saved grants and business data. No commit/publication requested.

1. Complete: inventory settings, persistence, schemas, direct/plugin/resource routes, sessions and all source/installed skill references.
2. Complete: scoped DDL, actual SQL/REST/Kafka target modes, Redis global/alias checks, lazy discovery, typed errors, profile revalidation, access metadata and skill contract; shared grammar/comment corrections verified.
3. Complete: 260 final tests passed, zero failures/skips. Includes 61,440 foundation, 2,304 SQL runtime, 432 non-SQL runtime, 3,456 SSH and 150 Redis alias combinations plus SQL/metadata/parser regressions.
4. Complete: signed component passed isolated native six-driver permission/transaction cases, package/stdio/HTTP acceptance and SSH loopback. Original zfb connection passed scoped temporary-table DDL/comment/cleanup; original grants unchanged.
5. Complete: signed MCP20261026-111132-aabe3a8b atomically installed with Previous/backup and installed-launcher verification; four skill files replaced and validated. Existing loaded client requires reconnect. Detailed evidence: docs/MCP_PERMISSION_VERIFICATION.md. No commit or publication.

## QueryCraft 0.1.12 release — 2026-10-22

1. Complete: reread release process/AGENTS; fetch tags and audit v0.1.11 baseline, independent components and all 12 live driver catalogs. App/MCP plus MySQL/PostgreSQL/Doris require new identities; API 5 and remaining components unchanged.
2. In progress: allocate app 0.1.12+22, MCP 0.1.2+3 and affected driver identities; prepare bilingual notes; run core/MCP/driver/release tests and Release build.
3. Complete: private server workflow 39696803444 deployed 16bfdf44 successfully; public health returned ok after restart. New update-format-2 handler is deployed before client publication.
4. In progress: feature 6e5d1c8 and release 344748f committed and pushed with v0.1.12. Public release workflow 39699218838 started; monitor both native builds, runtime gate and publication, then verify assets/catalogs/appcast/unchanged components.

## Table context operations — 2026-10-22

1. Complete: inspect sidebar/overview, SQL execution, safety lock and six-driver scope. Preserve Driver API 5; use existing executeStatement.
2. Complete: shared six-action menu and confirmation sheet; isolated SQL execution, connection/workspace checks, pending-change guard and content refresh. Replaced old separate rename/delete presentations.
3. Complete for local verification: Debug build, 36 regression methods, six installed API 5 driver activations/session factories and 60 Chinese/English light/dark native sheet snapshots. Docker unavailable, so real database mutations remain unverified. No desktop input, Dev replacement, commit/tag/release.

## Desktop dependency slimming — 2026-10-21

1. Complete: separate MCP SDK/HTTP/NIO into QueryCraftMCPPackage, sharing the existing dynamic Feature product through JSON SPI. Desktop policy, credentials and six-driver API 5 identities preserved.
2. Complete: 80 Swift tests; 35 script tests; relocated signed stdio/HTTP and six-driver/solo/mixed loading; actual signed component download, standalone CLI update, old-session continuity, rollback and failure recovery passed.
3. Complete: icon preserved after pixel comparison; both app and MCP architectures compiled. Signed XZ now 12.21/10.61 MB; lossless ULMO DMGs 13.49/11.79 MB. Both container families matched file hashes/modes/symlinks and signatures; all test images detached.
4. Complete: measurements and limits documented. Signed Intel and ARM validation apps retained in separate staging directories; ARM used a custom product output directory. No versions, commits, tags, online deployment, installed app or user settings changed. ARM native execution, real database operations, persistent launchd and system replacement installs remain untested this round.

## Smaller architecture-specific updates — 2026-10-21

Objective: implement signed Intel/Apple Silicon XZ updates, preserve upgrades from the existing public feed, measure actual archives; no public release or version bump.

1. Complete: traced Sparkle 2.9 selection, packaging, recovery, server storage/deployment and six-driver applicability.
2. Complete: single-architecture signed XZ archives, shared hardware-aware feed, v2 recovery artifacts, deployment/sync and server archive-pair storage/API; legacy ZIP history preserved.
3. Complete: native Intel and cross-compiled ARM Release builds; real signed XZ pair passed server public-key/XZ/CPU checks, roundtrip manifests and pinned signatures. Both DMGs passed integrity checks. Eighteen update/recovery tests, 15 scope tests, three native Sparkle selector scenarios, server Go tests/vet and six Intel driver loading passed. Validate-only publication checked all 12 online driver catalogs.
4. Complete: deployment order, legacy history/recovery, measurements and ARM/system-install limits documented. Native Intel build products restored. No versions, commits, tags, online deployment or installed app changes.


1. Complete: build MySQL/PostgreSQL/Doris SQL, JSON and Elasticsearch test corpus.
2. Complete: reproduce missing or incorrect captures and fix display classification.
3. Complete: validate incomplete input, UTF-16, incremental edits; 83 tests passed, Debug build passed, signed Dev installed.
4. Complete: document coverage, remaining grammar limitations and verified results in the existing editor-color design document and findings.md.

Do not execute SQL fixtures against databases. Preserve existing user settings and working tree changes.

5. Complete: 130 dialect/JSON/request fixtures, 216 SQL middle-edit transitions, 36 JSON/request edit transitions, empty documents and long-document viewport checks.
6. Complete: fixed newly exposed SQL quote/capture defects; 207 tests passed and Debug built. Signed Dev installed and launched (20261014-102601-7dcfdd78).

Errors: initial planning file creation through a Python heredoc hit a source encoding error; use apply_patch.

## Data transfer implementation — 2026-10-19

Objective: implement Tools → Data Transfer as a native reusable workbench, matching the local DBX feature/configuration reference, with real driver capability checks and honest execution outcomes.

1. Complete: inspect project/session/schema/connection APIs and local DBX configuration, persistence and runner; record the six-driver matrix.
2. Complete: implement persistent task/folder library, transfer request/planning and SQL dialect/metadata conversion.
3. Complete: implement background runner, progress/history, append/overwrite/upsert/rebuild, filtering, object dependencies and cancellation.
4. Complete: implement native workbench, task tree, searchable endpoint/object selection, options, SQL/ownership confirmations and Tools menu.
5. Complete for background verification: 84 regression methods, four real database transfer directions, six-driver loading, Debug build and signed Dev installation passed; capability documentation finalized. Visible UI acceptance remains incomplete after user Escape; no further desktop operation was performed.

Preserve existing untracked project metadata and earlier planning records. Do not commit, tag or release. Physical desktop input requires verified screen isolation first. Local DBX reference: /Users/weilai/.codex/reference-repos/DBX at 3de07819.

## Complete editor customization follow-up

7. Complete: undo/redo/session restore, validated HEX input, personal theme library/import/export, independent typography and additional surface roles, readability checks.
8. Complete: adaptive settings layout, five-language interactive previews with semantic role selection, stable native color-panel targeting.
9. Complete: connection-aware SQL highlighting and explicit MySQL quote-mode handling without guessing server state; preserve execution boundaries.
10. Complete: real undo/redo and composition, multi-editor synchronization/persistence, palette/rendering/layout matrix, MB-scale latency and memory coverage.
11. Complete: verify all relevant suites, build, inspect previews, install and launch Dev. Document any remaining external validation limits.
Test harness compilation fixes: actor-isolated parameter sources made nonisolated, supplied required wrapLines, used UInt64 revisions. Harness optional capture comparisons changed to compare CaptureName values directly.

## Final regression follow-up

12. Complete: reproduce search foreground failure in rendered pixels and correct overlay painter order; verify native color panel retargeting/reopening and grouped undo via AppKit APIs.
13. Complete: file IO/cancellation/error/duplicate-name tests; bounded theme reads and unique names; Chinese marked-text transitions across all five preview providers; executed-SQL colors and typography.
14. Complete: functional regression and isolated timing/performance checks passed; Debug build passed; all six installed drivers passed read-only smoke against existing local Docker services; 18 native SQL/JSON snapshots inspected. Signed Dev installed (20261014-135801-41722e67).
15. Environment limit: no verified desktop input isolation is available; physical mouse picker drags, file-dialog clicking, and system IME candidate-window interaction remain unverified. No OS mouse/keyboard simulation is allowed without the required isolation.

16. Complete: restored requested left/right customization layout with explicit 960×700 minimum and permanent preview; clarified selection-only readability advisories. Layout/presentation suites and Chinese/English light/dark screenshots checked; Debug rebuilt and signed Dev installed (20261014-142802-5f128345).

17. Complete: all six built-in palettes pass every readability check at unchanged targets, including active/inactive selection. Eighteen color/customization methods passed, six native palette snapshots inspected; Debug rebuilt, signed Dev installed (20261014-143528-53e23f06).

18. Complete: reread release/AGENTS requirements, fetched tags and checked v0.1.9 baseline, unchanged API 5 and six drivers, 12 online architecture catalogs compatible. Committed 69 feature/test/grammar/design/smoke files on main as dab2db0. Kept local planning logs and generated Xcode lock file outside the commit. No push, tag or release requested.

Data transfer progress checkpoint:
- Inspection/reference and six-driver assessment complete.
- Workbench/menu, saved task tree and configuration persistence implemented.
- Planner and runner implemented; final 84 regression methods and expanded four-direction database matrix passed.
- Signed Dev installed with marker 20261019-155653-d6bcfc35, without launching. Capability/limitation documentation finalized in docs/DATABASE_TRANSFER.md. Visible UI acceptance remains incomplete after user Escape; query-grid export-to-database and sidebar copy/paste entry points are outside this delivered workbench.

## Native bulk transfer — 2026-10-20

1. Complete: inspect native driver transports; add optional capabilities without changing the WorkspaceSession witness table or Driver API 5.
2. Complete: bounded streaming COPY / controlled in-memory LOCAL INFILE, lossless encoders, transactional Upsert, permission fallback and native cancellation.
3. Complete: 45 regression methods; six-driver loading; four-direction live edges; disabled LOCAL and denied TEMP fallback; three Doris/mixed-version combinations; eight million-row append/Upsert, four ten-million transfers and six cancellation/rollback cases passed with full-row verification. Owned fixtures and volumes removed.
4. Complete: documented actual results and fingerprints in docs/DATABASE_TRANSFER.md; signed Release Dev 20261020-114655-8a63b4d1 installed and launched with matching MySQL/PostgreSQL/Doris drivers. Verified installed-host loading, hashes/UUID and actual Dev loaded paths; old app and drivers backed up. No commit, tag or public release.

## QueryCraft 0.1.11 release — 2026-10-20

1. Complete: reread release rules; merge all main changes, unify Tools menu, allocate app/MCP/three-driver versions; README reduced to capabilities and measured performance.
2. Complete: 227 integrated Release regressions and 15 release-scope checks passed; all 12 online API5 driver packages verified against size/hash/bundle metadata.
3. Complete: final Release build, relocated Release MCP/stdio/HTTP/six-driver/mixed-upgrade checks and Debug isolated lifecycle passed. Added and locally exercised the dual-architecture runtime gate for Actions.
4. In progress: commit and push all main changes and v0.1.11, monitor architecture/runtime/publish jobs; verify live catalogs/assets/appcast and unchanged components.


## iOS / iPad proof — 2026-10-22

Objective: in isolated worktree, compile and exercise an iPad SQL prototype using existing core sources and native MySQL transport. No release, commit, tag, installed Mac app changes, or user database mutations.

1. Complete: inventoried portable source closure, iOS runtime/SDK and isolated MySQL fixture.
2. Complete: all three native slices built and checksummed; shared-source core/transport targets compile for iOS; desktop nominal types remain in Feature.
3. Complete: connection/query/results prototype with retained refresh content, fixed footer, explicit error/empty states and stale request isolation.
4. Complete: iPad/iPhone each pass 14 tests; actual iPad results and iPhone connection rendering inspected; unsigned device and Mac builds pass; six-driver old/new compatibility and fresh MySQL/Doris packaging verified. Scope/limits documented in QueryCraftMobile/VALIDATION.md.


## MySQL mobile first usable version — 2026-10-22

User scope: finish MySQL first, in the existing worktree. Other drivers are deferred; Kafka excluded. Preserve the installed Mac app, published Driver API and unrelated main-checkout changes. No commit/tag/release requested.

1. Complete: design bounded query transport, connection/credential persistence, browser state and pagination using existing MySQL metadata/protocol behavior.
2. Complete: implement native connection management, database/table browser, schema/details and paged data with stale-response protection.
3. Complete: integrate SQL workspace, bounded results, cell inspection, query history and stable shared refresh/navigation.
4. Complete: final 32 tests per iPad/iPhone, isolated real MySQL, native viewport/selection/width checks, unsigned device build, Mac build, six old-driver compatibility and fresh MySQL/Doris packaging/mixed loading/TLS query.
5. Complete for the first read-only MySQL scope: README, validation and Mac parity matrix updated; final native UI screenshots inspected; all owned fixture containers/volumes removed. Full desktop editing/disk-cached streaming/editor features and real-device interaction remain explicitly unported/unverified.

MySQL Mac parity requirement (user steering): preserve desktop data-loading/UI optimizations; reuse grid sampling and bounded cell preview source, native visible-cell reuse, stable refresh/error containers, request generations, column widths/scroll/selection. Full desktop disk-spooled SQL results/editor/export remain explicitly tracked as unported, never claimed complete.

UI feedback accepted: reference TablePro mobile information architecture, then revise rough prototype with native grouped structure, readable grid metrics and OS26 glass controls. Final screenshots must be inspected before delivery.

## Mobile connection home cleanup — 2026-10-22

User feedback: iOS home mixes too many unrelated controls.
1. Complete: separate the saved connection home from the database workspace; one add action, simple endpoint rows and native first-connection empty state.
2. Complete: place database selection, native object search, SQL and object navigation inside the connection. Keep the public refresh/cancel dispatch and cached data/draft when returning home.
3. Complete: 35 tests each on iPad/iPhone; clean home, empty home and catalog/detail rendering inspected; device build passed.
4. Complete: native TabView for Tables / Query / Views replaces combined catalog/SQL rows. Final iPhone/iPad each passed 37 tests (0 failed/skipped), actual system Glass tab/catalog/query/table screenshots inspected, unsigned ARM64 device compile passed; docs updated and owned MySQL fixtures removed. Desktop and external drivers are unchanged in this follow-up.

## Mobile data presentation and table search follow-up — 2026-10-22

1. Complete: default native grid, top options menu, title-menu Data/Structure switch, compact status/pagination footer, no extra floating Glass bar. Compact table detail hides main tabs; regular iPad keeps small top tabs and split navigation. Phone portrait and landscape declarations added and actual right-landscape rendering inspected.
2. Complete: desktop and mobile call one shared CompletionLabelMatcher.matching implementation for matching and stable ranking. Full bounded catalog is cached for local fuzzy search; no SQL collation mismatch or 200-item window. Primary checkout and worktree AGENTS.md record the user's desktop-parity requirement.
3. Complete: final iPhone/iPad each passed 43 tests; isolated MySQL includes 78 columns/120 rows. Native compact portrait/landscape/schema and iPad split rendering inspected. Final signed device build/install/launch succeeded without clearing saved connections. Mac full build, actual compiled object-list search regression and all six existing driver bundle/session factories passed.
4. Complete: README/parity/validation and work logs updated, all owned fixture containers/volumes removed. Desktop search sorting is a semantics-preserving shared extraction; external drivers/API unchanged. Mac Xcode scheme lacks test action, so its failed attempt is recorded accurately and the compiled-framework regression is the actual pass. No commit/tag/release.

## Mobile fullscreen grid and strict axis scrolling — 2026-10-22

1. Complete: native full-screen presentation for table and SQL results reuses the same grid renderer/data, hides surrounding UI, auto-hides its exit control, supports Escape/accessibility escape, and restores viewport/widths/selection with ownership fencing.
2. Complete: enforce one dominant axis through pan and deceleration, preserve it across same-object refresh, reset for cancel/new gesture/context/explicit restoration. Header-only resizing no longer intercepts data-cell swipes. Mac wheel behavior and driver protocols unchanged.
3. Complete: final iPhone/iPad each 49 passed/0 failed/0 skipped; full table/query and phone landscape screenshots inspected, iPad settled screenshot confirms auto-hidden exit. Signed device build log succeeded and strict signature verification passed; combined build-and-run reported failure because launch was blocked by device lock. Separate device install succeeded. Auto-launch remains unverified until unlock. Documentation updated; owned fixtures/volumes removed. No commit/tag/release.

## Fullscreen safe area and residual keyboard fix — 2026-10-22

1. Complete: respect hardware safe areas in fullscreen; keep background edge-to-edge and table/header outside notch in portrait and landscape.
2. Complete: clear catalog/results/editor input focus at navigation/fullscreen entry, suppress residual keyboard in this fullscreen window through rotation, retain working dismiss controls outside fullscreen.
3. Complete: final iPhone/iPad each 51/0/0; native hosting/responder regressions and phone portrait/landscape/iPad table/query renders inspected. Signed build/install/launch succeeded (PID 1112); actual physical third-party IME/rotation acceptance remains manual. Docs updated, fixtures/volumes removed, whitespace/script syntax passed. No commit/tag/release.

## Shared grid find parity — 2026-10-22

1. Complete: adapt the real Mac grid-search source boundary so iOS/iPadOS reuse its worker, controller, operators and match model unchanged in behavior; evaluate all desktop driver callers.
2. Complete: replace mobile row-hiding contains search with cell navigation, column/match/case controls and next/previous actions; preserve row identity, viewport/fullscreen, stable loading and raw typed cells.
3. Complete: final phone/iPad each 60 passed, 0 failed/skipped; shared matching/state, UIKit selection/resize, query editor restore and MySQL regressions passed. Table/query find and fullscreen renders inspected. Mac full build, actual compiled adapters and disk row 50,002 lookup, six driver loading and isolated MySQL TLS passed. Signed device build/install/launch succeeded (PID 1194); simulator experience uses the retained live fixture. Limits recorded; no commit/tag/release.

## Shared timestamp display parity — 2026-10-22

1. Complete: trace Mac timestamp formatting, metadata and raw-value boundaries; compile the same formatter for mobile, with per-column native format controls and fullscreen state.
2. Complete: cover automatic/explicit formats, metadata aliases/expressions, precision, refresh/object isolation, native menu/accessibility and real MySQL table/query paths. Compact landscape SQL now preserves result space.
3. Complete: final iPhone/iPad each 67/0/0; table/query/fullscreen renders inspected, Mac full build and actual native formatter/raw copy/export/lifecycle checks passed, all six driver factories loaded and owned MySQL TLS passed. Signed device build/install/launch succeeded (PID 1227); both simulators restored to epoch_values on the retained experience fixture. Applicability/limits recorded; no commit/tag/release.

## iPad sidebar and compact navigation — 2026-10-22

1. Complete: regular-width root NavigationSplitView aligns sidebar to the native top safe area. Per user follow-up, removed the entire regular-width TabView and moved Tables/Query/Views into the existing sidebar title menu; one native detail navigation container retains all toolbars.
2. Complete: native hierarchy/top-alignment/tab-switch identity/draft regression; final phone/iPad suites each 68/0/0, rendered sidebar/table/query/views and compact phone navigation inspected. Only mobile presentation changed; no Mac/driver rebuild required.
3. Complete: device signed build/install/launch succeeded (PID 1257), both simulator experience scenes restored on the retained fixture. Docs updated; no commit/tag/release.

## Shared MySQL server filtering - 2026-10-22

1. Complete: shared actual MySQL predicate/default-column helpers and filter models; desktop bound SQL behavior retained, mobile uses safe literal rendering through the same construction.
2. Complete: native filter sheet with fixed left labels/right values, committed/requested state, WHERE before sort/paging, failure/retry/cancel isolation and Mac page-context viewport behavior.
3. Complete: final iPhone/iPad each 80/0/0 with real MySQL; filter/editor renders inspected. Mac full build, independent MySQL build/package/signature, actual Dev registry six-driver loading and new MySQL live checks passed. Latest device launch succeeded; simulators restored to retained live fixture. No commit/tag/release.

## Shared loaded-data export - 2026-10-22

1. Complete: traced Mac defaults/request/writer and isolated unchanged Foundation copy types; shared XLSX/CSV/JSON/SQL writer and options, with JSON alias collision correction and six-driver applicability review.
2. Complete: immutable loaded-page/query snapshots, compact native export Form/Files save, cancellation/generation fencing, independent temporary directories, raw values and honest binary/loaded-data scope.
3. Complete: each phone/iPad 89/0/0 including real MySQL and native save-picker lifetime; forms inspected. Mac full build, actual four-format writer/dialects, independent XLSX ZIP/XML and six-driver loading passed. Final simulator/device builds/signature passed; physical installation blocked by disconnected device, documented. Simulators restored to retained live fixture. Whole-table/selection/task center/persistent export preferences deferred; no commit/tag/release.

## Shared SQL editor - 2026-10-22

1. Complete: same Mac structural parser, grammar/query resources, context/ranker, source ranges, default palette and portable insertion guards. Actual MySQL catalog/column query conversion shared; six-driver applicability evaluated.
2. Complete: native highlighted/IME-safe/undo-safe input, contextual recyclable keyboard candidates, Return/Tab/Ctrl-Space/arrows/Escape and Cmd-Return, lazy real metadata with cache eviction/coalescing and stale fences. Long drafts color visible composed-character ranges; query loading/results and single read-only execution remain intact.
3. Complete: final phone/iPad each 206/0/0, native plain/candidate renders inspected. Mac full build, actual three-dialect/highlight/resource/guard and six-driver factories passed; MySQL independently rebuilt/packaged/signed and actual Dev registry/session metadata/TLS regression passed in isolation. ARM64 signature passed; physical phone disconnected, new build not installed. Both simulators restored to retained live SQL experience. Custom preferences/snippets/multicursor/formatting/full desktop execution remain documented limits; no commit/tag/release.

## Shared whole-table export - 2026-10-22

1. Complete: traced Mac provider/session/writer, shared bounded paged source with desktop session/defaults retained; mobile captures committed object/filter/sort/configuration.
2. Complete: native scope picker and URL Files saving, empty tables/views, progress/cancel/retry/raw values; real multi-page/filter/sort/navigation/empty/oversized/failure/schema and native Files lifetime checks.
3. Complete: final phone/iPad each 213/0/0 and native renders; Mac full build and actual compiled three-dialect source/direct target/four formats/six-driver/MySQL TLS regression passed. Signed ARM64 verified; physical phone disconnected, not installed. Docs updated, both simulator live table experiences restored; owned transient fixtures removed. No commit/tag/release.

## Shared MySQL data editing - 2026-10-22

1. Complete: traced actual Mac edit/delete/insert requests, preview, safety lock and transaction SQL; shared column preparation and MySQL transaction runner, desktop overloads preserved and six drivers evaluated.
2. Complete: native cell/insert forms, pending preview/edit/undo/submit, raw PK overlay across pages/navigation, default lock and rollback/uncertain-result/context guards. Native Done keyboard issue fixed and tested; SQL execution remains read-only.
3. Complete: final iPhone/iPad each 224/0/0; real owned writes/rollback/cancel/lifecycle and native Return/grid checks passed. Mac main and independent MySQL build/package/signature/actual six-driver registry/new-MySQL mutation regression passed. Signed ARM64 verified, phone disconnected so not installed. Docs complete; both simulators use retained owned writable example with safety lock on, transient test fixtures removed. No commit/tag/release.

## SQL query result editing — 2026-10-22

1. Complete: same physical-origin resolver and query preparation compile on Mac/mobile; Mac query inline/inspector/delete guards reject expression-as-PK and conflicting keys, ordinary table requests preserved.
2. Complete: captured result/configuration, fenced async base metadata, common staging/native preview/lock/commit/local patches and pending navigation guards. Defaults/unknown COMMIT require explicit requery; reliable single-relation mobile scope documented.
3. Complete: full iPhone/iPad each 239/0/0, final focused native/state checks, Mac full build/actual query harness/six registry factories, ARM64 signing. Physical phone disconnected, not installed. Docs updated and owned simulator experience retained; no commit/tag/release.

## Fullscreen and record editing — 2026-10-22

1. Complete: actual Mac coordinator/inspector traced; shared UI source/immutable captures/generation fencing across ordinary/fullscreen/record surfaces, existing common requests/transaction model retained.
2. Complete: fullscreen tap edit/readonly fallback, live pending and transient preview, actual responder/controller-aware keyboard guard, keyboard-stable viewport and restore; record all-field edit/delete/preview, retained scroll anchors/grid state, default large native detail.
3. Complete: full phone/iPad each 248/0/0 plus focused source/native/large-detail/true scroll-view recreation checks; actual table/query fullscreen/record/edit/preview renders inspected, ARM64 signing verified. Phone disconnected, not installed. Docs and retained owned simulator experiences updated; transient fixtures cleaned, no desktop input/commit/release.

## Mobile connection and foreground reliability — 2026-10-22

1. Complete: trace actual Mac refresh/session reconnection and mobile per-request connections; add explicit read retry feedback, background cancellation, retained in-memory data/drafts, and no automatic request replay.
2. Complete: ensure rollback bypasses foreground authorization, give cancellation cleanup a bounded OS background lease, and fence ambiguous COMMIT acknowledgement against repeat writes. Cover controlled late responses and owned real MySQL interruption/faults.
3. Complete: final phone/iPad each 262/0/0 with owned real-transaction faults and native geometry/Files regressions; signed ARM64 and strict deep signature passed. Physical phone disconnected, not installed. Simulators restored, docs updated, transient fixtures cleaned. No persistent workspace recovery, SQL tabs, commits or releases.

## SQL selection/current-statement execution — 2026-10-22

1. Complete: trace Mac command/language service/target resolver/preflight; compile those exact sources and regression tests on mobile, leaving desktop behavior intact.
2. Complete: retain actual UIKit selection/IME across navigation, resolve captured revisions before execution, keep result/history/editing metadata bound to actual SQL, and refresh the displayed result independently of draft/caret changes. Single read query per run remains explicit; selected batches must never silently run a subset.
3. Complete: phone/iPad each 302/0/0, original shared/native/real MySQL current/selection/refresh/source checks; Mac full build, actual target/preflight and six-driver loading, signed ARM64 passed. Both simulator examples inspected, docs complete. Physical phone disconnected, not installed; no commit/tag/release.

## Six MySQL table operations — 2026-10-23

1. Complete: trace actual Mac actions/sheet/guard/driver execution; share six-action statement/copy/capabilities and portable tests without changing desktop behavior.
2. Complete: native catalog/context and existing result-menu entry, SQL preview, exact-name confirmation, safety lock, actual auto-increment inspection, pending/context guards, acknowledged vs uncertain outcomes, refreshed navigation/data/query metadata and background cancellation.
3. Complete: owned six-action semantics and denial/FK/no-auto/unknown/lifecycle/App-route checks; final phone/iPad each 324/0/0, native forms and simulator restoration, Mac full build/actual six-driver checks and ARM64 signature passed. Physical phone disconnected, not installed; docs complete, no commit/tag/release.


## Mobile schema editing and two presentations - 2026-10-23

1. Complete: recovered the accidentally archived source snapshot in an attached independent worktree, unarchived original chat; actual Mac/shared metadata, editor state/provider/SQL chain and six-driver applicability reviewed.
2. Complete: native field/index editing and shared table/list drafts, loading/error feedback, iPad base-surface sidebar and opaque macOS Settings backgrounds verified. Stale SQL completion display invalidation fixed during regression.
3. Complete: rebuilt ignored dependencies, final phone/iPad each 343/0/0; actual table/list/field/index and light/dark renders inspected. Mac complete build, independent MySQL build/package/TLS metadata/plan check and original/mixed six-driver activation/session factories passed.
4. Complete: final signed ARM64 and strict deep signature verified; both physical iPhone and iPad installed/launched successfully. Simulators restored to owned live schema fixture, safety lock on, no pending changes. Docs complete. No new feature commit/tag/release or changes to main checkout.


## iPad SQL completion visibility - 2026-10-23

1. Complete: traced Mac caret popup and mobile accessory; iPad now has a window-bounded caret overlay avoiding keyboard, with reusable scrolling candidates and unchanged shared matching/insertion guards. Phone keeps its accessory.
2. Complete: iPad/phone full real-MySQL/native suites each 345/0/0; new geometry invariants and native scroll-to-last/touch/lifecycle pass. Actual live SQL render confirms real fields and types near caret. No desktop input simulation.
3. Complete for user-selected simulator delivery: signed ARM64/signature passed; attempted device install failed after disconnect, then user explicitly chose simulator instead. iPad simulator retained on actual SQL completion experience, docs updated. No new commit/tag/release.


## iPad software keyboard and touch completion - 2026-10-23

1. Complete: enabled actual Simulator software keyboard and inspected the live SQL editor. iPad docked keyboards use a stable 76-point shelf with large, horizontally scrolling candidates; hardware/floating keyboards retain the caret list. User delegated the final placement choice.
2. Complete: iPad full real-MySQL/native regression 346/0/0 and phone focused native editor regression 8/0/0, no diagnostics. Actual keyboard/shelf screenshot inspected; simulator retained for use. Shared engine and desktop behavior preserved; simulator-only delivery, no commit/tag/release.

## Completion acceptance and opaque keyboard shelf - 2026-10-23

1. Complete: traced actual Mac/shared insertion and trigger model; opt-in shared token separation, exact-text/caret continuation and same-revision dismissal prevent old-token reopening. Functions/placeholders/qualification and native undo preserved.
2. Complete: opaque light/dark shelf inspected with actual software keyboard. Initial native 13/0/0; final iPad full 351/0/0 and phone focused 13/0/0, no diagnostics. Latest signed ARM64 build/install/launch on paired physical iPad succeeded (PID 1174), strict deep signature passed. Ongoing iPad delivery preference recorded; no commit/tag/release.


## Ongoing user delivery preference - 2026-10-23

For each mobile change, complete relevant verification then rebuild, install and launch the latest app on the user's paired iPad (73ACA305-F559-5859-843F-872DEE35CD07). The user explicitly authorizes this each time; do not stop at simulator delivery or ask permission again. If disconnected or installation fails, report the actual blocker. Do not infer physical touch acceptance from process launch.

## SQL snippets on iPhone/iPad - 2026-10-23

1. Complete: actual Mac template/store/ranking/session sources compiled on mobile with conditional native adapters. Native CRUD/toggle/restore, literal template input, touch and Tab/backtab navigation, hints, empty stops, edit/IME/undo/source guards implemented; Mac trigger validation shares the store rule.
2. Complete for user-selected simulator delivery: focused 39/0/0; full iPad/phone each 380/0/0; Mac complete build and 56 original snippet tests passed. Final DEBUG-only live-render trigger rebuilt with native presentation 2/0/0. Native navigation and manager renders inspected; both live simulator scenes ready with sel candidates and software keyboards.
3. Previous completion fix installed on iPhone; launch timed out, then device became unavailable. Latest signed snippet app installed on iPad, but automatic launch was denied while locked. User then selected simulator delivery; physical retries and unlock waiting stopped. No physical snippet touch acceptance claimed.

Current delivery override: user said “先用模拟器吧” during snippet work. This increment is simulator delivery; do not continue requesting device unlocks or retrying physical installs/launches. Previous standing iPad update preference does not override this newer instruction.

## User-requested Git commit - 2026-10-23

Release process and root instructions read again; current diff and last-tag driver scope checked. Create `codex/ios-ipad-editor` from recovered detached snapshot and save all authorized source/test/validation changes as one functional commit. Preserve existing version/API/driver identities and snapshot history. Existing final validation is unchanged; no remote push, tag or release requested.


## SQL formatting — 2026-10-23

1. Complete: reuse Mac SQLFormatter/Worker/request/options/edit and original formatter tests, with native mobile toolbar and Cmd-I entry.
2. Complete: eight native IME/selection/undo/stale/cancellation/teardown/workspace checks plus original shared formatter regressions; final owned-MySQL full iPad/phone each 404/0/0, native light/dark renders exported and inspected. Existing iPad owned action_demo experience restored, disposable fixtures cleaned.
3. Scope: mobile MySQL editor only; desktop SQL formatting behavior and all external drivers unchanged. PG/Doris retain the same desktop formatter; Redis/Elasticsearch/Kafka specialized requests are not mobile SQL formatting targets. Latest simulator delivery override retained.


## Read-only SQL batch execution and independent results — 2026-10-23

1. Complete implementation: reuse Mac resolver/preflight and extracted shared ordered/cancellable batch runner; preflight the whole plan, bounded same-session MySQL batch, stop on first error/cancellation/truncation, mark untouched suffix explicitly.
2. Complete implementation: selected/current/all execution and keyboard commands; per-result typed data/metadata/drafts/viewport, current-result refresh, history-on-completion and cross-result schema/write guards. Preserve prior selected data during new loads; label it as previous until success.
3. Complete: final owned-MySQL phone/iPad each 420/0/0; actual light/dark renders inspected; Mac build and actual compiled common SQL runner regression passed. Initial single-result loading regression corrected and documented. Latest simulator-delivery override remains. No additional mobile drivers or arbitrary SQL writes/transactions.


## New MySQL table creation — 2026-10-23

1. Complete implementation: trace actual Mac footer/draft/model/provider/statement/session path; extract exact shared draft, reuse editor state/options/MySQL plan and existing native field/index forms. Six-driver applicability reviewed; mobile remains MySQL only.
2. Complete implementation: existing catalog footer entry, retained draft, structure/index/options forms, immutable preview and safety lock; pre-send authorization/cancellation, unknown outcome fence and acknowledged-success navigation/refresh.
3. Complete: full owned real-MySQL iPad/phone each 438/0/0; final native light/dark/advanced-scroll checks each 3/0/0; screenshots inspected. Mac full build and actual compiled shared draft regression pass. Simulators restored to owned live fixture; docs complete. Simulator-only delivery remains; no commit/tag/release.


## Existing MySQL table options — 2026-10-23

1. Complete implementation: trace Mac options tab/metadata/editor changes/provider/DDL; share extracted exact MySQL information query/conversion, existing table options and change set. Existing mobile structure menu opens a native local staging form.
2. Complete implementation: preserve metadata/columns/index drafts, compare explicit changed options before DDL without treating an unrelated AUTO_INCREMENT advance as an edit, capture preview plans, refresh comment identity and preserve uncertain/successful-write fences. MySQL only; PG/Doris/Redis/Elasticsearch/Kafka capabilities unchanged.
3. Complete: final full owned-MySQL iPad 454/0/0 (143.236 s), phone 454/0/0 (91.979 s), no diagnostics; actual native light/dark/advanced/expired/SQL renders inspected. Mac main build and independent MySQL build/package/signature/new-bundle TLS metadata + six-driver Dev activation passed. Both simulators restored to owned schema demo. Simulator delivery; no physical install, commit/tag/release.

## Large SQL results and SQL writes/transactions — 2026-10-23

User explicitly requests both remaining items 2 and 3. Keep existing worktree and uncommitted formatting/batch/table changes; no main checkout edits or MCP work.

1. Complete: trace actual Mac result store, stream transport, execution policy/preflight and transaction session/controls. Determine shared boundaries and six-driver impact.
2. Complete implementation: mobile bounded-memory incremental typed results backed by the exact Mac disk store; paged native grid/record/find/export behavior, retained content on refresh and cancellation/stale response fencing.
3. Complete implementation: explicit write authorization, same-session SQL writes and transaction controls, truthful server transaction state, endpoint/background cleanup and no replay of writes or unknown commit.
4. Complete: meaningful shared/state/native/owned MySQL integration tests, full iPhone/iPad regression, Mac and affected MySQL+Doris transport build/package/load verification; update docs and restore simulator demos. Simulator-only delivery, no release/commit.


Validation: iPad full 467/0/0 + final SQL/cache/native 14/0/0 + final schema state 10/0/0; phone full 468/0/0 + final SQL/cache/native/schema 24/0/0. Mac full build + shared regression 41/0/0; MySQL/Doris independent V4 builds/packages and actual packaged new MySQL typed streaming + six-driver activation passed. Real app startup cleanup verified, simulator demos restored. Docs updated. No commit/tag/release or physical installation.

## Save completed mobile SQL work on branch — 2026-10-23

User explicitly requested a branch commit. Re-read root AGENTS.md and docs/RELEASE_PROCESS.md; checked v0.1.12 baseline, app 0.1.12 (22), Driver API 5 and all six driver impacts. Reattached detached worktree to existing codex/ios-ipad-editor at identical HEAD, preserving changes. Reused verified full/focused simulator, Mac and packaged-driver results; bilingual pending release note records future MySQL/Doris dual-architecture gates and unchanged other drivers. Commit all accumulated authorized formatting, batch, table/options, disk cache and transaction sources/tests/docs; no tag/release or remote push requested.

## Redis iPhone / iPad complete acceptance — 2026-10-23 (COMPLETE)

User direction: finish Redis on both iOS and iPadOS before delivering; stop ending work after individual feature increments. Continue only in codex/ios-ipad-editor worktree; preserve unrelated plans/changes. No commit/release or user database mutations.

1. Complete: inventory actual Mac Redis entry points and state/protocol capabilities; establish final acceptance matrix.
2. Complete: whole-key member search using shared Mac state/reader, rapid change/error/cancel/draft verification.
3. Complete: command console and write classification/confirmation, history/output, connection/background and unknown-write protection.
4. Complete: shared key tree/search, real metadata + Stream pages, 100MiB whole String with segmented touch presentation/JSON/raw export, selected/whole key command export, standalone TTL/delete for all readable types. Mac module/binary-member edit limits retained; no claimed cluster routing/TLS.
5. Complete: phone/tablet usability and stable loading/error/empty behavior across entry points; unified refresh, selection restoration and layout.
6. Complete: complete isolated Redis 7.2/7.4 + existing five-driver mobile regression; Mac shared changes, individual driver package/load, arm64; final capability and protocol-limit documentation. Deliver only after remaining actionable gaps above are resolved.

Implementation inventory complete: five common types create/rename/value/member CRUD; String ≤100MiB complete value editing with bounded touch segments/HEX/JSON/raw export; Hash field TTL; collection reader shared by primary grid/editor/search; selected/whole-key command exports; Stream shared read pages; standalone whole-key TTL/delete; same-session command console/history/completions/transactions; CAS/unknown-write/background safeguards. True desktop/protocol limitations documented. No remaining planned feature expansion; resolve regression findings before delivery.

Final evidence: five-fixture full iPad567/0/0 and phone568/0/0 (Redis7.2); final current-source Redis7.4 each50/0/0; Mac shared29/0/0, driver11/0/0; latest arm64 build; independent signed Redis package + all-six real installer/registry/session factories and live Redis Stream/paging/CAS checks. No actionable implementation gap in current Mac Redis baseline remains; existing Mac/protocol and physical-device validation limits explicitly documented.


## Elasticsearch complete iPhone / iPad parity — 2026-10-24 (COMPLETE)

User requests complete Elasticsearch functionality in one delivery, using current macOS behavior as baseline. Work completed only in codex/ios-ipad-editor; main-checkout changes preserved. No commit/tag/release or user database mutations requested.

1. Complete: actual Mac ES entry points, shared models/session capabilities and explicit acceptance matrix inventoried.
2. Complete: original native ES session/model sources shared; PIT/search_after beyond10k, filter/sort, Mapping/Field Caps, object identity and independent complete-match export.
3. Complete: REST current/selection/all with exact shared parser/completion/formatting/result conversion, multiple results/history, default lock, immutable preview and unknown-write protection.
4. Complete: document inspect/create/replace/partial/delete, shared field staging/paste/batch deletion; Mapping, index create/delete/settings/Alias/template/simulation with native phone/tablet and fullscreen entry points.
5. Complete: stable loading/refresh/empty/error, cancellation/stale/background and transport recreation, staged validation recovery, released-owner lifetime, source/export and cross-driver regression.
6. Complete: full five-fixture iPad647/0/1 and phone647/0/1; latest ES phone79/0/1 plus original fullscreen4/0/0, iPad83/0/1; Mac feature163/0/0, driver45/0/2 and shared supplements26/15/12 all passing; actual signed new ES package/all-six loading plus live typedPIT/docCAS/Mapping; latest arm64 build. Native captures inspected; documentation records server/TLS/physical/generic-editor boundaries. Simulator-only delivery remains. No remaining planned ES-specific implementation work.


## PostgreSQL complete mobile parity — 2026-10-24 (COMPLETE)

User-authorized complete PG-specific follow-up delivered in codex/ios-ipad-editor. Prior ES changes preserved; main checkout, installed Dev, user databases and release identities untouched. Simulator delivery remains current scope.

1. Complete: actual Mac PG query/schema/new-table/table-action/import/COPY sources and entry points inventoried; POSTGRESQL_PARITY records exact scope and generic-workspace/protocol boundaries.
2. Complete: physical-origin/PK result editing, including completed auto-commit cache pages; shared store mutation/streaming row compaction, whole-cache export, old-page editor invalidation and asynchronous patch protection.
3. Complete: original PG provider/descriptor/metadata/executor; field/index/identity/generated/new-table/zero-column/structure-SQL and table/owned-sequence operations, immutable native previews and transactional/unknown-outcome guards.
4. Complete: original multi-format parsers, frozen disk snapshot, mapping/plan and shared transactional importer; Files UI, stale preview/loading/cancel/background protections; actual COPY FROM protocol verification with rollback.
5. Complete: five-fixture full iPad694/0/1 and phone695/0/1; latest PG two-device80/0/0 each. Mac shared58/0/0, cache18/0/0 and PG13/0/0; independent dynamic build198.502s, new signed850f7b8725f6b4f7 package and actual six-driver/live PG load; latest arm6432.122s. Native final captures inspected.
6. Complete: current scope/validation/README/history/release-impact docs updated; owned fixtures cleaned. Normal iPad and iPhone simulator relaunches succeeded without diagnostics. No commit/push/tag/release or physical installation; no further planned PG-specific implementation work.


## Mobile remaining workspace completion — 2026-10-25 (COMPLETE)

Completed all four user-authorized areas after3e2a2df: Doris parity, persistent independent SQL documents, original generic migration engine and editor settings. Work remains on codex/ios-ipad-editor; Kafka is excluded from mobile work.

1. Complete: traced actual Mac entry points and shared restoration/metadata/transfer/theme rules and models; preserved desktop UI/storage behavior.
2. Complete: Doris original MariaDB backpressure stream/disk cache and true DDL/index metadata; no transaction/write support invented.
3. Complete: independent documents/saved queries/SQL sessions/schema catalogs, exact close snapshots and protected atomic recovery without credentials/results/server transactions. Unresolved SQL markers persist; cross-document writes stay fenced until verification.
4. Complete: original Mac catalog/planner/runner/manager/library and three driver sessions, native configuration/preview/folders/tasks/history/cancel/verification; six real transfer directions and complete data fidelity.
5. Complete: shared editor/theme/archive/history/keys/format/indent/completion; native UIKit selection/IME/undo/find, visible line decorations and long-draft scrolling; fixed error/footer/confirmation presentation.
6. Complete: both full five-fixture752/0/9, final80/0/0 each; Mac65/0/0 and driver5/0/0; changed three driver builds/signed packages/all-six real loading/liveDoris; final unsignedarm64; native captures/normal launches; fixture cleanup and docs. True-device/network/TLS and missing Simulator Emoji font limits are recorded explicitly. No commit/push/tag/release, installed Dev changes or user database operations.
## MCP settings implementation — 2026-10-21

Objective: implement the approved complete native MCP settings prototype, preserving the existing policy format, effective permission ceilings, all connection/database/tool options, integration controls and history.

1. Complete: inventory source/settings and backward-compatible permission editing/navigation.
2. Complete: native grouped permission editor, object scope, advanced settings, full directory and save review.
3. Complete: 58 package regression methods, final 13 focused editing/discovery/loading methods, and Chinese/English native offscreen light/dark/narrow layout checks passed.
4. Complete: Debug and optimized Release builds passed; final Release native layout snapshots/navigation/scroll checks passed; isolated signed Release Dev 20261021-083114-9aec4c98 installed with matching main/feature UUIDs. Diff whitespace checks passed. No live database writes or physical desktop input.

No commit/tag/release or user configuration migration. No physical desktop input without verified isolation. Keep earlier unrelated planning records.

Latest UI follow-up complete: permission categories are five flat tabs with direct controls; version/path disclosure removed. Release Dev 20261021-131258-0ebd9a96 installed and reopened after Chinese/English narrow rendering and eight regression methods passed.

Latest navigation refinement complete: one row of seven tabs, with a compact single-row narrow variant; nested Access tab bar removed. Final Release Dev 20261021-132217-5ad4bfef installed and reopened after routing regressions and native preview checks.

Latest footer refinement complete: settings index moved into bottom-left of the existing footer, top tab bar centered, narrow primary-button labels kept complete. Release Dev 20261021-142327-c6f8b855 installed/reopened after focused Chinese/English native previews.

Latest connection layout complete: static group headings and always-visible connections, optional filtering, aligned connection/access/scope columns, explicit Configure scope action and narrow fallback. Release Dev 20261021-145019-b7114f58 installed/reopened after 14 regressions and native Chinese/English preview/navigation checks.

Latest object-scope refinement complete: replaced inline expansion with a native transactional sheet; stable list and loading layout, Cancel/Apply, retained name rows. Release Dev 20261021-151607-a84e4f1c installed/reopened after 15 regressions, final Chinese/English native previews and scope presentation/cancellation verification.

Latest environment naming complete: QueryCraft Dev / querycraft-dev for Dev, QueryCraft / querycraft for production; templates, registration receipts/migration and runtime handshake aligned. Dev 20261021-155549-2484fe0e plus independent local Dev MCP installed, Claude Code migrated/backed up. 37 regressions, stdio/HTTP identities and signed six-driver package loading passed.

Development component channel separation complete: no configured Dev source means no production MCP/Skill download fallback. Release Dev 20261021-161742-02db7f53 and local independent components installed/verified, 38 regressions passed. Latest active follow-up: reproduce and reduce permission dropdown UI update latency, preserving all authorization semantics.

Permission dropdown/alignment follow-up complete: stable native popup controls, single responsive row layout and batched mutations; 28 regressions plus native action/disabled probes passed. Final fixture group update median 34.0 ms versus baseline 207 ms, individual 17.7–20.1 ms. Main row actions aligned above their descriptions at wide/narrow sizes in Chinese/English. Release Dev 20261021-165550-9c498363 installed, verified and reopened.


## QueryCraft 0.1.12 release — complete

Feature and version commits/tag pushed; dual-native Actions build/runtime/publish succeeded; public app/update/driver/component artifacts verified after download; both DMGs mounted and compared; Dev app and affected drivers installed, backed up and actual six-driver loaded paths confirmed. See progress.md release acceptance for versions, evidence and remaining real-database validation limit.


## SSH plugin and MCP — 2026-10-22

User scope: own libssh2-backed plugin, MCP first. Preserve existing six database drivers and unrelated work.
1. Complete: independent C plugin ABI and SSH connection/authorization model.
2. Complete: libssh2 transport, cancellable signed loader, five MCP tools, immutable local installation and native/ARM packages.
3. Complete: 52 coherent host regressions, native SSH ABI suite, authorized-server MCP acceptance, final stdio/HTTP checks and six-driver loading passed.
4. Complete: documentation and final native signed development MCP artifact available; native/ARM signed plugin ZIPs built. ARM runtime, SSH desktop UI/SFTP, mobile integration and real six-database queries remain outside this first MCP scope. No commit or release requested.

SSH phase update: independent ABI/plugin, host service, explicit grants, MCP routes and local immutable installer implemented. Native and ARM plugin builds complete; real server password/command checks passed. Final host regression and MCP protocol acceptance still in progress.

## SSH desktop workflow — 2026-10-22

1. Complete: integrate SSH plugin catalog/install/update/remove with Plugins settings, preserving independent ABI and six database drivers.
2. Complete: native SSH server/account editor with password/key authentication, test, credential lifecycle and explicit MCP grants.
3. Complete: regression tests, native offscreen layout verification, authorized server test, signed Dev app/MCP install and stdio verification.
4. Complete: document distribution setup and actual remaining limits. No public publish/commit/tag requested.

SSH desktop checkpoint: account and plugin UI implemented; 57 broad and 31 focused native regressions passed. Signed dual-architecture SSH catalogs/packages prepared locally, with no upload. Final credential-revocation regression, offscreen UI and real server cross-host credential checks in progress.

## SSH files and long tasks — 2026-10-23

1. Complete: optional SFTP extension 1, preserving base ABI 1; bounded list/stat/read and streamed upload/download with temporary-file publication.
2. Complete: independent file-read/transfer grants, 16 SSH MCP tools, shared cancellation/capacity and native account permission controls. Existing grants do not gain file access.
3. Complete: persistent remote Python 3.6+ supervisor, account-bound local task registry, bounded logs, status/output/cancel/terminal cleanup and no automatic retries. Missing Python is rejected before recording a task.
4. Complete: native ABI/SFTP, host policy/task tests, loopback full MCP task lifecycle, authorized-server SFTP/missing-runtime acceptance, signed Intel/ARM packages, Dev app/MCP/plugin installation and documentation. ARM runtime and real six-database queries not repeated. No public release or commit requested.

## SSH authorization shared entrances — 2026-10-23
1. Complete: one persisted account grant shared by SSH Servers and MCP Connections, native shared controls and change notifications.
2. Complete: stale-editor conflict checks, unsaved global MCP settings preservation and stable-loading layout.
3. Complete: 16 account/file/task regressions plus 14 sync/MCP permission/loading regressions; Chinese/English offscreen layouts; signed build and Dev installation. No database grant semantics or public distribution changes.

## Remove remote Python prerequisite — 2026-10-23
1. Complete: replace task supervisor with existing Bash/system utilities; no downloads/installations.
2. Complete: binary/log bounds, cancellation, timeout, disconnect/reconnect, unknown-state, legacy and cleanup safety tests; full authorized-server acceptance without installing Python.
3. Complete: 16 host regressions, signed Dev/MCP update, installed stdio verification and documentation. No changes to database drivers or SSH plugin ABI.

## SSH file management and recovery — 2026-10-23
1. Complete: optional file-management capability preserving ABI1/SFTP1; mkdir, non-overwriting move, unlink and empty-directory removal.
2. Complete: separate default-deny management grant shared by both settings entrances; gated MCP schemas and cancellation.
3. Complete: tracked transfer inspection/token-checked staging cleanup, local-only acknowledged task forgetting, active-operation locks. No arbitrary PID kill or recursive deletion.
4. Complete: native/host/Shell/protocol/live-server tests, signed native/ARM plugin packages, Dev app/MCP/plugin install and docs. Online public distribution and ARM hardware remain separate work.

## Native SSH tasks and transfers panel — 2026-10-23
1. Complete: traced existing task/transfer registries, policy/cancellation and settings entry; built one shared local service over existing runtime operations.
2. Complete: native per-server panel with stable lists/details, task status/log windows, explicit cancel/cleanup/forget actions and tracked transfer inspection/cleanup/cancel.
3. Complete: model/concurrency/recovery regressions, native Chinese/English loading/error/empty/narrow previews and actual SSH acceptance; signed Dev/MCP update and documentation. No remote dependency, public release or database driver changes.

Activity acceptance follow-up: final 19 regressions passed; real native test exposed short-log buffering in the prior shell collector. Fixed bounded one-read publication, shell live-output/drain/cap/cancel/timeout suite passed; final resource rebuild and signed runtime packaging completed/in verification. Re-run real native and loopback acceptance before install.

Activity panel acceptance complete: 19 focused host tests, short-live-log/Shell suite, signed native Chinese/English previews, real-server native status/log/cancel/cleanup and final full loopback MCP suite passed. Signed Dev 20261023-145726-b5669fc6 and immutable MCP local-ssh-activity-20261023-145727-da1820 installed. SSH 0.3.0 plugin unchanged; reconnect clients for new transfer cancellation and short live logs.

## SSH connection reuse and disconnect recovery — 2026-10-23
1. Complete: optional pool capability preserving ABI1/SFTP1; exclusive session leasing, bounded idle lifetime/capacity and exact account/authentication binding.
2. Complete: host lifecycle invalidation for current credential/profile/grant changes and shutdown; old-plugin fallback, no automatic replay after submission. User-requested task/transfer panel entry removed.
3. Complete: native reuse/isolation/concurrency/dead-peer/cancel/timeout/expiry tests, host policy regressions, real server and stdio acceptance, signed dual-architecture plugin packages and Dev/MCP installation. No remote dependencies or public release.

SSH reuse complete: 48 host regressions, native pool/legacy ABI/SFTP suite, real stdio reuse and timeout recovery, new/old-plugin full loopback and protocol suites passed. SSH settings task/transfer entry removed per user direction. Dev 20261023-152935-01fde445, MCP local-ssh-reuse-20261023-152937-03a5aa and SSH 0.4.0 installed; existing clients require reconnect.

## MCP transfer progress and retained results — 2026-10-23
In progress: optional ABI1 progress callbacks, durable bounded result snapshots, MCP-only start/status/cancel/forget. Preserve stdio, old-plugin fallback, exact account grants and no remote runtime dependency or automatic retry.

MCP transfer progress and results complete: optional progress ABI1 in SSH 0.5.0; four MCP-only start/status/cancel/forget tools, durable result snapshots and bounded completed-history retention. No operating page, server runtime, resume or automatic retry. Native regression suite, 34 host regressions, full new/0.4-plugin loopback stdio suites, full authorized 192.168.0.33 acceptance, protocol suites and final signatures/tool discovery passed. Dev/MCP/plugin installed and launched; clients must reconnect. ARM package cross-built/signed, no ARM hardware run; database factories verified, no database-page changes or real database queries repeated.

## SSH routes, agent and OpenSSH import — 2026-10-23
1. Complete: traced current ABI/auth/pool/account/UI; bounded native jump transport, local agent authentication and safe preview import without external command execution.
2. Complete: shared saved-account routes/permissions, optional route extension1, MCP arguments, native agent/jump/import settings and fail-closed v2 account migration/private backup.
3. Complete: 47 host tests, native auth/agent/one-two-four-hop/SFTP/cancellation/pool suites, signed Intel/ARM packages, real-server password jump, final stdio mixed-agent routes, old-plugin fallback/capability rejection and Chinese/English offscreen layouts passed.
4. Complete: signed Dev 20261023-170602-5a25d4ac, immutable MCP local-ssh-routes-20261023-170813-4cf24a and SSH 0.6.0 installed and launched; final signatures, Dev stdio identity, 27 schemas/route extension1 and all six database factories verified. Documentation updated; clients must reconnect before saving extended accounts. No server runtime, commit or public release.

## SSH diagnostics and runtime self-check — 2026-10-23
1. Complete: optional diagnostic extension preserving ABI1, endpoint/stage errors through native and MCP callers.
2. Complete: runtime_info with captured loaded host/plugin identities and capabilities, comparison with installed Current, no credentials or remote probes.
3. Complete: native/Swift/stdio regressions, old-plugin compatibility and real-server acceptance; signed Intel/ARM SSH 0.7 packages and Dev/MCP/plugin deployment. Installed signatures, runtime_info identities/capabilities, 27 SSH schemas and all six database factories verified. No task/transfer UI, resume, remote dependencies or public release.

## SSH package distribution and update delivery — 2026-10-23
1. Complete: independent SSH component version, signed package metadata and release selection/build/recovery/deploy integration.
2. Complete: resource-server SSH upload/catalog/admin support, transactional migration preserving existing MCP/Skill records; full server tests and real signed-package integration passed.
3. Complete: signed online-update/metadata/downgrade-protection acceptance, 40 publishing/package regressions, full server tests and dual-architecture SSH artifacts; Dev/MCP/plugin installed and verified. Six database drivers unchanged. Public deployment was not selected; ready-to-publish procedure and limits recorded in docs/releases/pending-ssh-distribution.md.

## Saved Shell script library — 2026-10-25
1. Complete: private bounded persistent script store and revision-checked CRUD.
2. Complete: five MCP direct/plugin tools, policy controls, pagination and Unicode body windows; no implicit execution or SSH dependency.
3. Complete: five Shell tests plus existing SSH/optimization regressions, actual stdio persistence/CRUD/conflict/policy and protocol suites passed. Signed Dev/MCP installed and discovered; six driver factories and 12 online API5 catalogs verified. Docs and CI acceptance added. No native driver/runtime dependency or operation panel.

## Shell script settings UI — 2026-10-25
1. Complete: Shell library section inside existing SSH Servers settings, shared script-store service, editor and revision-aware deletion/copy.
2. Complete: cached file-change detection and generation-checked refresh, preserved content/drafts/conflicts, native literal source editor and bilingual accessible layouts.
3. Complete: ten model/storage/editor tests, Chinese/English light/dark offscreen validation, final signed build and Dev installation; docs updated. Changes remain uncommitted and unstaged per explicit user instruction.

## Interactive SSH client UI — 2026-10-25
1. Complete: native libssh2 PTY/duplex/resize optional extension; reuse saved accounts, pins and routes.
2. Complete: native server sidebar and persistent multi-session terminal window, tools/settings entry, disconnect/reconnect and close lifecycle. SwiftTerm local renderer only; no remote runtime or MCP activity panel.
3. Complete: native protocol and host regressions, offscreen bilingual/light/dark validation, signed Dev/plugin installation. No commit per explicit user instruction.

## Move SwiftTerm into the SSH plugin — 2026-10-25
1. Complete: remove host SwiftTerm dependency; add a signed, nested terminal renderer with a main-thread C ABI and lazy loading.
2. Complete: package/update validation, old-plugin and missing-renderer behavior, single-renderer-version lifetime and host/native tests.
3. Complete: signed Intel/ARM packages, native UI and authorized-server acceptance, rebuilt Dev install and actual size/link verification. No commit.

## SSH accounts in the welcome connection catalog — 2026-10-26
1. Complete: merge saved SSH accounts into the existing native welcome outline with shared search/count/open/edit/delete, keeping its real SSH identity and store.
2. Complete: SSH choice in Create Connection, reuse the existing account editor, move settings account entry to the welcome scene and retain only Shell settings.
3. Complete: catalog/model/outline and all-six-type regressions, bilingual native preview, signed Dev build/install. No commit. SSH uses a fixed protocol section; existing custom database grouping/drag semantics remain intact.

## SSH three-column native Glass workspace — 2026-10-26
1. Complete: reuse the database native split controller with independent SSH layout storage and collapsible left/right panes; match full-size native window/toolbar chrome.
2. Complete: server sidebar, terminal center and connection inspector with independent toggles/shortcuts, preserving renderer/session identity during layout changes.
3. Complete: 25 shared split/database and SSH/account tests passed; bilingual light/dark/narrow and three-tab compositor previews, actual native pane collapse/restore and PTY size/session retention passed. Signed Dev20261026-102721-dca28e2c installed after explicit restart authorization. No commit, no MCP activity/transfer panel.

## Saved Shell scripts in SSH inspector — 2026-10-26
1. Complete: first/default Shell Scripts tab, Connection Info second; shared library, simple name list with per-row Run/Insert, context New/Details.
2. Complete: terminal input actions with reviewed revision/live-route checks, selection/cancellation guards, no Return on insertion; multiline/large source remains one pending shell command.
3. Complete: 23 focused tests plus 6 encoder rechecks; real PTY native paste/no-early-execution, direct Run, pending Run, large source, alternate-screen guard and legacy short-input/rejection behavior passed. Signed Intel/ARM SSH 0.9.0 build 10 packaged; Dev20261026-120849-362fd47f and its native plugin installed and launched. No commit.

## Compact saved Shell editor — 2026-10-26
1. Complete: replace modal grouped cards with compact left-aligned metadata and one plain code editor; shared settings/SSH entry, 660×520, native actions and black dark canvas.
2. Complete: final build passed; Chinese/English light/dark new/edit/conflict native previews passed. Preserved literal text/undo/selection and save/cancel rules. Signed Dev20261026-122649-89c83d64 installed and restarted per existing authorization. No commit.

## SSH as a regular connection type — 2026-10-26
1. Complete: collapse standalone SSH plugin, type-choice, home and MCP authorization sections into the existing lists. Reuse plugin row/state and install/continue flow; remove repeated account-editor grants and management banners.
2. Complete: common groups/search/counts, SSH group metadata and movement, group deletion review/compensation, one MCP draft/review/save with per-account optimistic conflict checks. Preserve existing runtime grant semantics and credentials.
3. Complete: 34 initial and 30 final focused tests passed; final build and bilingual light/dark/narrow native previews passed. Signed Dev20261026-142524-8fe537b3 installed, verified and launched; previous app backed up. No commit.

## SSH output responsiveness and Vim wheel — 2026-10-26
1. Complete: bounded main-actor PTY drain, coalesced native scrolling, dirty-region redraw and stable history position.
2. Complete: trackpad accumulation, negotiated mouse wheel, alternate-screen cursor fallback and stale wheel cancellation; pinned reproducible SwiftTerm patch.
3. Complete: five release renderer tests, 30,000-line real loopback PTY output (0.67 s; maximum heartbeat gap 15.8 ms), real Vim with/without mouse reporting, full native PTY/UI regressions. Signed Intel/ARM build 11 packages and native package checks passed. Dev20261026-154027-b1efc915 and SSH build 11 installed and launched; no commit.

## Direct SSH entry and collapsed initial panes — 2026-10-26
1. Complete: home activation passes the selected saved account directly to the terminal controller, creating/selecting its session before presenting the window. Existing connecting/active sessions are reused. No dependency on an asynchronous sidebar snapshot.
2. Complete: native real-PTY regression starts with an empty/busy account list, connects immediately, and verifies repeated activation while connecting and connected creates no extra session. Existing PTY/UI regression passed.
3. Complete: new SSH windows start with both side panes collapsed; toolbar toggles remain available. Final build passed; signed Dev20261026-161600-2dc70351 installed and launched, no commit.

## All-code main integration and push — complete
Main and origin/main point to3f43e7d. All current code from mobile, main SSH workflow, original MCP/skill/parser work and ancestor feature branches is committed. Mac/iOS builds and300 regressions passed. Local notes restored; original WIP recovery refs retained.

## QueryCraft0.1.13 release — in progress
User explicitly requests release now; defer Python consolidation. Baselinev0.1.12; prepare app0.1.13/build23, MCP0.1.3/build4, Skill1.0.1/build2, SSH0.9.0/build11; updated MySQL/PG/Doris/Redis/ES with new identities and host0.1.13, keepKafkaunchanged/API5. Deploy existing sibling SSH catalog support first. Run release gates, commit/tag/push main and monitor dual-architecture CI through canonical/GitHub post-release verification. Preserve planning notes and installed user apps; no simulator/mirror workflow or unrelated refactor.

2026-10-27 release dispatched: backend27c684b3 pushed to future0923/QueryCraftMacOS; official production workflow40470290380 passed build/test/deploy. Client release commit9284bde and tagv0.1.13 pushed. Metadata app0.1.13/23, MCP0.1.3/4, Skill1.0.1/2 (minMCP0.1.3,minapp0.1.12), SSH0.9.0/11; MySQL+Doris1.0.9/10, PG1.0.8/10, Redis+ES1.0.2/3,minhost0.1.13; Kafkaunchanged/API5. Publication plan and bilingual notes validated, all12onlineAPI5 catalogs checked;53release script regressions passed. Monitoring dual-architecture build/runtime/publication and final online artifacts; no Python consolidation or user-app replacement.

## MCP usability improvements — 2026-10-28

Objective: implement SSH effective permission discovery/structured denials, bounded Kafka timestamp/key/eventId/isolation reading, complete consumer offsets, compact discovery descriptions. Preserve unrelated local work and saved grants.
1. Complete: inspected runtime/driver contracts; optional protocols preserve API 5 compatibility for existing drivers.
2. Complete: SSH grants/effective discovery/structured policy denials, distinct remote denial sources, Kafka timestamp/latest/cell windows/exact key/eventId/isolation, full offsets/lag reasons and compact discovery contract.
3. Complete: main/MCP/Kafka builds; 75 initial and 23 final MCP tests, 71 Kafka passes with 3 external-environment skips; signed relocated MCP stdio/HTTP and six-driver loading; native packaged and installed Dev driver capability checks.
4. Complete: docs and shipped reference guides updated. Signed Dev app/MCP/Kafka installed with backups and launched; actual Dev Feature/Kafka loaded paths verified. Real broker timestamp indexing, transactional visibility, authentication/TLS remain outside local fixture acceptance. No commit/tag/release or formal MCP replacement.

5. Complete: anchored native checkbox popover; shielded actual click verification proved continuous selection and draft updates, Escape/reopen preservation and dismissal on connection revocation. Shield removed.

## Git review and commit — 2026-10-28
1. Complete: reviewed pending source/tests/docs and six-driver/API impact; preserved historical planning notes.
2. Complete: main Debug and Kafka dynamic builds passed; core/protocol tests covered all 130 selected tests after fixing the stale connection-picker test; Kafka 60 passed, 14 opt-in broker tests skipped; fresh ad-hoc Kafka package signature and native loading passed.
3. Complete: created f5e3f3f (connection picker) and efa0828 (MCP/Kafka source/tests/docs). No push/tag/release. Only findings.md, progress.md and task_plan.md retain local unstaged changes.

## QueryCraft 0.1.14 release — 2026-10-30
User explicitly authorized publication. Preserve existing local notes and user app installations.
1. In progress: app 0.1.14/24, MCP 0.1.4/5, Skill 1.0.2/3; MySQL/Doris 1.0.10/11, Kafka 1.0.2/3 (minimum host 0.1.14 for new optional protocol symbols). API 5 unchanged; PG/Redis/ES/SSH unchanged.
2. Pending: fresh local main build, relevant core/driver tests, release gates and signed package/native checks; reuse recorded integration evidence with explicit limitations.
3. Pending: commit only release files, push main and immutable v0.1.14 tag; monitor dual native builds and publication.
4. Pending: verify GitHub releases/attachments, public appcast and both architectures of component/driver catalogs; record test limits and workflow URL.
Initial discovery: .xcodebuildmcp/config.yaml absent; use explicit project/workspace, scheme, configuration and cached DerivedData CLI arguments.

Local validation issue: app certificate was mistakenly used for driver package signatures. Use official CI ad-hoc driver signing; repackage and rerun MCP six-driver gate before commit. No product changes required.

2026-10-30 local preparation and validation complete: 119 core, 60 Kafka (14 real-broker skips), 61 Python gates; all three separate driver builds/packages and packaged long-wait/cancel/native Kafka checks passed. Repackaged with official CI signing; standalone MCP relocated protocol/six-driver/independent mixed-upgrade gates all passed. Proceeding to release commit/tag/push and native CI.

Release source pushed: 76b1c72 / v0.1.14. Official CI started; publication and online acceptance remain pending.

User-directed waiting stop: CI continues remotely. Await user completion notification, then check workflow 41013248346 and postflight. No further polling requested.
