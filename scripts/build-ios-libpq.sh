#!/bin/bash
# Build from the same pinned sources as the desktop driver, without touching Libs/.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
platform="${1:-iphonesimulator}"
architecture="${2:-$(uname -m)}"
version=18.6
sha=555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f
output="$root/.build/ios-native/$platform-$architecture"
cache="$root/.build/ios-native/downloads"
developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
workers="${IOS_BUILD_JOBS:-4}"
case "$platform" in
    iphonesimulator) sdk="$developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"; triple="$architecture-apple-ios18.0-simulator" ;;
    iphoneos) sdk="$developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"; triple="$architecture-apple-ios18.0" ;;
    *) echo 'Expected iphoneos or iphonesimulator' >&2; exit 1 ;;
esac
[[ -f "$output/lib/libssl.a" ]] || bash "$root/scripts/build-ios-mariadb.sh" "$platform" "$architecture"
mkdir -p "$cache" "$output/lib"
archive="$cache/postgresql-$version.tar.bz2"
if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 2 "https://ftp.postgresql.org/pub/source/v$version/postgresql-$version.tar.bz2" -o "$archive.partial"
    mv "$archive.partial" "$archive"
fi
echo "$sha  $archive" | shasum -a 256 -c -
identity="$version/$triple/$sdk"
if [[ -f "$output/.libpq-complete" && "$(cat "$output/.libpq-complete")" == "$identity" ]]; then
    (cd "$output"; shasum -a 256 -c libpq-checksums.sha256)
    exit 0
fi
source="$root/.build/ios-native/libpq-$platform-$architecture"
mkdir -p "$source"
tar xjf "$archive" -C "$source" --strip-components=1
clang="$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
host=x86_64-apple-darwin
[[ "$architecture" != arm64 ]] || host=aarch64-apple-darwin
(
    cd "$source"
    CC="$clang" CFLAGS="-target $triple -isysroot $sdk -I$output/include -Wno-unguarded-availability-new" \
    LDFLAGS="-target $triple -isysroot $sdk -L$output/lib" \
    PKG_CONFIG=/usr/bin/false ac_cv_func_strchrnul=yes \
    ./configure --host="$host" --with-ssl=openssl --without-readline --without-icu --without-gssapi --without-ldap --without-zlib --without-lz4 --without-zstd
    make -C src/include -j"$workers"
    make -C src/common -j"$workers"
    make -C src/port -j"$workers"
    make -C src/interfaces/libpq all-static-lib -j"$workers"
    printf '%s\n' '#include <stddef.h>' 'char *strchrnul(const char *s, int c) { while (*s && *s != (char)c) s++; return (char *)s; }' > src/port/strchrnul_ios.c
    "$clang" -target "$triple" -isysroot "$sdk" -c src/port/strchrnul_ios.c -o src/port/strchrnul_ios.o
    ar rs src/port/libpgport_shlib.a src/port/strchrnul_ios.o
) > "$source/build.log" 2>&1 || { tail -70 "$source/build.log"; exit 1; }
cp "$source/src/interfaces/libpq/libpq.a" "$output/lib/libpq.a"
cp "$source/src/common/libpgcommon_shlib.a" "$output/lib/libpgcommon.a"
cp "$source/src/port/libpgport_shlib.a" "$output/lib/libpgport.a"
(cd "$output"; shasum -a 256 lib/libpq.a lib/libpgcommon.a lib/libpgport.a > libpq-checksums.sha256)
printf '%s\n' "$identity" > "$output/.libpq-complete"
echo "Built libpq $version for $triple"
