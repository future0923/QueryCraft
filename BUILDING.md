# Building QueryCraft

QueryCraft requires macOS 15 or later and Xcode 26. Open
`QueryCraft.xcworkspace` and build the `QueryCraft` scheme. The checked-in
Debug configuration uses Xcode's ad-hoc "Sign to Run Locally" identity, so a
paid Apple Developer account is not required for ordinary local builds.
Formal Release packaging requires Developer ID signing and Apple notarization.

The command-line build uses XcodeBuildMCP:

```sh
/usr/local/bin/xcodebuildmcp macos build \
  --workspace-path QueryCraft.xcworkspace \
  --scheme QueryCraft \
  --configuration Debug \
  --derived-data-path .build/DerivedData
```

## Developer ID distribution and saved passwords

Release packaging uses the Developer ID identity pinned by public certificate
metadata in `Config/DeveloperID.json`. Debug Xcode builds may still use ad-hoc
signing. Local signing uses the already installed private key; it never exports
it or generates a replacement. See [distribution setup](docs/APPLE_DISTRIBUTION.md)
for CI secrets, notarization, credential migration and mobile TestFlight export.

```sh
python3 scripts/code-signing.py check
python3 scripts/code-signing.py sign /path/to/fresh/QueryCraft.app
python3 scripts/code-signing.py verify /path/to/fresh/QueryCraft.app
python3 scripts/notarize.py /path/to/fresh/QueryCraft.app
```

Packaged applications use private pipes to signed credential helpers. Existing
v1/shared-v2 helpers are retained; Developer ID helpers live in an additional
`developer-id-5975A7N3W3` directory under each existing installation root. Their
caller and host checks require an Apple-trusted Developer ID from the same Team
and an allowed QueryCraft identifier. Certificate renewal within that Team does
not change the installed-helper namespace. Passwords, service names, vault IDs
and connection data remain unchanged. First use of an existing vault may need
macOS authorization for the new helper; an authorization failure never deletes
or replaces the old item. Both generations share the same vault file lock.

```sh
python3 scripts/test-credential-helper.py
python3 scripts/test-shared-credentials.py
```

These native tests use disposable credentials, disable Keychain interaction,
verify upgrades, sharing, tamper/caller rejection and remove their fixture items.
They do not claim that an old user's Keychain ACL can be migrated without consent.

The previous self-signed identity remains available only for explicit recovery:
`QUERYCRAFT_SIGNING_MODE=legacy python3 scripts/code-signing.py check`.
Its private backup stays under `~/Library/Application Support/QueryCraftSigning`;
do not delete or replace it. Legacy artifacts must not enter the Developer ID
release pipeline. Sparkle EdDSA keys and component catalog keys are unchanged.

## Database drivers

Released builds download architecture-specific database drivers from the
public QueryCraft catalog. To build all six drivers for the current Mac and
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

## Release and development isolation

The released app uses the bundle identifier `io.github.future0923.QueryCraft`
and the historical `~/Library/Application Support/QueryCraft` directory. The
local development app must use the separate bundle identifier
`io.github.future0923.QueryCraft.Dev`; the app stores its database, driver
bundles, and local license state under
`~/Library/Application Support/QueryCraftDev`.

Keep both identifiers and storage roots separate when packaging or launching
the two apps at the same time. Reusing the release storage directory can make
the development build load the release driver's state, share SQLite files, or
leave a connection test looking permanently busy in the other instance.

The helper builds and packages MySQL, PostgreSQL, Doris, Redis, Elasticsearch,
and Kafka drivers. Set `DRIVER_ARCH`, `DERIVED_DATA`, `OUTPUT_ROOT`, or
`XCODEBUILDMCP_BIN` to override its bounded defaults.

Kafka packaging must include every non-system `librdkafka` dependency, including
Homebrew's `libzstd.1.dylib`. A driver that passes code-signing checks can still
be rejected by `Bundle.load()` when one of these dylibs is missing; validate the
bundle load before installing it into an app's driver directory.

Kafka tests compile source objects but do not necessarily rebuild the dynamic
`QueryCraftKafkaDriver.framework`. Before packaging Kafka, explicitly build the
`QueryCraftKafkaDriver` scheme using the same configuration and DerivedData path
as the app. The packaging script rejects frameworks missing the current Kafka
capabilities. Also verify the packaged session, not just its principal class:

```sh
bash scripts/verify-kafka-driver.sh \
  .build/driver-catalog/Kafka-$(uname -m).querycraftdriver
```

When staging `/Applications/QueryCraftDev.app`, remove absolute build-directory
runpaths from its executable and embedded frameworks before signing. Verify with
`lsof -p <dev-app-pid>` that the process loads its bundled `QueryCraftFeature`
framework, not a mutable copy in DerivedData. Install only into the Dev app and
its `QueryCraftDev/DriverAPI-4/Drivers` directory.

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

After building the MySQL and PostgreSQL dynamic driver schemes, verify native
SQL query metadata with `python3 scripts/test-sql-query-metadata.py`. It runs
libpq and MariaDB Connector/C against temporary localhost protocol fixtures,
covering aliases, cross-schema/database origins, expression types, empty
results, and PostgreSQL metadata failure. Doris uses the same MariaDB transport.
This does not use saved connections and does not replace real-server integration
testing. Driver conversion regressions also run in the three SQL driver test
schemes, including `QueryCraftDorisDriverTests`.

For real-server checks, start the existing Docker containers
`querycraft-mysql56-test`, `querycraft-postgres16-test`, and
`querycraft-postgres17-test`, then run
`python3 scripts/test-sql-docker-metadata.py`. It loads the installed Dev drivers
and checks table/query headers and inspectors, full types, comments (including
PostgreSQL view columns), duplicate aliases, cross-schema/database joins,
expressions, and empty results. It creates uniquely named fixtures, removes
them after each check, and leaves the containers running. Credentials stay in
memory. Offscreen light/dark previews are saved under `.build/previews`.
Set `CHECK_DRIVER_DIRECTORY` to test freshly packaged drivers before installing
them, or `CHECK_FEATURE_FRAMEWORKS` to use a different Feature framework build.
These Docker fixtures do not cover a real Doris server.

Kafka regression tests can use an ephemeral localhost broker implemented by
librdkafka's mock cluster API (requires `librdkafka`, `pkg-config`, and XcodeBuildMCP):

```sh
bash scripts/test-kafka-local.sh
```

The runner creates two temporary topics, seeds both partitions with messages,
adds broker latency, and tears down the server after testing. It does not connect
to saved connections. This covers native cold reads, empty topics, partition and
offset selection, latest offsets, and the timestamp lookup API. The mock broker
does not implement realistic timestamp indexing, so exact timestamp matching
still requires verification against a real Kafka broker. Authentication and TLS
also require a separate integration environment.

The mock broker does not implement IncrementalAlterConfigs. Configuration tests
cover native unsupported-API errors, session conflict checks, safety-lock checks,
incremental request validation, and readback handling using fixtures. Successful
broker-side configuration changes require an isolated Kafka 2.3+ integration
environment; do not use saved user connections for write tests.
