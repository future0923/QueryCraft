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

Database drivers are installed on demand for the current Mac architecture.

## Core experience

- Multiple connections and isolated database workspaces
- Restorable query documents, tabs, and editing state
- SQL highlighting, completion, formatting, and statement or batch execution
- Safety Lock write protection, SQL previews, and unified commits
- A native virtualized, direct-drawn grid for substantial results
- Search, copy, paging, server-side sorting, and filtering
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
[BUILDING.md](BUILDING.md) to build the app and all five drivers with
XcodeBuildMCP.

## Repository layout

```text
QueryCraft.xcworkspace/       Xcode workspace
QueryCraft.xcodeproj/         macOS application shell
QueryCraft/                   App entry point, resources, and configuration
QueryCraftPackage/            Main features and tests
QueryCraftDrivers/            Five installable database drivers
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
