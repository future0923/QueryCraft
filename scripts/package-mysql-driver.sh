#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
source "$project_root/scripts/driver-package-common.sh"
configuration="${CONFIGURATION:-Debug}"
driver_version="${DRIVER_VERSION:-1.0.3}"
driver_build="${DRIVER_BUILD:-4}"
driver_arch="${DRIVER_ARCH:-$(uname -m)}"
if [[ "$driver_arch" != "x86_64" && "$driver_arch" != "arm64" ]]; then
    print -u2 "Unsupported driver architecture: $driver_arch"
    exit 1
fi
derived_data="${DERIVED_DATA:-$project_root/.build/DerivedData}"
products="$derived_data/Build/Products/$configuration"
source_framework="$products/PackageFrameworks/QueryCraftMySQLDriver.framework"
shared_api_framework="$products/PackageFrameworks/QueryCraftFeature.framework"
output_root="${OUTPUT_ROOT:-$project_root/.build/driver-catalog}"
download_base_url="${QUERYCRAFT_DRIVER_DOWNLOAD_BASE_URL:-https://querycraft.debug-tools.cc/drivers}"
download_base_url="${download_base_url%/}"
bundle="$output_root/MySQL-$driver_arch.querycraftdriver"
macos="$bundle/Contents/MacOS"
frameworks="$bundle/Contents/Frameworks"
info_plist="$bundle/Contents/Info.plist"
manifest="$output_root/mysql-$driver_arch.json"
signing_identity="${CODE_SIGN_IDENTITY:-}"
archive_temp=""
manifest_temp=""

if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/"Apple (Development|Distribution)|"Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "$signing_identity" ]]; then
    print -u2 "No code signing identity found. Set CODE_SIGN_IDENTITY to a valid Apple signing identity."
    print -u2 "Use CODE_SIGN_IDENTITY=- for the free ad-hoc release channel."
    exit 1
fi

cleanup() {
    [[ -z "$archive_temp" || ! -e "$archive_temp" ]] || rm -f "$archive_temp"
    [[ -z "$manifest_temp" || ! -e "$manifest_temp" ]] || rm -f "$manifest_temp"
    rm -rf "$output_root/MySQL-$driver_arch.querycraftdriver.previous"
}
trap cleanup EXIT

source_binary="$source_framework/Versions/A/QueryCraftMySQLDriver"
querycraft_validate_driver_package_inputs \
    "$source_framework" \
    "QueryCraftMySQLDriver" \
    "$shared_api_framework"

mkdir -p "$output_root"
if [[ -e "$bundle" ]]; then
    mv "$bundle" "$output_root/MySQL-$driver_arch.querycraftdriver.previous"
fi
mkdir -p "$macos" "$frameworks"
binary="$macos/QueryCraftMySQLDriver"
cp "$source_binary" "$binary"

copy_framework_dependencies() {
    local input_binary="$1"
    local dependency
    local framework_name
    local source_dependency

    otool -L "$input_binary" | awk '/@rpath\/.*\.framework\// { print $1 }' | while read -r dependency; do
        framework_name="${${dependency#@rpath/}%%.framework/*}.framework"
        [[ "$framework_name" != "QueryCraftMySQLDriver.framework" ]] || continue
        [[ "$framework_name" != "QueryCraftFeature.framework" ]] || continue
        [[ ! -d "$frameworks/$framework_name" ]] || continue

        source_dependency="$products/PackageFrameworks/$framework_name"
        if [[ ! -d "$source_dependency" ]]; then
            print -u2 "Missing framework dependency: $source_dependency"
            exit 1
        fi

        cp -R "$source_dependency" "$frameworks/$framework_name"
        if [[ -f "$frameworks/$framework_name/Versions/A/${framework_name:r}" ]]; then
            copy_framework_dependencies "$frameworks/$framework_name/Versions/A/${framework_name:r}"
        fi
    done
}

copy_framework_dependencies "$binary"

thin_binary() {
    local target="$1"
    local target_architectures
    local target_mode
    local thin_temp

    target_architectures="$(lipo -archs "$target")"
    if [[ "$target_architectures" == "$driver_arch" ]]; then
        return
    fi
    if [[ " $target_architectures " != *" $driver_arch "* ]]; then
        print -u2 "Missing $driver_arch slice: $target"
        exit 1
    fi
    target_mode="$(stat -f %Lp "$target")"
    thin_temp="$(mktemp "$output_root/.mysql-thin-$driver_arch.XXXXXX")"
    lipo "$target" -thin "$driver_arch" -output "$thin_temp"
    chmod "$target_mode" "$thin_temp"
    mv "$thin_temp" "$target"
}

thin_binary "$binary"
for framework_dependency in "$frameworks"/*.framework(N); do
    framework_binary="$framework_dependency/Versions/A/${framework_dependency:t:r}"
    [[ ! -f "$framework_binary" ]] || thin_binary "$framework_binary"
done

/usr/libexec/PlistBuddy -c 'Clear dict' "$info_plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleDevelopmentRegion string en' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string QueryCraftMySQLDriver' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string io.github.future0923.QueryCraft.Driver.MySQL' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleInfoDictionaryVersion string 6.0' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string MySQL Driver' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string BNDL' "$info_plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $driver_version" "$info_plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $driver_build" "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :NSPrincipalClass string QueryCraftMySQLDriverEntry' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :QCDriverDatabaseType string mysql' "$info_plist"
/usr/libexec/PlistBuddy -c "Add :QCDriverAPIVersion integer $querycraft_driver_api_version" "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :QCMinimumAppVersion string 0.1.2' "$info_plist"

build_frameworks_rpath="$products/PackageFrameworks"
querycraft_prepare_driver_rpaths "$binary" "$build_frameworks_rpath"
querycraft_strip_local_symbols "$binary"

for framework_dependency in "$frameworks"/*.framework(N); do
    framework_binary="$framework_dependency/Versions/A/${framework_dependency:t:r}"
    [[ ! -f "$framework_binary" ]] || querycraft_strip_local_symbols "$framework_binary"
    querycraft_codesign "$signing_identity" "$framework_dependency"
done
querycraft_codesign "$signing_identity" "$binary"
querycraft_codesign "$signing_identity" "$bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"

archive_temp="$(mktemp "$output_root/.mysql-driver-$driver_version-$driver_arch.XXXXXX")"
ditto -c -k --keepParent "$bundle" "$archive_temp"
sha256="$(shasum -a 256 "$archive_temp" | cut -d ' ' -f 1)"
size="$(stat -f %z "$archive_temp")"
archive_name="mysql-driver-$driver_version-$driver_arch-${sha256[1,16]}.zip"
archive="$output_root/$archive_name"
if [[ -e "$archive" ]]; then
    rm -f "$archive_temp"
else
    mv "$archive_temp" "$archive"
fi
archive_temp=""
architectures="[\"$driver_arch\"]"

manifest_temp="$(mktemp "$output_root/.mysql-$driver_arch.json.XXXXXX")"
sed \
    -e "s|__VERSION__|$driver_version|g" \
    -e "s|__BUILD__|$driver_build|g" \
    -e "s|__SHA256__|$sha256|g" \
    -e "s|__SIZE__|$size|g" \
    -e "s|__DRIVER_API_VERSION__|$querycraft_driver_api_version|g" \
    -e "s|__ARCHITECTURES__|$architectures|g" \
    -e "s|__DOWNLOAD_BASE_URL__|$download_base_url|g" \
    -e "s|__ARCHIVE_NAME__|$archive_name|g" \
    "$project_root/scripts/mysql-driver-manifest.json.in" > "$manifest_temp"
mv "$manifest_temp" "$manifest"
manifest_temp=""

# The two architecture manifests are authoritative. Keep only their referenced
# archives after a successful package.
for stale_archive in "$output_root"/mysql-driver-*.zip(N); do
    keep_archive=0
    for current_manifest in \
        "$output_root/mysql-x86_64.json" \
        "$output_root/mysql-arm64.json"
    do
        [[ -f "$current_manifest" ]] || continue
        if querycraft_manifest_references_archive \
            "$current_manifest" "$stale_archive"
        then
            keep_archive=1
            break
        fi
    done
    (( keep_archive )) || rm -f "$stale_archive"
done
rm -f "$output_root/mysql.json"
rm -rf "$output_root/MySQL.querycraftdriver"
for stale_bundle in "$output_root"/MySQL*.querycraftdriver\ *(N); do
    rm -rf "$stale_bundle"
done
rm -f "$output_root/.DS_Store"

print "Driver bundle: $bundle"
print "Archive: $archive"
print "Manifest: $manifest"
