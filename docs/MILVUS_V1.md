# Milvus REST browse milestone

Update on 2026-11-05: Dev MCP now provides `execute_milvus_request` for read-only Query, Get and single-query Search, alongside database/Collection discovery, schema and schema context. The authorized Dev connection is limited to the default database with read-only access. Live MCP acceptance passed against estate_ai_listing, including its 23 fields, 1024-dimensional COSINE search, two scored hits and textual Int64 IDs. Main MCP/session tests passed 37 methods and Milvus driver tests passed five. Relocated standalone stdio/HTTP and all seven installed driver types passed loading checks. Existing six-driver live services were not rerun.

The dynamic Milvus product must be built separately from its test target before packaging. The bundle-loading check now requires the REST execution interface, preventing a stale browse-only binary from passing acceptance. Desktop Dev, standalone Dev MCP and the Milvus driver were installed locally. Codex's existing querycraft-dev client entry is currently disabled, so it needs enabling and reconnection to expose the new tool in a chat. The source Skill and MCP usage guide include the read workflow.

Update on 2026-11-04: the installed macOS Dev framework and installed Milvus driver now pass live read-only checks against the authorized default database. Both estate_ai_community (10 fields) and estate_ai_listing (23 fields) returned 25 rows at offsets 0 and 25, followed by a successful repeat of offset 0. Saved credentials were read back from the shared Keychain vault. Earlier network failures below are historical.

REST v2 implementation without C++, gRPC or Conan dependencies.

Available: connection profiles (port 19530, database default), Bearer credentials, database/Collection listing, schema/primary-key/vector-dimension parsing, dynamic data columns and JSON/vector previews. macOS uses the existing grid and common refresh; iOS/iPadOS share the same session/parser through the resource browser.

Paging requires offset + limit < 16384. Responses are bounded to 32 MiB. TLS modes, cancellation and refusal of redirects follow the existing HTTP driver pattern. Generic SQL filtering/sorting/editing, transactions and exact count are unavailable. Vector Search UI and write operations remain outstanding. Offset pagination is not a snapshot. Collections must already be loaded/queryable.

## Validation — 2026-11-04

- SwiftPM Milvus product build and four focused protocol tests passed.
- Native macOS driver/framework and QueryCraft Debug app builds passed.
- Ad-hoc signed Intel package passed signature checks and actual bundle loading, activation and read-only session factory verification.
- iOS/iPadOS source compiled to link, but complete simulator linking failed: the existing .build/ios-native/iphonesimulator-x86_64/lib directory is absent, including libpq. Complete mobile build and device/UI acceptance remain outstanding.
- Current Alibaba Cloud read-only recheck returned 502 through the proxy and timed out directly. Earlier successful checks established default and the two estate collections; the new driver has not completed live-server acceptance.
- No database writes, installed app replacement, desktop input, commit, tag or publication.

## Local package

The package is .build/milvus-driver-catalog/Milvus-x86_64.querycraftdriver, with ZIP and architecture manifest alongside. The online driver catalog is not updated.

    swift test --package-path QueryCraftDrivers --disable-sandbox --skip-update --filter Milvus
    CONFIGURATION=Debug CODE_SIGN_IDENTITY=- OUTPUT_ROOT="$PWD/.build/milvus-driver-catalog" /bin/zsh scripts/package-milvus-driver.sh
    python3 scripts/test-milvus-driver-loading.py "$PWD/.build/milvus-driver-catalog/Milvus-x86_64.querycraftdriver"

All seven driver targets compiled in the focused test build. MySQL explicitly rejects the new Collection object kind; existing-driver live regression was not rerun. The local build/package script now includes Milvus.
