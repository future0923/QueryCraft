#!/bin/bash

set -euo pipefail

mariadb_version="3.4.9"
mariadb_sha256="a84bba97e59b6a322637a189964d4fd72bd8d92f2d22a9f8d6a5f0657c821e97"
deployment_target="15.0"
cmake_bin="${CMAKE_BIN:-}"
if [ -z "$cmake_bin" ]; then
    cmake_bin="$(command -v cmake || true)"
fi
openssl_root="${OPENSSL_ROOT:-}"
if [ -z "$openssl_root" ] && command -v brew >/dev/null 2>&1; then
    openssl_root="$(brew --prefix openssl@3 2>/dev/null || true)"
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
libs_directory="$project_root/QueryCraftDrivers/Libs"
headers_directory="$project_root/QueryCraftDrivers/Sources/CMariaDB/include"
build_directory="$(mktemp -d)"
worker_count="$(sysctl -n hw.ncpu)"

cleanup() {
    rm -rf "$build_directory"
}
trap cleanup EXIT

if [ ! -x "$cmake_bin" ]; then
    echo "CMake not found at $cmake_bin" >&2
    exit 1
fi
if [ ! -d "$openssl_root" ]; then
    echo "OpenSSL not found at $openssl_root" >&2
    exit 1
fi

archive="$build_directory/mariadb-connector-c.tar.gz"
curl -fL "https://archive.mariadb.org/connector-c-$mariadb_version/mariadb-connector-c-$mariadb_version-src.tar.gz" -o "$archive"
echo "$mariadb_sha256  $archive" | shasum -a 256 -c -
tar xzf "$archive" -C "$build_directory"
source_directory="$build_directory/mariadb-connector-c-$mariadb_version-src"

build_slice() {
    local architecture="$1"
    local slice_source="$build_directory/source-$architecture"
    local slice_build="$slice_source/build"

    cp -R "$source_directory" "$slice_source"
    mkdir -p "$slice_build"
    "$cmake_bin" -S "$slice_source" -B "$slice_build" \
        -DCMAKE_OSX_ARCHITECTURES="$architecture" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_C_FLAGS="-w -Wno-error -Wno-inline-asm -Wno-deprecated-non-prototype -Wno-macro-redefined" \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_EXTERNAL_ZLIB=ON \
        -DWITH_SSL=OPENSSL \
        -DOPENSSL_ROOT_DIR="$openssl_root" \
        -DOPENSSL_SSL_LIBRARY="$openssl_root/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$openssl_root/lib/libcrypto.a" \
        -DOPENSSL_INCLUDE_DIR="$openssl_root/include" \
        -DWITH_UNIT_TESTS=OFF \
        -DWITH_CURL=OFF \
        -DCLIENT_PLUGIN_AUTH_GSSAPI_CLIENT=OFF \
        -DCLIENT_PLUGIN_DIALOG=STATIC \
        -DCLIENT_PLUGIN_MYSQL_CLEAR_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_CACHING_SHA2_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_SHA256_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_MYSQL_NATIVE_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_MYSQL_OLD_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_PVIO_NPIPE=OFF \
        -DCLIENT_PLUGIN_PVIO_SHMEM=OFF
    "$cmake_bin" --build "$slice_build" --target mariadbclient -j"$worker_count"
    cp "$slice_build/libmariadb/libmariadbclient.a" "$libs_directory/libmariadb_$architecture.a"
}

mkdir -p "$libs_directory" "$headers_directory/mysql" "$headers_directory/mariadb"
build_slice arm64
build_slice x86_64
lipo -create \
    "$libs_directory/libmariadb_arm64.a" \
    "$libs_directory/libmariadb_x86_64.a" \
    -output "$libs_directory/libmariadb_universal.a"
cp "$libs_directory/libmariadb_universal.a" "$libs_directory/libmariadb.a"

for header in errmsg.h ma_list.h ma_pvio.h ma_tls.h mariadb_com.h mariadb_ctype.h mariadb_dyncol.h mariadb_rpl.h mariadb_stmt.h mysql.h mysqld_error.h; do
    cp "$source_directory/include/$header" "$headers_directory/$header"
done
cp "$build_directory/source-x86_64/build/include/mariadb_version.h" "$headers_directory/mariadb_version.h"
cp "$source_directory/include/mysql/client_plugin.h" "$headers_directory/mysql/client_plugin.h"
cp "$source_directory/include/mysql/plugin_auth.h" "$headers_directory/mysql/plugin_auth.h"
cp "$source_directory/include/mariadb/ma_io.h" "$headers_directory/mariadb/ma_io.h"

nm "$libs_directory/libmariadb_x86_64.a" > "$build_directory/libmariadb-symbols.txt"
grep -q clear_password_client_plugin "$build_directory/libmariadb-symbols.txt"
lipo -archs "$libs_directory/libmariadb_universal.a"
echo "MariaDB Connector/C $mariadb_version built successfully."
