# Syntax highlighting audit

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
