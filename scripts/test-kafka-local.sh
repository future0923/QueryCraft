#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
task_dir="$(mktemp -d "${TMPDIR:-/tmp}/querycraft-kafka-tests.XXXXXX")"
broker_pid=""
cleanup() {
    if [[ -n "$broker_pid" ]]; then
        kill "$broker_pid" 2>/dev/null || true
        wait "$broker_pid" 2>/dev/null || true
    fi
    rm -rf "$task_dir"
}
trap cleanup EXIT

# pkg-config emits compiler/linker flags, intentionally split into arguments.
cc "$project_root/QueryCraftDrivers/Tests/Fixtures/kafka-mock-broker.c" \
    $(pkg-config --cflags --libs rdkafka) -o "$task_dir/broker"
"$task_dir/broker" "$task_dir/bootstrap" >"$task_dir/broker.log" 2>&1 &
broker_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ -s "$task_dir/bootstrap" ]] && break
    kill -0 "$broker_pid" 2>/dev/null || { cat "$task_dir/broker.log"; exit 1; }
    sleep 0.1
done
[[ -s "$task_dir/bootstrap" ]] || { cat "$task_dir/broker.log"; exit 1; }

python3 - "$project_root" "$task_dir" <<'PY'
import json, os, pathlib, sys
root, temporary = map(pathlib.Path, sys.argv[1:])
args = {
    "workspacePath": str(root / "QueryCraft.xcworkspace"),
    "scheme": "QueryCraftKafkaDriverTests",
    "configuration": "Debug",
    "derivedDataPath": str(root / ".build/DerivedData"),
    "testRunnerEnv": {"QUERYCRAFT_KAFKA_FIXTURE": (temporary / "bootstrap").read_text()},
}
for key in ["QUERYCRAFT_KAFKA_GROUP_SMOKE", "QUERYCRAFT_KAFKA_GROUP_SMOKE_TOPIC", "QUERYCRAFT_KAFKA_GROUP_SMOKE_GROUP"]:
    if value := os.environ.get(key):
        args["testRunnerEnv"][key] = value
(temporary / "arguments.json").write_text(json.dumps(args))
PY
"${XCODEBUILDMCP_BIN:-/usr/local/bin/xcodebuildmcp}" macos test \
    --json "$(cat "$task_dir/arguments.json")"
