#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${DERIVED_DATA:-$project_root/.build/DerivedData}"
products="$derived_data/Build/Products/${CONFIGURATION:-Debug}"
plugin="${1:?Usage: bash scripts/verify-kafka-driver.sh /path/to/Kafka.querycraftdriver}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/querycraft-verify-kafka.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
module_arguments=()
for module_map in "$derived_data/Build/Intermediates.noindex/GeneratedModuleMaps/"*.modulemap; do
    module_arguments+=(-Xcc "-fmodule-map-file=$module_map")
done
swiftc -parse-as-library "$project_root/scripts/verify-kafka-driver.swift" \
    -I "$products" \
    -I "$derived_data/SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite" \
    -I "$project_root/ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include" \
    "${module_arguments[@]}" \
    -F "$products/PackageFrameworks" -framework QueryCraftFeature \
    -Xlinker -rpath -Xlinker "${FRAMEWORKS_DIRECTORY:-$products/PackageFrameworks}" \
    -o "$temporary/verify-kafka-driver"
"$temporary/verify-kafka-driver" "$plugin"
