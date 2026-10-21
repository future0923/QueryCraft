#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/ci/build-release-artifacts.sh <x86_64|arm64> <output-directory>

Optional environment:
  QUERYCRAFT_BUILD_CLIENT           Build application release artifacts (default: true)
  QUERYCRAFT_BUILD_UNIVERSAL_UPDATE Deprecated; must remain false
  QUERYCRAFT_BUILD_SKILL            Package changed Skill on arm64 (default: false)
  QUERYCRAFT_BUILD_DRIVERS          Build external driver artifacts (default: true)
  QUERYCRAFT_DRIVER_TARGET          all, mysql, postgresql, doris, redis,
                                    elasticsearch, or kafka (default: all)
  QUERYCRAFT_UPDATE_BASE_URL        Default: https://querycraft.debug-tools.cc
  QUERYCRAFT_DRIVER_DOWNLOAD_BASE_URL
                                    Default: <update-base-url>/drivers
  QUERYCRAFT_RELEASE_VERSION        Must match Config/Shared.xcconfig
  QUERYCRAFT_RELEASE_BUILD          Must match Config/Shared.xcconfig
  XCODEBUILDMCP_BIN                 Default: xcodebuildmcp from PATH
  DERIVED_DATA_ROOT                 Default: temporary directory

SPARKLE_PRIVATE_KEY is required for client update signing in CI.
Local packaging can use the existing Sparkle Keychain account.
Client builds require the persistent identity installed by scripts/code-signing.py.
EOF
}

if [[ $# -ne 2 ]]; then
    usage
    exit 64
fi

architecture="$1"
output_directory="$2"
if [[ "$architecture" != "x86_64" && "$architecture" != "arm64" ]]; then
    echo "Unsupported architecture: $architecture" >&2
    exit 65
fi

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
workspace="$project_root/QueryCraft.xcworkspace"
configuration_file="$project_root/Config/Shared.xcconfig"
xcodebuildmcp_bin="${XCODEBUILDMCP_BIN:-$(command -v xcodebuildmcp || true)}"
build_universal_update="${QUERYCRAFT_BUILD_UNIVERSAL_UPDATE:-false}"
build_client="${QUERYCRAFT_BUILD_CLIENT:-true}"
build_drivers="${QUERYCRAFT_BUILD_DRIVERS:-true}"
driver_target="${QUERYCRAFT_DRIVER_TARGET:-all}"
update_base_url="${QUERYCRAFT_UPDATE_BASE_URL:-https://querycraft.debug-tools.cc}"
update_base_url="${update_base_url%/}"
driver_download_base_url="${QUERYCRAFT_DRIVER_DOWNLOAD_BASE_URL:-$update_base_url/drivers}"
driver_download_base_url="${driver_download_base_url%/}"

require_environment() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "$name is required." >&2
        exit 64
    fi
}

if [[ -z "$xcodebuildmcp_bin" || ! -x "$xcodebuildmcp_bin" ]]; then
    echo "XcodeBuildMCP CLI was not found." >&2
    exit 69
fi
if [[ "$build_universal_update" != "false" ]]; then
    echo "Universal updates are replaced by architecture-specific client updates." >&2
    exit 65
fi
if [[ "$build_client" != "true" && "$build_client" != "false" ]]; then
    echo "QUERYCRAFT_BUILD_CLIENT must be true or false." >&2
    exit 65
fi
if [[ "$build_drivers" != "true" && "$build_drivers" != "false" ]]; then
    echo "QUERYCRAFT_BUILD_DRIVERS must be true or false." >&2
    exit 65
fi
if [[ "$driver_target" != "all" && \
      "$driver_target" != "mysql" && \
      "$driver_target" != "postgresql" && \
      "$driver_target" != "doris" && \
      "$driver_target" != "redis" && \
      "$driver_target" != "elasticsearch" && \
      "$driver_target" != "kafka" ]]; then
    echo "Unsupported QUERYCRAFT_DRIVER_TARGET: $driver_target" >&2
    exit 65
fi
if [[ "$build_client" != "true" && "$build_drivers" != "true" ]]; then
    echo "At least one release artifact type must be enabled." >&2
    exit 65
fi
if [[ "$update_base_url" != https://* || "$driver_download_base_url" != https://* ]]; then
    echo "Release download URLs must use HTTPS." >&2
    exit 65
fi

configured_version="$(awk -F ' = ' '/^MARKETING_VERSION = / { print $2; exit }' "$configuration_file")"
configured_build="$(awk -F ' = ' '/^CURRENT_PROJECT_VERSION = / { print $2; exit }' "$configuration_file")"
release_version="${QUERYCRAFT_RELEASE_VERSION:-$configured_version}"
release_build="${QUERYCRAFT_RELEASE_BUILD:-$configured_build}"
if [[ "$release_version" != "$configured_version" || "$release_build" != "$configured_build" ]]; then
    echo "Requested release $release_version ($release_build) does not match configured release $configured_version ($configured_build)." >&2
    exit 65
fi
if [[ ! "$release_version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ || ! "$release_build" =~ ^[0-9]+$ ]]; then
    echo "Invalid release version or build number." >&2
    exit 65
fi

# Fail before compilation if the persistent identity is missing. Driver-only
# jobs keep their existing ad-hoc channel and do not need this private key.
if [[ "$build_client" == "true" ]]; then
    if [[ "${CI:-false}" == "true" ]]; then
        require_environment SPARKLE_PRIVATE_KEY
    fi
    python3 "$project_root/scripts/code-signing.py" check
fi

temporary_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/querycraft-release.XXXXXX")"
derived_data_root="${DERIVED_DATA_ROOT:-$temporary_root/DerivedData}"
architecture_derived_data="$derived_data_root/$architecture"
driver_output="$temporary_root/drivers-$architecture"

cleanup() {
    rm -rf "$temporary_root"
}
trap cleanup EXIT

mkdir -p "$output_directory" "$driver_output" "$derived_data_root"

common_build_settings=(
    "CODE_SIGN_IDENTITY=-"
    "DEVELOPMENT_TEAM="
    "CODE_SIGN_STYLE=Manual"
    "ENABLE_HARDENED_RUNTIME=NO"
    "ENABLE_CODE_COVERAGE=NO"
    "DEAD_CODE_STRIPPING=YES"
    "COPY_PHASE_STRIP=YES"
    "STRIP_INSTALLED_PRODUCT=YES"
    "STRIP_STYLE=non-global-symbols"
)

build_scheme() {
    local scheme="$1"
    local derived_data="$2"
    local target_architecture="$3"
    shift 3
    local settings=("${common_build_settings[@]}" "$@")
    local arguments=(
        macos build
        --workspace-path "$workspace"
        --scheme "$scheme"
        --configuration Release
        --derived-data-path "$derived_data"
    )
    if [[ -n "$target_architecture" ]]; then
        arguments+=(--arch "$target_architecture")
    fi
    arguments+=(--extra-args "${settings[@]}" --output json)
    "$xcodebuildmcp_bin" "${arguments[@]}"
}

verify_release_app() {
    local app_path="$1"
    local entitlements
    python3 "$project_root/scripts/code-signing.py" verify "$app_path"
    entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null)"
    if grep -q '<key>com.apple.security.app-sandbox</key>' <<<"$entitlements"; then
        echo "The free distribution application must not enable App Sandbox." >&2
        exit 65
    fi
    if ! grep -q '<key>com.apple.security.network.client</key>' <<<"$entitlements"; then
        echo "Release application is missing the network client entitlement." >&2
        exit 65
    fi
}

prepare_release_app() {
    local app_path="$1"
    local app_binary="$app_path/Contents/MacOS/QueryCraft"
    local feature_framework="$app_path/Contents/Frameworks/QueryCraftFeature.framework"
    local feature_binary="$feature_framework/Versions/A/QueryCraftFeature"
    local binary
    local load_commands

    for binary in "$app_binary" "$feature_binary"; do
        if [[ ! -f "$binary" ]]; then
            echo "Release application binary is missing: $binary" >&2
            exit 66
        fi

        load_commands="$(otool -l "$binary")"
        if grep -Eq '(__LLVM_COV|__llvm_prf_)' <<<"$load_commands"; then
            echo "Release application contains code coverage instrumentation: $binary" >&2
            exit 65
        fi

        strip -x "$binary"
        if nm -m "$binary" 2>/dev/null | \
            awk '/non-external/ { found = 1 } END { exit(found ? 0 : 1) }'
        then
            echo "Release application still contains local symbols: $binary" >&2
            exit 65
        fi
    done

    if [[ "${QUERYCRAFT_BUILD_MCP:-false}" == "true" ]]; then
        build_scheme querycraft-mcp "$architecture_derived_data" "$architecture"
        local mcp_staging
        mcp_staging="$(mktemp -d "$temporary_root/mcp.XXXXXX")"
        python3 "$project_root/scripts/package-mcp.py" \
            --build-dir "$(dirname "$app_path")" --architecture "$architecture" \
            --output "$mcp_staging/QueryCraft MCP.app"
        python3 "$project_root/scripts/test-mcp-protocol.py" \
            "$mcp_staging/QueryCraft MCP.app/Contents/MacOS/querycraft-mcp"
        cp "$mcp_staging/"*.zip "$mcp_staging/"*.package.json "$output_directory/"
        local component_sign_tool
        component_sign_tool="$(find "$derived_data_root" -name sign_update -type f -perm -111 -print -quit)"
        python3 "$project_root/scripts/package-components.py" --component mcp --sign-existing \
            --output "$output_directory" --sign-tool "$component_sign_tool"
    fi
    python3 "$project_root/scripts/code-signing.py" sign "$app_path"
}

create_dmg() {
    local app_path="$1"
    local dmg_path="$2"
    local staging_directory
    local source_dmg
    staging_directory="$(mktemp -d "$temporary_root/dmg.XXXXXX")"
    source_dmg="${staging_directory}.dmg"
    ditto "$app_path" "$staging_directory/QueryCraft.app"
    ln -s /Applications "$staging_directory/Applications"
    hdiutil create \
        -volname "QueryCraft $release_version" \
        -srcfolder "$staging_directory" \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$source_dmg"
    # ULMO is supported since macOS 10.15; QueryCraft requires macOS 15.
    # Recompressing the finished filesystem gave smaller images than creating
    # ULMO directly, with identical files, permissions and signatures.
    hdiutil convert "$source_dmg" -format ULMO -o "$dmg_path"
    rm -f "$source_dmg"
    codesign --force --sign - --timestamp=none "$dmg_path"
    codesign --verify --verbose=2 "$dmg_path"
    hdiutil verify "$dmg_path"
}

selected_driver_targets=()
if [[ "$build_drivers" == "true" ]]; then
    if [[ "$driver_target" == "all" ]]; then
        selected_driver_targets=(mysql postgresql doris redis elasticsearch kafka)
    else
        selected_driver_targets=("$driver_target")
    fi
fi

if [[ "$build_client" == "true" ]]; then
    echo "Building QueryCraft $release_version ($release_build) for $architecture."
    build_scheme QueryCraft "$architecture_derived_data" "$architecture"
fi

if [[ "$build_drivers" == "true" ]]; then
    for selected_driver in "${selected_driver_targets[@]}"; do
        case "$selected_driver" in
            mysql) driver_scheme=QueryCraftMySQLDriver ;;
            postgresql) driver_scheme=QueryCraftPostgreSQLDriver ;;
            doris) driver_scheme=QueryCraftDorisDriver ;;
            redis) driver_scheme=QueryCraftRedisDriver ;;
            elasticsearch) driver_scheme=QueryCraftElasticsearchDriver ;;
            kafka) driver_scheme=QueryCraftKafkaDriver ;;
        esac
        echo "Building $selected_driver driver for $architecture."
        build_scheme "$driver_scheme" "$architecture_derived_data" "$architecture"
    done
fi

if [[ "$build_client" == "true" ]]; then
    app_path="$architecture_derived_data/Build/Products/Release/QueryCraft.app"
    app_binary="$app_path/Contents/MacOS/QueryCraft"
    if [[ ! -x "$app_binary" ]]; then
        echo "Built application is missing: $app_path" >&2
        exit 66
    fi
    if [[ "$(lipo -archs "$app_binary")" != "$architecture" ]]; then
        echo "Application does not contain only the requested $architecture slice." >&2
        exit 65
    fi
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")" != "$release_version" || \
          "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")" != "$release_build" ]]; then
        echo "Built application version does not match release metadata." >&2
        exit 65
    fi
fi

if [[ "$build_drivers" == "true" ]]; then
    for selected_driver in "${selected_driver_targets[@]}"; do
        case "$selected_driver" in
            mysql) package_script=package-mysql-driver.sh ;;
            postgresql) package_script=package-postgresql-driver.sh ;;
            doris) package_script=package-doris-driver.sh ;;
            redis) package_script=package-redis-driver.sh ;;
            elasticsearch) package_script=package-elasticsearch-driver.sh ;;
            kafka) package_script=package-kafka-driver.sh ;;
        esac
        CONFIGURATION=Release \
        DRIVER_ARCH="$architecture" \
        DERIVED_DATA="$architecture_derived_data" \
        OUTPUT_ROOT="$driver_output" \
        CODE_SIGN_IDENTITY=- \
        QUERYCRAFT_DRIVER_DOWNLOAD_BASE_URL="$driver_download_base_url" \
            "$project_root/scripts/$package_script"
    done

    for driver_file in "$driver_output"/*.zip "$driver_output"/*-"$architecture".json; do
        if [[ -f "$driver_file" ]]; then
            cp "$driver_file" "$output_directory/"
        fi
    done
    expected_driver_count="${#selected_driver_targets[@]}"
    if [[ "$(find "$output_directory" -maxdepth 1 -type f -name "*-driver-*-$architecture-*.zip" | wc -l | tr -d ' ')" != "$expected_driver_count" || \
          "$(find "$output_directory" -maxdepth 1 -type f -name "*-$architecture.json" | wc -l | tr -d ' ')" != "$expected_driver_count" ]]; then
        echo "Expected $expected_driver_count driver archive(s) and manifest(s) for $architecture." >&2
        exit 65
    fi
fi

if [[ "$build_client" == "true" ]]; then
    prepare_release_app "$app_path"
    verify_release_app "$app_path"
    dmg_path="$output_directory/QueryCraft-$release_version-$architecture.dmg"
    create_dmg "$app_path" "$dmg_path"
    sign_tool="$(find "$architecture_derived_data" -type f -name sign_update -perm -111 -print -quit)"
    test -n "$sign_tool"
    python3 "$project_root/scripts/update-archives.py" package \
        --app "$app_path" --architecture "$architecture" \
        --directory "$output_directory" --sign-tool "$sign_tool"
    python3 "$project_root/scripts/test-sparkle-updates.py" \
        --sparkle-directory "$(dirname "$(dirname "$sign_tool")")"
    if [[ "${QUERYCRAFT_BUILD_SKILL:-false}" == "true" && "$architecture" == "arm64" ]]; then
        python3 "$project_root/scripts/package-components.py" --component skill \
            --output "$output_directory" --sign-tool "$sign_tool"
    fi
fi

echo "Release artifacts: $output_directory"
