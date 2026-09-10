# Native Driver Libraries

The downloadable database drivers use the same native C client approach as
TablePro. The checked-in build libraries are universal (`arm64` and `x86_64`)
and target macOS 15.0 or later. Packaging thins those build inputs into separate
`arm64` and `x86_64` downloads so each Mac receives only its native slice.

| Driver | Native library | Version |
| --- | --- | --- |
| MySQL and MariaDB | MariaDB Connector/C | 3.4.9 |
| PostgreSQL | libpq | 18.6 |
| TLS for all drivers | OpenSSL | 3.6.3 |

Rebuild the libraries from checksummed upstream source with:

```sh
./scripts/build-mariadb-driver-library.sh
./scripts/build-postgresql-driver-library.sh
```

After a rebuild, update `checksums.sha256`, rebuild both Xcode driver schemes,
and build each driver scheme with `ARCHS="x86_64 arm64"` and
`ONLY_ACTIVE_ARCH=NO`. Generate both downloads from that universal build input:

```sh
DRIVER_ARCH=x86_64 ./scripts/package-mysql-driver.sh
DRIVER_ARCH=arm64 ./scripts/package-mysql-driver.sh
DRIVER_ARCH=x86_64 ./scripts/package-doris-driver.sh
DRIVER_ARCH=arm64 ./scripts/package-doris-driver.sh
DRIVER_ARCH=x86_64 ./scripts/package-postgresql-driver.sh
DRIVER_ARCH=arm64 ./scripts/package-postgresql-driver.sh
```

The packaging scripts reject a requested slice that is missing from the build
input, sign each thinned bundle independently, and retain only the archives
referenced by the six architecture-specific manifests.
