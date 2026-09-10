#!/bin/bash

set -euo pipefail

postgresql_version="18.6"
postgresql_sha256="555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f"
openssl_version="3.6.3"
openssl_sha256="243a86649cf6f23eeb6a2ff2456e09e5d77dd9018a54d3d96b0c6bdd6ba6c7f1"
deployment_target="15.0"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
libs_directory="$project_root/QueryCraftDrivers/Libs"
headers_directory="$project_root/QueryCraftDrivers/Sources/CLibPQ/include"
build_directory="$(mktemp -d)"
worker_count="$(sysctl -n hw.ncpu)"

cleanup() {
    rm -rf "$build_directory"
}
trap cleanup EXIT

download() {
    local url="$1"
    local checksum="$2"
    local output="$3"
    local fallback_url="${4:-}"
    if ! curl -fL --speed-limit 1024 --speed-time 15 "$url" -o "$output"; then
        if [ -z "$fallback_url" ]; then
            return 1
        fi
        curl -fL --speed-limit 1024 --speed-time 15 "$fallback_url" -o "$output"
    fi
    echo "$checksum  $output" | shasum -a 256 -c -
}

openssl_archive="$build_directory/openssl.tar.gz"
postgresql_archive="$build_directory/postgresql.tar.bz2"
download \
    "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" \
    "$openssl_sha256" \
    "$openssl_archive" \
    "https://ghfast.top/https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz"
download \
    "https://ftp.postgresql.org/pub/source/v$postgresql_version/postgresql-$postgresql_version.tar.bz2" \
    "$postgresql_sha256" \
    "$postgresql_archive"

build_openssl() {
    local architecture="$1"
    local source_directory="$build_directory/openssl-$architecture"
    local install_directory="$build_directory/openssl-install-$architecture"
    local target="darwin64-x86_64-cc"
    if [ "$architecture" = "arm64" ]; then
        target="darwin64-arm64-cc"
    fi

    mkdir -p "$source_directory"
    tar xzf "$openssl_archive" -C "$source_directory" --strip-components=1
    (
        cd "$source_directory"
        MACOSX_DEPLOYMENT_TARGET="$deployment_target" ./Configure \
            "$target" \
            no-shared \
            no-tests \
            no-apps \
            no-docs \
            --prefix="$install_directory" \
            -mmacosx-version-min="$deployment_target"
        make -j"$worker_count"
        make install_sw
    )
}

build_libpq() {
    local architecture="$1"
    local source_directory="$build_directory/postgresql-$architecture"
    local openssl_directory="$build_directory/openssl-install-$architecture"
    local host="x86_64-apple-darwin"
    if [ "$architecture" = "arm64" ]; then
        host="aarch64-apple-darwin"
    fi

    mkdir -p "$source_directory"
    tar xjf "$postgresql_archive" -C "$source_directory" --strip-components=1
    (
        cd "$source_directory"
        MACOSX_DEPLOYMENT_TARGET="$deployment_target" \
        CFLAGS="-arch $architecture -mmacosx-version-min=$deployment_target -Wno-unguarded-availability-new -I$openssl_directory/include" \
        LDFLAGS="-arch $architecture -L$openssl_directory/lib" \
        PKG_CONFIG_PATH="$openssl_directory/lib64/pkgconfig:$openssl_directory/lib/pkgconfig" \
        ac_cv_func_strchrnul=yes \
        ./configure \
            --host="$host" \
            --with-ssl=openssl \
            --without-readline \
            --without-icu \
            --without-gssapi

        printf '%s\n' \
            '#include <stddef.h>' \
            'char *strchrnul(const char *s, int c) {' \
            '    while (*s && *s != (char)c) s++;' \
            '    return (char *)s;' \
            '}' > src/port/strchrnul_compat.c

        make -C src/include -j"$worker_count"
        make -C src/common -j"$worker_count"
        make -C src/port -j"$worker_count"
        make -C src/interfaces/libpq all-static-lib -j"$worker_count"
        cc -arch "$architecture" \
            -mmacosx-version-min="$deployment_target" \
            -c src/port/strchrnul_compat.c \
            -o src/port/strchrnul_compat.o
        ar rs src/port/libpgport_shlib.a src/port/strchrnul_compat.o
    )

    cp "$source_directory/src/interfaces/libpq/libpq.a" "$libs_directory/libpq_$architecture.a"
    cp "$source_directory/src/common/libpgcommon_shlib.a" "$libs_directory/libpgcommon_$architecture.a"
    cp "$source_directory/src/port/libpgport_shlib.a" "$libs_directory/libpgport_$architecture.a"
    cp "$openssl_directory/lib/libssl.a" "$libs_directory/libssl_$architecture.a"
    cp "$openssl_directory/lib/libcrypto.a" "$libs_directory/libcrypto_$architecture.a"
}

mkdir -p "$libs_directory" "$headers_directory"
for architecture in arm64 x86_64; do
    build_openssl "$architecture"
    build_libpq "$architecture"
done

for library in libpq libpgcommon libpgport libssl libcrypto; do
    lipo -create \
        "$libs_directory/${library}_arm64.a" \
        "$libs_directory/${library}_x86_64.a" \
        -output "$libs_directory/${library}_universal.a"
    cp "$libs_directory/${library}_universal.a" "$libs_directory/$library.a"
done

postgresql_source="$build_directory/postgresql-x86_64"
cp "$postgresql_source/src/interfaces/libpq/libpq-fe.h" "$headers_directory/libpq-fe.h"
cp "$postgresql_source/src/interfaces/libpq/libpq-events.h" "$headers_directory/libpq-events.h"
cp "$postgresql_source/src/include/postgres_ext.h" "$headers_directory/postgres_ext.h"

lipo -archs "$libs_directory/libpq_universal.a"
echo "libpq $postgresql_version and OpenSSL $openssl_version built successfully."
