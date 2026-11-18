#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
command -v xcodegen >/dev/null || { echo 'Install XcodeGen before generating the Store project.' >&2; exit 1; }
xcodegen generate --spec "$root/QueryCraftStore/project.yml"
lock_dir="$root/QueryCraftStore/QueryCraftStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$lock_dir"
cp "$root/QueryCraftStore/Package.resolved" "$lock_dir/Package.resolved"
