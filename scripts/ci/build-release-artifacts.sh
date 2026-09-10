#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/ci/build-release-artifacts.sh <x86_64|arm64> <output-directory>

Optional environment:
  QUERYCRAFT_BUILD_UNIVERSAL_UPDATE Build the universal Sparkle ZIP (default: false)
  QUERYCRAFT_BUILD_DRIVERS          Build external driver artifacts (default: true)
  QUERYCRAFT_UPDATE_BASE_URL        Default: https://querycraft.debug-tools.cc
  QUERYCRAFT_DRIVER_DOWNLOAD_BASE_URL
                                    Default: <update-base-url>/drivers
  QUERYCRAFT_RELEASE_VERSION        Must match Config/Shared.xcconfig
  QUERYCRAFT_RELEASE_BUILD          Must match Config/Shared.xcconfig
  XCODEBUILDMCP_BIN                 Default: xcodebuildmcp from PATH
  DERIVED_DATA_ROOT                 Default: temporary directory

SPARKLE_PRIVATE_KEY is also required when
QUERYCRAFT_BUILD_UNIVERSAL_UPDATE=true.
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
build_drivers="${QUERYCRAFT_BUILD_DRIVERS:-true}"
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
if [[ "$build_universal_update" != "true" && "$build_universal_update" != "false" ]]; then
    echo "QUERYCRAFT_BUILD_UNIVERSAL_UPDATE must be true or false." >&2
    exit 65
fi
if [[ "$build_drivers" != "true" && "$build_drivers" != "false" ]]; then
    echo "QUERYCRAFT_BUILD_DRIVERS must be true or false." >&2
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

temporary_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/querycraft-release.XXXXXX")"
derived_data_root="${DERIVED_DATA_ROOT:-$temporary_root/DerivedData}"
architecture_derived_data="$derived_data_root/$architecture"
driver_output="$temporary_root/drivers-$architecture"
appcast_backup="$temporary_root/appcast.xml.original"
appcast_was_backed_up=false

cleanup() {
    if [[ "$appcast_was_backed_up" == "true" ]]; then
        cp "$appcast_backup" "$project_root/appcast.xml"
    fi
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

verify_ad_hoc_app() {
    local app_path="$1"
    local signing_info
    codesign --verify --deep --strict --verbose=2 "$app_path"
    signing_info="$(codesign -d --verbose=4 "$app_path" 2>&1)"
    if ! grep -q '^Signature=adhoc$' <<<"$signing_info"; then
        echo "Release application must use an ad-hoc signature." >&2
        exit 65
    fi
    if grep -q '^TeamIdentifier=' <<<"$signing_info" && \
       ! grep -q '^TeamIdentifier=not set$' <<<"$signing_info"; then
        echo "Ad-hoc release application unexpectedly has a signing team." >&2
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

    codesign --force --sign - --timestamp=none "$feature_framework"
    codesign --force --sign - --timestamp=none "$app_path"
}

create_dmg() {
    local app_path="$1"
    local dmg_path="$2"
    local staging_directory
    staging_directory="$(mktemp -d "$temporary_root/dmg.XXXXXX")"
    ditto "$app_path" "$staging_directory/QueryCraft.app"
    ln -s /Applications "$staging_directory/Applications"
    hdiutil create \
        -volname "QueryCraft $release_version" \
        -srcfolder "$staging_directory" \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$dmg_path"
    codesign --force --sign - --timestamp=none "$dmg_path"
    codesign --verify --verbose=2 "$dmg_path"
    hdiutil verify "$dmg_path"
}

echo "Building QueryCraft $release_version ($release_build) for $architecture."
build_scheme QueryCraft "$architecture_derived_data" "$architecture"
if [[ "$build_drivers" == "true" ]]; then
    for driver_scheme in \
        QueryCraftMySQLDriver \
        QueryCraftPostgreSQLDriver \
        QueryCraftDorisDriver \
        QueryCraftRedisDriver \
        QueryCraftElasticsearchDriver
    do
        build_scheme "$driver_scheme" "$architecture_derived_data" "$architecture"
    done
fi

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

if [[ "$build_drivers" == "true" ]]; then
    for package_script in \
        package-mysql-driver.sh \
        package-postgresql-driver.sh \
        package-doris-driver.sh \
        package-redis-driver.sh \
        package-elasticsearch-driver.sh
    do
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
    if [[ "$(find "$output_directory" -maxdepth 1 -type f -name "*-driver-*-$architecture-*.zip" | wc -l | tr -d ' ')" != "5" || \
          "$(find "$output_directory" -maxdepth 1 -type f -name "*-$architecture.json" | wc -l | tr -d ' ')" != "5" ]]; then
        echo "Expected five driver archives and manifests for $architecture." >&2
        exit 65
    fi
fi

prepare_release_app "$app_path"
verify_ad_hoc_app "$app_path"
dmg_path="$output_directory/QueryCraft-$release_version-$architecture.dmg"
create_dmg "$app_path" "$dmg_path"

if [[ "$build_universal_update" == "true" ]]; then
    require_environment SPARKLE_PRIVATE_KEY
    universal_derived_data="$derived_data_root/universal"
    build_scheme QueryCraft "$universal_derived_data" "" \
        "ARCHS=x86_64 arm64" \
        "ONLY_ACTIVE_ARCH=NO"
    universal_app="$universal_derived_data/Build/Products/Release/QueryCraft.app"
    universal_binary="$universal_app/Contents/MacOS/QueryCraft"
    universal_architectures=" $(lipo -archs "$universal_binary") "
    if [[ "$universal_architectures" != *" x86_64 "* || "$universal_architectures" != *" arm64 "* ]]; then
        echo "Universal update application is missing an architecture slice." >&2
        exit 65
    fi
    prepare_release_app "$universal_app"
    verify_ad_hoc_app "$universal_app"

    update_zip="$output_directory/QueryCraft-$release_version.zip"
    ditto -c -k --sequesterRsrc --keepParent "$universal_app" "$update_zip"

    generate_appcast="$(find "$universal_derived_data" -type f -name generate_appcast -perm -111 -print -quit)"
    if [[ -z "$generate_appcast" ]]; then
        echo "Sparkle generate_appcast was not found in universal DerivedData." >&2
        exit 69
    fi
    release_notes="$project_root/docs/releases/$release_version.md"
    if [[ ! -f "$release_notes" ]]; then
        echo "Release notes not found: $release_notes" >&2
        exit 66
    fi
    cp "$project_root/appcast.xml" "$appcast_backup"
    appcast_was_backed_up=true
    SPARKLE_TOOLS_DIR="$(dirname "$generate_appcast")" \
    SPARKLE_PRIVATE_KEY="$SPARKLE_PRIVATE_KEY" \
    QUERYCRAFT_UPDATE_BASE_URL="$update_base_url" \
    QUERYCRAFT_ALLOW_UNNOTARIZED_UPDATE=true \
        "$project_root/scripts/generate-appcast.sh" \
            "$release_version" "$update_zip" "$release_notes"
    cp "$project_root/appcast.xml" "$output_directory/appcast.xml"
    cp "$release_notes" "$output_directory/release-notes.md"
    cp "$appcast_backup" "$project_root/appcast.xml"
    appcast_was_backed_up=false
fi

echo "Release artifacts: $output_directory"
