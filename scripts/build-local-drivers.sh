#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
workspace="$project_root/QueryCraft.xcworkspace"
derived_data="${DERIVED_DATA:-$project_root/.build/DerivedData}"
output_root="${OUTPUT_ROOT:-$project_root/.build/driver-catalog}"
configuration="${CONFIGURATION:-Debug}"
driver_arch="${DRIVER_ARCH:-$(uname -m)}"
xcodebuildmcp_bin="${XCODEBUILDMCP_BIN:-/usr/local/bin/xcodebuildmcp}"
catalog_url="${QUERYCRAFT_DRIVER_DOWNLOAD_BASE_URL:-http://127.0.0.1:8788}"

if [[ "$driver_arch" != "arm64" && "$driver_arch" != "x86_64" ]]; then
    echo "Unsupported driver architecture: $driver_arch" >&2
    exit 65
fi
if [[ ! -x "$xcodebuildmcp_bin" ]]; then
    echo "XcodeBuildMCP was not found at $xcodebuildmcp_bin." >&2
    exit 69
fi

mkdir -p "$derived_data" "$output_root"

for scheme in \
    QueryCraftMySQLDriver \
    QueryCraftPostgreSQLDriver \
    QueryCraftDorisDriver \
    QueryCraftRedisDriver \
    QueryCraftElasticsearchDriver
do
    "$xcodebuildmcp_bin" macos build \
        --workspace-path "$workspace" \
        --scheme "$scheme" \
        --configuration "$configuration" \
        --derived-data-path "$derived_data" \
        --arch "$driver_arch" \
        --extra-args \
            "CODE_SIGN_IDENTITY=-" \
            "DEVELOPMENT_TEAM=" \
            "CODE_SIGN_STYLE=Manual" \
        --output json
done

for package_script in \
    package-mysql-driver.sh \
    package-postgresql-driver.sh \
    package-doris-driver.sh \
    package-redis-driver.sh \
    package-elasticsearch-driver.sh
do
    CONFIGURATION="$configuration" \
    DRIVER_ARCH="$driver_arch" \
    DERIVED_DATA="$derived_data" \
    OUTPUT_ROOT="$output_root" \
    CODE_SIGN_IDENTITY=- \
    QUERYCRAFT_DRIVER_DOWNLOAD_BASE_URL="$catalog_url" \
        "$project_root/scripts/$package_script"
done

archive_count="$(find "$output_root" -maxdepth 1 -type f -name "*-driver-*-$driver_arch-*.zip" | wc -l | tr -d ' ')"
manifest_count="$(find "$output_root" -maxdepth 1 -type f -name "*-$driver_arch.json" | wc -l | tr -d ' ')"
if [[ "$archive_count" != "5" || "$manifest_count" != "5" ]]; then
    echo "Expected five driver archives and manifests for $driver_arch." >&2
    exit 65
fi

echo "Driver catalog: $output_root"
echo "Start it with scripts/serve-local-driver-catalog.sh"
