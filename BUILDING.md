# Building QueryCraft

QueryCraft requires macOS 15 or later and Xcode 26. Open
`QueryCraft.xcworkspace` and build the `QueryCraft` scheme. The checked-in
configuration uses Xcode's ad-hoc "Sign to Run Locally" identity, so a paid
Apple Developer account and a personal development team are not required.

The command-line build uses XcodeBuildMCP:

```sh
/usr/local/bin/xcodebuildmcp macos build \
  --workspace-path QueryCraft.xcworkspace \
  --scheme QueryCraft \
  --configuration Debug \
  --derived-data-path .build/DerivedData
```

## Database drivers

Released builds download architecture-specific database drivers from the
public QueryCraft catalog. To build all five drivers for the current Mac and
serve them locally:

```sh
scripts/build-local-drivers.sh
scripts/serve-local-driver-catalog.sh
```

Then launch the Debug executable from a terminal with the local catalog URL:

```sh
QUERYCRAFT_DRIVER_CATALOG_BASE_URL=http://127.0.0.1:8788/ \
  .build/DerivedData/Build/Products/Debug/QueryCraft.app/Contents/MacOS/QueryCraft
```

The helper builds and packages MySQL, PostgreSQL, Doris, Redis, and
Elasticsearch drivers. Set `DRIVER_ARCH`, `DERIVED_DATA`, `OUTPUT_ROOT`, or
`XCODEBUILDMCP_BIN` to override its bounded defaults.

The prebuilt MariaDB Connector/C, PostgreSQL libpq, and OpenSSL static libraries
are reproducible from checksummed upstream sources. See
`QueryCraftDrivers/Libs/VERSIONS.md` and the two `scripts/build-*-driver-library.sh`
scripts.

## GitHub release configuration

Future client releases use these repository settings:

- Secret `SPARKLE_PRIVATE_KEY`: Ed25519 private key used to sign Sparkle update
  archives.
- Secret `QUERYCRAFT_RESOURCE_DEPLOY_TOKEN`: bearer token accepted by the
  LicenseServer resource deployment API.
- Optional variable `QUERYCRAFT_RESOURCE_DEPLOY_URL`: HTTPS resource deployment
  endpoint. It defaults to the production QueryCraft endpoint.

The public repository does not require production SSH host, user, host-key, or
private-key secrets. Those belong only to the private LicenseServer repository.

## Tests

Run tests through XcodeBuildMCP and select only the suites relevant to a
change. Several AppKit editor and window suites own process-global state and
must be run in isolation; their constraints are documented alongside the test
sources.
