#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
catalog_root="${OUTPUT_ROOT:-$project_root/.build/driver-catalog}"
catalog_port="${QUERYCRAFT_DRIVER_CATALOG_PORT:-8788}"

if [[ ! -d "$catalog_root" ]]; then
    echo "Driver catalog not found: $catalog_root" >&2
    echo "Run scripts/build-local-drivers.sh first." >&2
    exit 66
fi

echo "Serving QueryCraft drivers at http://127.0.0.1:$catalog_port/"
echo "Launch QueryCraft with QUERYCRAFT_DRIVER_CATALOG_BASE_URL=http://127.0.0.1:$catalog_port/"
exec /usr/bin/python3 -m http.server "$catalog_port" \
    --bind 127.0.0.1 \
    --directory "$catalog_root"
