# Native library licenses and source

QueryCraft's downloadable drivers contain statically linked native libraries.
The exact versions and checksums are recorded in
`QueryCraftDrivers/Libs/VERSIONS.md` and `QueryCraftDrivers/Libs/checksums.sha256`.

| Component | License | Upstream source |
| --- | --- | --- |
| MariaDB Connector/C 3.4.9 | GNU LGPL 2.1 or later | https://archive.mariadb.org/connector-c-3.4.9/ |
| PostgreSQL libpq 18.6 | PostgreSQL License | https://ftp.postgresql.org/pub/source/v18.6/ |
| OpenSSL 3.6.3 | Apache License 2.0 | https://github.com/openssl/openssl/releases/tag/openssl-3.6.3 |

The complete terms are included as `MARIADB-CONNECTOR-C-LICENSE.txt`,
`POSTGRESQL-LICENSE.txt`, and `OPENSSL-LICENSE.txt` in this directory.

The corresponding build scripts download and verify the upstream source before
producing the checked-in universal and architecture-specific libraries. Users
may relink modified versions of the LGPL library by rebuilding it and then
rebuilding the QueryCraft drivers with the replacement archive.

This notice supplements those license texts and does not change their terms.
