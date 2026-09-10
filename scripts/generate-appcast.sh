#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: scripts/generate-appcast.sh <version> <update-zip> [release-notes]"
    echo "Defaults to docs/releases/<version>.md when release-notes is omitted."
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage
    exit 64
fi

version="$1"
update_zip="$2"
keychain_account="io.github.future0923.QueryCraft"
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
release_notes="${3:-$repository_root/docs/releases/${version}.md}"
update_base_url="${QUERYCRAFT_UPDATE_BASE_URL:-https://querycraft.debug-tools.cc}"
update_base_url="${update_base_url%/}"
allow_unnotarized="${QUERYCRAFT_ALLOW_UNNOTARIZED_UPDATE:-false}"

if [[ "$update_base_url" != https://* ]]; then
    echo "QUERYCRAFT_UPDATE_BASE_URL must use HTTPS." >&2
    exit 65
fi

if [[ ! -f "$update_zip" ]]; then
    echo "Update archive not found: $update_zip" >&2
    exit 66
fi

if [[ ! -f "$release_notes" ]]; then
    echo "Release notes not found: $release_notes" >&2
    exit 66
fi

sparkle_tools_dir="${SPARKLE_TOOLS_DIR:-}"
if [[ -n "$sparkle_tools_dir" ]]; then
    generate_appcast="$sparkle_tools_dir/generate_appcast"
elif command -v generate_appcast >/dev/null 2>&1; then
    generate_appcast="$(command -v generate_appcast)"
else
    generate_appcast="$(
        find "${HOME}/Library/Developer/Xcode/DerivedData" \
            -type f -name generate_appcast -perm -111 -print -quit \
            2>/dev/null
    )"
fi

if [[ -z "${generate_appcast:-}" || ! -x "$generate_appcast" ]]; then
    echo "Sparkle generate_appcast was not found." >&2
    echo "Set SPARKLE_TOOLS_DIR to the directory containing Sparkle's tools." >&2
    exit 69
fi

staging_directory="$(mktemp -d /tmp/querycraft-appcast.XXXXXX)"
trap 'rm -rf "$staging_directory"' EXIT

archive_name="QueryCraft-${version}.zip"
cp "$update_zip" "$staging_directory/$archive_name"

if [[ -f "$repository_root/appcast.xml" ]]; then
    cp "$repository_root/appcast.xml" "$staging_directory/appcast.xml"
fi

cp "$release_notes" "$staging_directory/QueryCraft-${version}.md"

extracted_directory="$staging_directory/extracted"
mkdir "$extracted_directory"
ditto -x -k "$staging_directory/$archive_name" "$extracted_directory"

app_path="$extracted_directory/QueryCraft.app"
if [[ ! -d "$app_path" ]]; then
    echo "The update archive must contain QueryCraft.app at its root." >&2
    exit 65
fi

archive_version="$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString)"
if [[ "$archive_version" != "$version" ]]; then
    echo "Version mismatch: requested $version, archive contains $archive_version." >&2
    exit 65
fi

if [[ "$allow_unnotarized" == "true" ]]; then
    if ! codesign --verify --deep --strict --verbose=2 "$app_path"; then
        echo "The unnotarized update has an invalid code signature." >&2
        exit 65
    fi
    signing_info="$(codesign -d --verbose=4 "$app_path" 2>&1)"
    grep -q '^Identifier=io.github.future0923.QueryCraft$' \
        <<<"$signing_info" || {
            echo "The unnotarized update has the wrong bundle identifier." >&2
            exit 65
        }
    grep -q '^Signature=adhoc$' <<<"$signing_info" || {
            echo "The unnotarized update must use an ad-hoc signature." >&2
            exit 65
        }
    if codesign -d --entitlements :- "$app_path" 2>&1 \
        | grep -q 'com.apple.security.app-sandbox'; then
            echo "The unnotarized Release must not enable App Sandbox." >&2
            exit 65
    fi
    echo "Warning: publishing an unnotarized update for manual Gatekeeper approval." >&2
else
    codesign --verify --deep --strict --verbose=2 "$app_path"
    if ! codesign -dv --verbose=4 "$app_path" 2>&1 \
        | grep -q '^Authority=Developer ID Application:'; then
        echo "The update must be signed with a Developer ID Application certificate." >&2
        exit 65
    fi
    xcrun stapler validate "$app_path"
fi

download_prefix="${update_base_url}/releases/"
generate_arguments=(
    --download-url-prefix "$download_prefix"
    --embed-release-notes
    --maximum-versions 0
    --account "$keychain_account"
    "$staging_directory"
)

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" \
        | "$generate_appcast" \
            --ed-key-file - \
            --download-url-prefix "$download_prefix" \
            --embed-release-notes \
            --maximum-versions 0 \
            "$staging_directory"
else
    "$generate_appcast" "${generate_arguments[@]}"
fi

cp "$staging_directory/appcast.xml" "$repository_root/appcast.xml"

echo "Generated appcast.xml for QueryCraft ${version}."
echo "Download URL: ${download_prefix}${archive_name}"
echo "Deploy the archive first, then deploy appcast.xml last."
