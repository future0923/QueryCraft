#!/usr/bin/env python3
"""Run core tests with AppKit suites isolated in separate test processes.

The UI suites exercise native hosting without desktop pointer/keyboard events.
Isolation prevents shared NSApplication/WindowServer state from leaking between
otherwise unrelated suites. No tests are disabled or changed to expected failures.
"""
from pathlib import Path
import json
import os
import re
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = Path(__file__).resolve().parent.parent
DD = Path(os.environ.get('DERIVED_DATA', ROOT / 'output/schema-comparison-build')).resolve()
OUT = DD / 'regression/core-isolated'
OUT.mkdir(parents=True, exist_ok=True)
# These suites own an AppKit hosting hierarchy, an actual window controller, or
# the recovery/presentation path that creates one indirectly.
ui_suites = set()
for path in (ROOT / 'QueryCraftPackage/Tests/QueryCraftFeatureTests').glob('*Tests.swift'):
    source = path.read_text()
    if re.search(r'import (?:AppKit|SwiftUI|CodeEdit)|NSWindow\(|NSHostingView\(|WorkspaceWindowController|WorkspaceWindowManager|WorkspaceWindowFactory', source):
        # A few historical files contain differently named/multiple suites.
        ui_suites.update(re.findall(r'(?:struct|class|enum)\s+(\w+Tests)\b', source))
ui_suites = sorted(ui_suites)
summary = []
summary_lock = threading.Lock()

def run(label, selection):
    args = {'workspacePath': str(ROOT / 'QueryCraft.xcworkspace'), 'scheme': 'QueryCraft',
        'configuration': 'Debug', 'derivedDataPath': str(DD),
        'testRunnerEnv': {'SWIFT_BACKTRACE': 'enable=no'},
        'extraArgs': ['CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM=',
                      '-parallel-testing-enabled', 'NO', *selection]}
    log_path = OUT / (label + '.log')
    with log_path.open('w') as log:
        result = subprocess.run(['/usr/local/bin/xcodebuildmcp', 'macos', 'test', '--json', json.dumps(args)],
                                stdout=log, stderr=subprocess.STDOUT, timeout=600)
    text = log_path.read_text()
    counts = re.search(r'(\d+) tests? passed, (\d+) failed, (\d+) skipped', text)
    item = dict(suite=label, passed=int(counts[1]) if counts else None,
                failed=int(counts[2]) if counts else None, skipped=int(counts[3]) if counts else None,
                exit_code=result.returncode, log=str(log_path))
    with summary_lock:
        summary.append(item)
        (OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(item), flush=True)
    if result.returncode or not counts or int(counts[2]):
        raise RuntimeError(f'{label} failed; inspect {log_path}')

run('core', ['-only-testing:QueryCraftFeatureTests',
             *(f'-skip-testing:QueryCraftFeatureTests/{suite}' for suite in ui_suites)])
with ThreadPoolExecutor(max_workers=int(os.environ.get('QC_CORE_WORKERS', '2'))) as executor:
    futures = [executor.submit(run, suite, [f'-only-testing:QueryCraftFeatureTests/{suite}']) for suite in ui_suites]
    for future in as_completed(futures):
        future.result()
print('PASS all core and isolated native suites: ' + str(sum(item['passed'] for item in summary)) + ' passed', flush=True)
