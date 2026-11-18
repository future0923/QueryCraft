# Mac App Store channel

This target shares the native app and database code with the direct-download
edition. It uses App Sandbox, StoreKit and the existing iOS app's bundle ID for
universal purchase. It does not use Sparkle or download executable components.
Do not upload a development build or treat the checks below as App Review approval.

## Generate and build

Run `bash scripts/generate-store-project.sh` at the repository root. This restores
the checked-in SwiftPM lock after XcodeGen creates the ignored Xcode project.
When intentionally changing dependencies, review and copy the generated lock back
to `QueryCraftStore/Package.resolved`.

Set `QC_STORE_COMPONENTS_DIR` as an Xcode build setting to an absolute local folder:

```
<components>/Drivers/*.querycraftdriver
<components>/QueryCraftSSH.bundle/Contents/PlugIns/TerminalRenderer.bundle
```

The seven drivers must use Driver API 5; each plugin entrypoint must contain every requested architecture.
The build step validates the source components' Apple signature and team, copies
them into the app, and signs the copies with the selected app identity before
Xcode signs the outer app. It performs no network downloads and does not change
the original components. Build against reviewed, hash-verified component releases.

Use scheme `QueryCraftStore`, team `5975A7N3W3`, automatic signing and the intended
architecture. Development builds require a registered Mac and Apple Development
profile. App Store export requires the appropriate distribution profile and
certificate; a successful development build alone does not satisfy this requirement.

Run `python3 scripts/check-store-app.py <path/to/QueryCraft.app>` on the exported
candidate. `--unsigned-build` checks structure only and deliberately skips release
signing gates. Debug builds are expected to fail the release `get-task-allow` gate.

For a universal build, run `scripts/assemble-store-components.py <intel> <arm>
<new-output> --identity <Apple-identity>` against both verified release sets. This
creates new Store-only copies and preserves the original release artifacts. It
requires matching component identities/resources and combines native entrypoints
with `lipo`. Architecture-specific leaf dependencies remain intact: for example,
the current Kafka slices use OpenSSL 3 on Intel and OpenSSL 4 on ARM. These libraries
are not ABI substitutes. The final app gate follows actual load commands separately
for each architecture, checking that every selected dependency is present with the
correct slice. Successful assembly alone is not App Store acceptance.

Run `QC_STORE_COMPONENTS_DIR=<absolute-universal-folder> bash scripts/archive-store.sh
<new-output-directory>` for archive and export. `QC_STORE_DERIVED_DATA` can reuse an
existing compatible build cache. The script verifies the exported installer and
expanded app, including distribution provisioning, both architectures, signature,
CloudKit environment and dependency closure. It never uploads or submits review.

## Runtime differences and acceptance

- All seven drivers and SSH ship inside the reviewed app; updates use App Store.
- MCP uses the same protocol, policy and authorization code, hosted inside the app
  over HTTP. Keep QueryCraft running. Standalone stdio/LaunchAgent integration is
  exclusive to the direct edition. External client configuration is copied manually.
- SSH private-key and config-file selection saves read-only, device-local security
  bookmarks. They are not part of synced connection data. Each Mac grants access
  independently. Missing/moved files ask the user to select them again.
- Skill installation asks for the client's `skills` folder through the system
  picker and saves a local writable bookmark. Unmanaged/local edits retain the
  existing protection against overwrite. The internal fixture install/remove
  lifecycle has passed inside App Sandbox; real external-folder picker interaction
  remains a separate acceptance check.
- SSH agent sockets, config `Include` paths and SFTP user-selected destinations
  still require sandbox acceptance. Do not claim these flows
  are finished based on unsandboxed unit tests.
- Complete signed sandbox driver/SSH/MCP runtime testing, ARM testing, StoreKit
  sandbox/production routing, no-appAccountToken ownership handling and Apple
  submission metadata before upload. See `docs/PAID_SYNC_PLAN.md` for remaining gates.

`QueryCraftStoreTests` runs MCP lifecycle/security, updater isolation and local
file-grant tests. It is an unhosted test target; it does not by itself demonstrate
that the app runs correctly inside App Sandbox. Real StoreKit transaction lifecycle
tests use the separate `Tests/StoreKitHost` target and never ship in this app.

`QueryCraftStoreProbe` is a separate development-only signed App Sandbox host. It
does not launch the product's application model, touch user connection libraries,
or start CloudKit. Pass an existing unselected file outside its container as its
only argument. It verifies that the file is denied, loads all seven bundled driver
entrypoints and SSH, checks MCP HTTP authorization/shutdown, then installs/removes
a Skill fixture in its own temporary directory. Its success does not imply that
database server authentication, external file picker flows or ARM execution were
tested. Never upload this diagnostic target.
