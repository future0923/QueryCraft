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

## Persistent signing for saved passwords

Distributed applications now use a fixed self-signed code-signing certificate.
Ad-hoc signatures change identity when the executable changes, causing Keychain
to request access again after an update. The public certificate fingerprint is
pinned in `Config/CodeSigningIdentity.txt`; no private key is checked in.

The maintainer's signing material is stored in
`~/Library/Application Support/QueryCraftSigning` (directory mode 700, secret
files mode 600). Back up this whole directory securely, especially `identity.p12`
and `p12-password`. Losing it and generating a replacement changes the identity
and requires users to authorize access again. The certificate is valid for ten
years. `python3 scripts/code-signing.py init` reuses the existing identity and
refuses to replace a pinned certificate with a new one.

For a local non-sandboxed app, finish all binary and bundle edits first, then run:

```sh
python3 scripts/code-signing.py sign /path/to/QueryCraftDev.app
python3 scripts/code-signing.py verify /path/to/QueryCraftDev.app
```

The free Release channel uses `Config/Release.entitlements` without App Sandbox,
matching its Sparkle installer configuration. Ordinary Debug builds retain their
existing sandbox settings; the signing helper rejects sandboxed bundles rather
than silently changing their storage and permission behavior. Release packaging
builds intermediate ad-hoc binaries, strips them, then applies the pinned
certificate to the host and QueryCraftFeature framework. Sparkle's embedded
upstream signatures and existing Ed25519 update key remain unchanged. External
drivers still use the existing ad-hoc channel (the self-signed host has no Apple
Team ID).

Before running the updated GitHub release workflow, configure these repository
Actions secrets using the **existing** local identity:

- `QUERYCRAFT_SIGNING_P12_BASE64`: base64 of `identity.p12`.
- `QUERYCRAFT_SIGNING_P12_PASSWORD`: contents of `p12-password`.
- Keep the existing `SPARKLE_PRIVATE_KEY` unchanged.

CI imports the identity into a temporary keychain, checks its fingerprint, and
removes it after packaging, including partial imports when a job fails. Client
builds check the identity before compiling. They fail if it is missing or incorrect;
it never generates a new one or silently falls back to ad-hoc application signing.
Self-signing does not provide Apple notarization or eliminate Gatekeeper's
first-install warnings. Previously saved ad-hoc Keychain entries may need one
more **Always Allow** authorization when first used by the new identity.

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
