#!/bin/bash
# Archive and export a Mac App Store candidate. Never uploads or publishes.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${QC_STORE_COMPONENTS_DIR:?Set QC_STORE_COMPONENTS_DIR to reviewed universal components}"
output="${1:-$project_root/.build/mac-store-distribution}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
archive="$output/QueryCraft.xcarchive"
derived_data="${QC_STORE_DERIVED_DATA:-$output/DerivedData}"
if [[ -e "$archive" || -e "$output/export" ]]; then
    echo 'Use a new output directory; existing archives/exports are never overwritten.' >&2
    exit 65
fi
command -v xcodebuildmcp >/dev/null
bash "$project_root/scripts/generate-store-project.sh"
# The CLI has no archive/export operation. Ordinary builds/tests use XcodeBuildMCP.
xcodebuild archive -project "$project_root/QueryCraftStore/QueryCraftStore.xcodeproj" \
    -scheme QueryCraftStore -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$archive" -derivedDataPath "$derived_data" -allowProvisioningUpdates \
    -disableAutomaticPackageResolution -skipPackageUpdates \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO DEVELOPMENT_TEAM=5975A7N3W3 \
    "QC_STORE_COMPONENTS_DIR=$QC_STORE_COMPONENTS_DIR"
xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "$project_root/QueryCraftStore/ExportOptions.plist" \
    -exportPath "$output/export" -allowProvisioningUpdates
python3 - "$project_root" "$output" <<'PY'
import subprocess, sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
packages = list((output / 'export').glob('*.pkg'))
if len(packages) != 1:
    raise SystemExit('Expected one exported App Store installer')
subprocess.run(['pkgutil', '--check-signature', str(packages[0])], check=True)
expanded = output / 'expanded-for-validation'
subprocess.run(['pkgutil', '--expand-full', str(packages[0]), str(expanded)], check=True)
apps = list(expanded.rglob('QueryCraft.app'))
if len(apps) != 1:
    raise SystemExit('Expected one exported QueryCraft app')
subprocess.run(['python3', str(root / 'scripts/check-store-app.py'), str(apps[0])], check=True)
PY
echo "Export validated at $output. No upload or App Review submission performed."
