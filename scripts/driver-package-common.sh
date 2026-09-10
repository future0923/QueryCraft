#!/bin/zsh

# Keep this synchronized with
# DatabaseDriverCompatibilityValidator.currentDriverAPIVersion.
querycraft_driver_api_version=3

# Shared preflight for every external database-driver package.
querycraft_validate_driver_package_inputs() {
    local source_framework="$1"
    local driver_binary_name="$2"
    local shared_api_framework="$3"
    local source_binary="$source_framework/Versions/A/$driver_binary_name"
    local shared_api_binary="$shared_api_framework/Versions/A/QueryCraftFeature"

    if [[ ! -f "$source_binary" ]]; then
        print -u2 "Missing driver binary: $source_binary"
        return 1
    fi
    if [[ ! -f "$shared_api_binary" ]]; then
        print -u2 "Missing shared driver API framework: $shared_api_framework"
        return 1
    fi
}

# Developer ID artifacts need a trusted timestamp and Hardened Runtime before
# Apple will notarize them. Local Apple Development and ad-hoc builds remain
# timestamp-free so existing development packaging keeps working offline.
querycraft_codesign() {
    local signing_identity="$1"
    local target="$2"
    local signing_arguments=(--force --sign "$signing_identity")

    if [[ "$signing_identity" == "Developer ID Application:"* ]]; then
        signing_arguments+=(--timestamp --options runtime)
    else
        signing_arguments+=(--timestamp=none)
    fi
    codesign "${signing_arguments[@]}" "$target"
}

querycraft_binary_has_rpath() {
    local binary="$1"
    local expected="$2"

    otool -l "$binary" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { expecting_path = 1; next }
        expecting_path && $1 == "path" { print $2; expecting_path = 0 }
    ' | grep -Fqx -- "$expected"
}

querycraft_prepare_driver_rpaths() {
    local binary="$1"
    local build_frameworks_rpath="$2"
    local runtime_rpath

    if querycraft_binary_has_rpath "$binary" "$build_frameworks_rpath"; then
        install_name_tool -delete_rpath "$build_frameworks_rpath" "$binary"
    fi
    for runtime_rpath in \
        '@executable_path/../Frameworks' \
        '@loader_path/../Frameworks'
    do
        if ! querycraft_binary_has_rpath "$binary" "$runtime_rpath"; then
            install_name_tool -add_rpath "$runtime_rpath" "$binary"
        fi
    done
}

querycraft_strip_local_symbols() {
    local binary="$1"

    strip -x "$binary"
    if nm -m "$binary" 2>/dev/null | \
        awk '/non-external/ { found = 1 } END { exit(found ? 0 : 1) }'
    then
        print -u2 "Packaged driver binary still contains local symbols: $binary"
        return 1
    fi
}

# Development catalogs may contain either one package or the schema-v2
# releases array. Preserve archives referenced by either representation.
querycraft_manifest_references_archive() {
    local manifest="$1"
    local archive="$2"
    local download_url

    download_url="$(plutil -extract downloadURL raw -o - "$manifest" 2>/dev/null)" \
        || download_url="$(plutil -extract releases.0.downloadURL raw -o - "$manifest" 2>/dev/null)" \
        || return 1
    [[ "${download_url:t}" == "${archive:t}" ]]
}
