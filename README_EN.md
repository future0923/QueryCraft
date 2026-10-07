# QueryCraft

**A native open-source database workspace built for macOS.**

[简体中文](README.md) · [Download](https://github.com/future0923/QueryCraft/releases/latest) · [Build](BUILDING.md) · [Report an issue](https://github.com/future0923/QueryCraft/issues)

QueryCraft brings connections, database objects, SQL documents, results, and
data editing into focused workspaces while following native macOS conventions.

Every feature in the current version is free and requires no purchase or
license activation. QueryCraft's original source code is available under the
[GNU Affero General Public License v3.0](LICENSE).

## Database support

| Database | Current capabilities |
| --- | --- |
| MySQL / MariaDB | Object browsing, SQL queries, table data and schema editing, export |
| PostgreSQL | Database / Schema contexts, SQL queries, data and schema workflows, export |
| Apache Doris / SelectDB | Connections, object browsing, and SQL queries |
| Redis | Database and key browsing, type resolution, value editing, command documents |
| Elasticsearch | Indices, aliases, data streams, mappings, documents, and REST requests |
| Kafka | Topic creation / deletion, message sending, partition / offset / time navigation, raw messages, consumer groups and lag |

Kafka data defaults to JSON Table, with a JSON Table / Raw Value switch in the read bar. Object fields expand into paths such as `value.user.id`; literal dots and backslashes in keys are escaped. Arrays stay intact and numeric tokens retain their exact precision. Original Value and non-JSON content remain available; the inspector and Copy as New Message use the original message. Find, copy and current-data export use the displayed fields; export covers the messages already read. Live columns freeze after the first JSON batch; Rebuild JSON Columns includes later fields. Expansion is limited to 128 columns, 1 MB per value, 32 nesting levels and a parsing budget; unsupported values remain raw.

The read bar's Filter supports Key, Value, or either field, contains/exact matching, and case sensitivity. Scan uses the chosen partition and start position with a default 10,000-message limit (1,000 or 100,000 also available), about 30 seconds, and a 64 MB budget. Progress reports scanned/matched counts and the stopping reason. Results reuse the message grid, raw inspector, and pagination. The shared refresh reruns the scan; cancellation or failure preserves the previous results. Find searches loaded rows only.

Send Message in the topic's data footer supports automatic or explicit partition selection, nullable keys, JSON/text values, and duplicate header names (UTF-8, up to 1 MB total). Disable the workspace safety lock before sending. Success shows the broker-confirmed partition and offset. In-flight sends prevent repeated submission; errors retain the draft. Check the topic before retrying any delivery whose result was not confirmed.

Live reads start at the current end using the selected partition and filter. Pause closes the reader; Resume continues from its saved next offsets. Stop ends reading, and Live starts a new session from the end. Retention is capped at 10,000 rows or 32 MB with received, matched, and evicted counts. Scrolling up preserves the viewport; Latest returns to the end. Shared refresh reads from the current position, errors retain existing results, and switching tabs pauses reading. No consumer offsets are committed.

The librdkafka-based Kafka driver supports unauthenticated connections, SASL/PLAIN,
SCRAM-SHA-256/512, and TLS. The Consumer Groups view shows committed offsets,
log boundaries, and lag per partition; missing or unavailable offsets remain unknown.
The Structure tab shows partition leaders, replicas, ISR, and topic configuration,
including retention and cleanup policies. Partition metadata remains visible if
configuration access is denied. Confirmed topic-related consumer groups appear
first, with total lag and lagging partition counts. Optional 15-second refresh
updates the selected group; bounded relationship checks leave unconfirmed groups visible.
The Members tab shows client IDs, hosts, member IDs, static instance IDs, and
assignments for the current topic, together with group state and assignment strategy.
It supports manual refresh and the same optional automatic refresh.

Right-click a sidebar topic and choose “Delete Topic…” to delete it after entering its exact name and disabling Safety Lock. An acknowledged deletion removes its sidebar entry and open tab; rejection or timeout preserves the page and explains the failure. Unconfirmed results require refreshing the topic list to verify; writes are never retried automatically. Internal Kafka topics cannot be deleted, and pending configuration changes must be committed or discarded first.

Double-click configuration values in Structure to edit all writable properties, including inherited values; edits automatically create topic overrides. Right-click to restore defaults or revert a property. Broker read-only and sensitive properties cannot be edited. Changes are highlighted and use the shared top toolbar to preview, commit or discard. Refresh preserves drafts and their conflict baselines. Commits require safety-lock confirmation, submit only changed properties with IncrementalAlterConfigs, check for conflicts, and reread the result. Writes require Kafka 2.3+ and DescribeConfigs / AlterConfigs permissions. After an unconfirmed result, discard the draft and refresh current server values before editing again.
Select a partition with known lag and use View Pending Messages to read from its
committed offset. Navigation is unavailable for caught-up, unknown, or invalid positions.
Browsing messages and groups never commits offsets. Lag counts offset positions,
which may differ from actual message counts in compacted topics.

Database drivers are installed on demand for the current Mac architecture.

## Core experience

- Multiple connections and isolated database workspaces
- Restorable query documents, tabs, and editing state
- SQL highlighting, completion, formatting, and statement or batch execution
- Safety Lock write protection, SQL previews, and unified commits
- A native virtualized, direct-drawn grid for substantial results
- Search, copy, paging, server-side sorting, and filtering
- Automatic local date/time display for timestamp columns in SQL, Kafka, and Elasticsearch grids (enabled by default; toggle in Settings → Data); column-header menus offer raw, Unix seconds, and milliseconds formats, while editing, copying, and exporting preserve raw values
- Excel, CSV, JSON, JSON Lines, and SQL export
- Simplified Chinese and English in Light and Dark appearance
- Signed updates through Sparkle

## Download and build

GitHub Releases provides separate DMGs for Apple Silicon and Intel Macs.
QueryCraft requires **macOS 15 or later**. The free distribution channel uses
ad-hoc signing. If macOS blocks the first launch, verify the source under
**System Settings > Privacy & Security** and choose **Open Anyway**.

Building from source does not require a paid Apple Developer account. Open
`QueryCraft.xcworkspace` and select the `QueryCraft` scheme, or follow
[BUILDING.md](BUILDING.md) to build the app and all six drivers with
XcodeBuildMCP.

## Repository layout

```text
QueryCraft.xcworkspace/       Xcode workspace
QueryCraft.xcodeproj/         macOS application shell
QueryCraft/                   App entry point, resources, and configuration
QueryCraftPackage/            Main features and tests
QueryCraftDrivers/            Six installable database drivers
QueryCraftUITests/            UI automation tests
Config/                       Public build configuration
scripts/                      Local build and client release tools
ThirdParty/                   Third-party source under its original licenses
ThirdPartyLicenses/           Third-party licenses and provenance
```

The licensing service, deployment credentials, and internal design documents
are not part of this public repository.

## License

QueryCraft's original source code is licensed under `AGPL-3.0-only`.
Third-party source, libraries, and assets remain under their respective terms;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
`ThirdPartyLicenses/`.
