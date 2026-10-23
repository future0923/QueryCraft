#!/bin/bash
# Isolated proof artifacts only; never overwrites the macOS driver libraries.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/.build/ios-native"
cache="$output/downloads"
developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
clang="$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
cmake="${CMAKE_BIN:-$root/.build/ios-tools/cmake/data/bin/cmake}"
workers="${IOS_BUILD_JOBS:-4}"
openssl_version="3.6.3"
openssl_sha="243a86649cf6f23eeb6a2ff2456e09e5d77dd9018a54d3d96b0c6bdd6ba6c7f1"
mariadb_version="3.4.9"
mariadb_sha="a84bba97e59b6a322637a189964d4fd72bd8d92f2d22a9f8d6a5f0657c821e97"
mkdir -p "$cache"
[[ -x "$cmake" ]] || { echo "Set CMAKE_BIN to CMake 3.31+ (see QueryCraftMobile/README.md)." >&2; exit 1; }

download() {
    local url="$1" sha="$2" file="$3"
    if [[ ! -f "$file" ]]; then
        curl --fail --location --retry 2 --connect-timeout 20 --max-time 300 "$url" -o "$file.partial"
        mv "$file.partial" "$file"
    fi
    echo "$sha  $file" | shasum -a 256 -c -
}
download "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" "$openssl_sha" "$cache/openssl.tar.gz"
download "https://archive.mariadb.org/connector-c-$mariadb_version/mariadb-connector-c-$mariadb_version-src.tar.gz" "$mariadb_sha" "$cache/mariadb.tar.gz"

build_slice() {
    local platform="$1" arch="$2" sdk platform_dir triple configure_target destination
    case "$platform" in
        iphoneos)
            platform_dir="iPhoneOS"; triple="$arch-apple-ios18.0"; configure_target="ios64-xcrun" ;;
        iphonesimulator)
            platform_dir="iPhoneSimulator"; triple="$arch-apple-ios18.0-simulator"
            if [[ "$arch" == "arm64" ]]; then configure_target="iossimulator-arm64-xcrun"; else configure_target="iossimulator-x86_64-xcrun"; fi ;;
        *) echo "Unsupported platform: $platform" >&2; exit 1 ;;
    esac
    sdk="$developer/Platforms/$platform_dir.platform/Developer/SDKs/$platform_dir.sdk"
    destination="$output/$platform-$arch"
    local identity="$openssl_version/$mariadb_version/$triple/$sdk"
    if [[ -f "$destination/.complete" ]] && [[ "$(cat "$destination/.complete")" == "$identity" ]] \
        && shasum -a 256 -c "$destination/checksums.sha256" >/dev/null 2>&1; then
        echo "Using verified build $platform-$arch"; return
    fi
    local source="$output/work-$platform-$arch"
    mkdir -p "$source/openssl" "$source/mariadb" "$destination/lib"
    tar xzf "$cache/openssl.tar.gz" -C "$source/openssl" --strip-components=1
    tar xzf "$cache/mariadb.tar.gz" -C "$source/mariadb" --strip-components=1
    echo "Building OpenSSL $platform-$arch (log: $source/openssl.log)"
    (
        cd "$source/openssl"
        CC="$clang" SDKROOT="$sdk" ./Configure "$configure_target" no-shared no-tests no-apps no-docs no-dso no-module \
            --prefix="$destination" --libdir=lib "--target=$triple" -isysroot "$sdk" || exit 1
        make -j"$workers" || exit 1
        make install_sw || exit 1
    ) > "$source/openssl.log" 2>&1 || { tail -60 "$source/openssl.log"; return 1; }
    echo "Building MariaDB $platform-$arch (log: $source/mariadb.log)"
    (
        "$cmake" -S "$source/mariadb" -B "$source/mariadb/build" \
            -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$arch" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 -DCMAKE_C_COMPILER="$clang" \
            -DCMAKE_C_FLAGS="-target $triple -Wno-error -Wno-deprecated-non-prototype" \
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=OFF -DWITH_UNIT_TESTS=OFF -DWITH_CURL=OFF \
            -DWITH_EXTERNAL_ZLIB=ON -DWITH_SSL=OPENSSL \
            -DOPENSSL_ROOT_DIR="$destination" -DOPENSSL_SSL_LIBRARY="$destination/lib/libssl.a" \
            -DOPENSSL_CRYPTO_LIBRARY="$destination/lib/libcrypto.a" -DOPENSSL_INCLUDE_DIR="$destination/include" \
            -DCLIENT_PLUGIN_AUTH_GSSAPI_CLIENT=OFF -DCLIENT_PLUGIN_PVIO_NPIPE=OFF -DCLIENT_PLUGIN_PVIO_SHMEM=OFF \
            -DCLIENT_PLUGIN_DIALOG=STATIC -DCLIENT_PLUGIN_MYSQL_CLEAR_PASSWORD=STATIC \
            -DCLIENT_PLUGIN_CACHING_SHA2_PASSWORD=STATIC -DCLIENT_PLUGIN_SHA256_PASSWORD=STATIC \
            -DCLIENT_PLUGIN_MYSQL_NATIVE_PASSWORD=STATIC -DCLIENT_PLUGIN_MYSQL_OLD_PASSWORD=STATIC || exit 1
        "$cmake" --build "$source/mariadb/build" --target mariadbclient -j"$workers" || exit 1
        cp "$source/mariadb/build/libmariadb/libmariadbclient.a" "$destination/lib/"
    ) > "$source/mariadb.log" 2>&1 || { tail -60 "$source/mariadb.log"; return 1; }
    shasum -a 256 "$destination/lib/"*.a > "$destination/checksums.sha256"
    printf '%s\n' "$identity" > "$destination/.complete"
    echo "Built $destination"
}

# One slice can be built while investigating a failure; default covers both CPU families.
if [[ $# -eq 2 ]]; then
    build_slice "$1" "$2"
else
    build_slice iphonesimulator "$(uname -m)"
    build_slice iphoneos arm64
    if [[ "$(uname -m)" != "arm64" ]]; then build_slice iphonesimulator arm64; fi
fi
