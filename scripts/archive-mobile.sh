#!/bin/bash
# Archive/export only. Upload to TestFlight is an explicit subsequent action.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$project_root/.build/mobile-distribution}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
archive="$output/QueryCraft.xcarchive"
derived_data="${IOS_DERIVED_DATA:-$output/DerivedData}"
if [[ -e "$archive" || -e "$output/export" ]]; then
    echo "Choose a new output directory; existing archives/exports are never overwritten." >&2
    exit 65
fi
command -v xcodegen >/dev/null
command -v xcodebuildmcp >/dev/null
bash "$project_root/scripts/build-ios-mariadb.sh" iphoneos arm64
bash "$project_root/scripts/build-ios-libpq.sh" iphoneos arm64
xcodegen generate --spec "$project_root/QueryCraftMobile/project.yml"
resolution="$project_root/QueryCraftMobile/QueryCraftMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolution"
cp "$project_root/QueryCraftMobile/Package.resolved" "$resolution/Package.resolved"
# XcodeBuildMCP has no archive/export command. Use Xcode's distribution commands
# for these two operations; ordinary device builds still use XcodeBuildMCP.
xcodebuild archive -project "$project_root/QueryCraftMobile/QueryCraftMobile.xcodeproj" \
    -scheme QueryCraftMobileProof -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$archive" -derivedDataPath "$derived_data" -allowProvisioningUpdates \
    -disableAutomaticPackageResolution -skipPackageUpdates
xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "$project_root/QueryCraftMobile/ExportOptions-TestFlight.plist" \
    -exportPath "$output/export" -allowProvisioningUpdates
echo "Archive and IPA exported to $output. No TestFlight upload performed."
