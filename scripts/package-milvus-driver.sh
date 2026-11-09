#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
source "$project_root/scripts/driver-package-common.sh"
querycraft_driver_minimum_app_version="${DRIVER_MINIMUM_APP_VERSION:-0.1.15}"
configuration="${CONFIGURATION:-Debug}"
driver_version="${DRIVER_VERSION:-0.1.0}"
driver_build="${DRIVER_BUILD:-2}"
driver_arch="${DRIVER_ARCH:-$(uname -m)}"
if [[ "$driver_arch" != "x86_64" && "$driver_arch" != "arm64" ]]; then
    print -u2 "Unsupported driver architecture: $driver_arch"
    exit 1
fi
derived_data="${DERIVED_DATA:-$project_root/.build/DerivedData}"
products="$derived_data/Build/Products/$configuration"
source_framework="$products/PackageFrameworks/QueryCraftMilvusDriver.framework"
shared_api_framework="$products/PackageFrameworks/QueryCraftFeature.framework"
output_root="${OUTPUT_ROOT:-$project_root/.build/driver-catalog}"
download_base_url="${QUERYCRAFT_DRIVER_DOWNLOAD_BASE_URL:-https://querycraft.debug-tools.cc/drivers}"
download_base_url="${download_base_url%/}"
bundle="$output_root/Milvus-$driver_arch.querycraftdriver"
macos="$bundle/Contents/MacOS"
info_plist="$bundle/Contents/Info.plist"
manifest="$output_root/milvus-$driver_arch.json"
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
    rm -rf "$output_root/Milvus-$driver_arch.querycraftdriver.previous"
}
trap cleanup EXIT

source_binary="$source_framework/Versions/A/QueryCraftMilvusDriver"
querycraft_validate_driver_package_inputs \
    "$source_framework" \
    "QueryCraftMilvusDriver" \
    "$shared_api_framework"

source_symbols="$(nm -u "$source_binary" | swift demangle)"
if [[ "$source_symbols" != *"protocol descriptor for QueryCraftFeature.WorkspaceRequestExecutingSession"* ]]; then
    print -u2 "Milvus framework is missing REST execution. Build the QueryCraftMilvusDriver scheme before packaging."
    exit 1
fi

mkdir -p "$output_root"
if [[ -e "$bundle" ]]; then
    mv "$bundle" "$output_root/Milvus-$driver_arch.querycraftdriver.previous"
fi
mkdir -p "$macos"
binary="$macos/QueryCraftMilvusDriver"
cp "$source_binary" "$binary"

target_architectures="$(lipo -archs "$binary")"
if [[ "$target_architectures" != "$driver_arch" ]]; then
    if [[ " $target_architectures " != *" $driver_arch "* ]]; then
        print -u2 "Missing $driver_arch slice: $binary"
        exit 1
    fi
    thin_temp="$(mktemp "$output_root/.milvus-thin-$driver_arch.XXXXXX")"
    lipo "$binary" -thin "$driver_arch" -output "$thin_temp"
    chmod "$(stat -f %Lp "$binary")" "$thin_temp"
    mv "$thin_temp" "$binary"
fi

/usr/libexec/PlistBuddy -c 'Clear dict' "$info_plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleDevelopmentRegion string en' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string QueryCraftMilvusDriver' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string io.github.future0923.QueryCraft.Driver.Milvus' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleInfoDictionaryVersion string 6.0' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Milvus Driver' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string BNDL' "$info_plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $driver_version" "$info_plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $driver_build" "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :NSPrincipalClass string QueryCraftMilvusDriverEntry' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :QCDriverDatabaseType string milvus' "$info_plist"
/usr/libexec/PlistBuddy -c "Add :QCDriverAPIVersion integer $querycraft_driver_api_version" "$info_plist"
/usr/libexec/PlistBuddy -c "Add :QCMinimumAppVersion string $querycraft_driver_minimum_app_version" "$info_plist"

querycraft_prepare_driver_rpaths "$binary" "$products/PackageFrameworks"
querycraft_strip_local_symbols "$binary"
querycraft_codesign "$signing_identity" "$binary"
querycraft_codesign "$signing_identity" "$bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"

archive_temp="$(mktemp "$output_root/.milvus-driver-$driver_version-$driver_arch.XXXXXX")"
ditto -c -k --keepParent "$bundle" "$archive_temp"
querycraft_notarize_driver_archive "$archive_temp"
sha256="$(shasum -a 256 "$archive_temp" | cut -d ' ' -f 1)"
size="$(stat -f %z "$archive_temp")"
archive_name="milvus-driver-$driver_version-$driver_arch-${sha256[1,16]}.zip"
archive="$output_root/$archive_name"
if [[ -e "$archive" ]]; then
    rm -f "$archive_temp"
else
    mv "$archive_temp" "$archive"
fi
archive_temp=""
architectures="[\"$driver_arch\"]"

manifest_temp="$(mktemp "$output_root/.milvus-$driver_arch.json.XXXXXX")"
sed \
    -e "s|__VERSION__|$driver_version|g" \
    -e "s|__BUILD__|$driver_build|g" \
    -e "s|__SHA256__|$sha256|g" \
    -e "s|__SIZE__|$size|g" \
    -e "s|__DRIVER_API_VERSION__|$querycraft_driver_api_version|g" \
    -e "s|__MINIMUM_APP_VERSION__|$querycraft_driver_minimum_app_version|g" \
    -e "s|__ARCHITECTURES__|$architectures|g" \
    -e "s|__DOWNLOAD_BASE_URL__|$download_base_url|g" \
    -e "s|__ARCHIVE_NAME__|$archive_name|g" \
    "$project_root/scripts/milvus-driver-manifest.json.in" > "$manifest_temp"
querycraft_validate_driver_package_metadata \
    "$info_plist" "$manifest_temp" milvus \
    "$driver_version" "$driver_build" "$driver_arch"
mv "$manifest_temp" "$manifest"
manifest_temp=""

for stale_archive in "$output_root"/milvus-driver-*.zip(N); do
    keep_archive=0
    for current_manifest in \
        "$output_root/milvus-x86_64.json" \
        "$output_root/milvus-arm64.json"
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
rm -f "$output_root/milvus.json"
rm -rf "$output_root/Milvus.querycraftdriver"
for stale_bundle in "$output_root"/Milvus*.querycraftdriver\ *(N); do
    rm -rf "$stale_bundle"
done
rm -f "$output_root/.DS_Store"

print "Driver bundle: $bundle"
print "Archive: $archive"
print "Manifest: $manifest"
