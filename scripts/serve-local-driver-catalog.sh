#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
catalog_root="${OUTPUT_ROOT:-$project_root/.build/driver-catalog}"
catalog_port="${QUERYCRAFT_DRIVER_CATALOG_PORT:-8788}"
served_root="$catalog_root/.served-catalog"

if [[ ! -d "$catalog_root" ]]; then
    echo "Driver catalog not found: $catalog_root" >&2
    echo "Run scripts/build-local-drivers.sh first." >&2
    exit 66
fi

rm -rf "$served_root"
mkdir -p "$served_root"

# Package scripts emit a single-release manifest for deployment. The client
# consumes the schema-v2 catalog published by the resource service, so wrap
# each local release manifest before serving it.
shopt -s nullglob
manifests=("$catalog_root"/*-x86_64.json "$catalog_root"/*-arm64.json)
if [[ "${#manifests[@]}" -eq 0 ]]; then
    echo "No driver manifests found: $catalog_root" >&2
    exit 66
fi
for manifest in "${manifests[@]}"; do
    database_type="$(jq -er '.databaseType' "$manifest")"
    architecture="$(jq -er '.supportedArchitectures[0]' "$manifest")"
    jq -e \
        --arg database_type "$database_type" \
        --arg architecture "$architecture" \
        '.databaseType == $database_type and
         (.supportedArchitectures | length == 1) and
         .supportedArchitectures[0] == $architecture' \
        "$manifest" >/dev/null
    jq \
        --arg database_type "$database_type" \
        --arg architecture "$architecture" \
        '{schemaVersion: 2,
          databaseType: $database_type,
          architecture: $architecture,
          releases: [.]}' \
        "$manifest" > "$served_root/$(basename "$manifest")"
done
for archive in "$catalog_root"/*.zip; do
    [[ -f "$archive" ]] || continue
    cp "$archive" "$served_root/$(basename "$archive")"
done

echo "Serving QueryCraft drivers at http://127.0.0.1:$catalog_port/"
echo "Launch QueryCraft with QUERYCRAFT_DRIVER_CATALOG_BASE_URL=http://127.0.0.1:$catalog_port/"
exec /usr/bin/python3 -m http.server "$catalog_port" \
    --bind 127.0.0.1 \
    --directory "$served_root"
