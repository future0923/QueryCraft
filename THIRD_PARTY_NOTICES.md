# Third-Party Notices

## DBX database brand assets

The MySQL, PostgreSQL, Apache Doris, and SelectDB brand artwork in
`QueryCraftPackage/Sources/QueryCraftFeature/Resources/DatabaseBrands.xcassets`
is sourced from the [DBX project](https://github.com/t8y2/dbx), licensed under
the Apache License 2.0. The original product names and trademarks remain the
property of their respective owners.

## Native database client libraries

The installable database drivers link MariaDB Connector/C, PostgreSQL libpq,
and OpenSSL. Their versions, licenses, source locations, checksums, and rebuild
instructions are recorded in `QueryCraftDrivers/Libs/VERSIONS.md` and
`ThirdPartyLicenses/NATIVE-LIBRARIES.md`.

## MCP runtime

The MCP implementation uses the official [Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk)
(MIT), [EventSource](https://github.com/mattt/eventsource) (MIT), and Apple's
[SwiftNIO](https://github.com/apple/swift-nio), Swift Log, Swift Atomics,
Swift System and Swift Collections (Apache 2.0 with Swift runtime exception where stated).
Exact revisions are pinned in `QueryCraftPackage/Package.resolved`. License texts
and upstream notices are included in `ThirdPartyLicenses` and the standalone MCP bundle.
