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


Database drivers install on demand for the current Mac architecture.

## What makes QueryCraft different

- Native macOS workspaces with multiple connections, restorable documents and tabs, and Light/Dark appearance.
- SQL highlighting, completion, formatting and batch execution, with customizable editor colors.
- A virtualized, directly rendered grid for large results, with search, filtering and data editing.
- SQL previews, Safety Lock and transactional writes for controlled database changes.
- Import and export across common spreadsheet, text and SQL formats.
- MySQL schema comparison and synchronization with reviewed deployment SQL.
- Reusable cross-database transfer tasks with structure/data copying, Upsert, background progress and cancellation.
- Native MySQL LOAD DATA and PostgreSQL COPY pipelines with bounded streaming memory.
- Independent MCP integration for AI tools, with scoped database permissions and shared credential authorization.
- Simplified Chinese and English, plus signed automatic updates.

## Measured performance

Release measurements transferring **10 million rows**, with every field verified after completion:

| Transfer | Time | Peak memory* |
| --- | ---: | ---: |
| MySQL → MySQL | 102.06 s | 36.62 MiB |
| PostgreSQL → PostgreSQL | 45.75 s | 26.34 MiB |
| MySQL → PostgreSQL | 48.94 s | 40.05 MiB |
| PostgreSQL → MySQL | 121.81 s | 40.62 MiB |

*One-second sampled RSS of the transfer test process, not total app/database memory. Local Docker: MySQL 5.7/8.0 and PostgreSQL 17, five mixed-type columns, batches of 1,000; each database container limited to 4 CPUs and 2 GiB. Timings include execution checks and commit, excluding fixture generation and final verification. Results depend on schema, hardware and network conditions.

## Download and build

Supports **macOS 15 or later**, with separate DMGs for Apple Silicon and Intel Macs.
See [BUILDING.md](BUILDING.md) for source builds; a paid Apple Developer account is not required.

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
