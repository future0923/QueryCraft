#!/usr/bin/env python3
"""Capture synthetic native transfer windows behind verified desktop/input isolation.

Escape immediately restores user control and stops the test process. The shield
also has a five-minute watchdog; no physical mouse or keyboard input is used.
Run once after the relevant test targets have been built.
"""
from pathlib import Path
import json
import os
import signal
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
shield_binary = root / '.build/ui-isolation/querycraft-shield'
if not shield_binary.exists():
    raise SystemExit('Build the repository ui-test-shield.swift helper first; no desktop interaction started.')
run = Path(tempfile.mkdtemp(prefix='querycraft-transfer-ui-'))
shield = None
process = None
try:
    with (run / 'shield.log').open('w') as log:
        shield = subprocess.Popen([str(shield_binary), str(run)], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + 10
    while not (run / 'shield.ready').exists():
        if shield.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Reliable desktop isolation was not enabled. No UI input started. ' + str(run))
        time.sleep(0.1)
    print('Verified desktop isolation; Escape exits immediately.', flush=True)
    args = dict(workspacePath=str(root / 'QueryCraft.xcworkspace'), scheme='QueryCraft', configuration='Debug',
                derivedDataPath=str(root / '.build/DerivedData'),
                extraArgs=['-disableAutomaticPackageResolution', '-skipPackageUpdates', '-parallel-testing-enabled', 'NO',
                           '-only-testing:QueryCraftFeatureTests/DataTransferPresentationTests'],
                testRunnerEnv={'QUERYCRAFT_UI_VISUAL_QA_DIR': str(run)})
    with (run / 'test.log').open('w') as log:
        process = subprocess.Popen(['xcodebuildmcp', 'macos', 'test', '--json', json.dumps(args)],
                                   cwd=root, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    captures = 0
    while process.poll() is None:
        if shield.poll() is not None or not (run / 'shield.ready').exists():
            raise RuntimeError('Isolation ended; stopping the UI tests.')
        request = run / 'capture-request'
        if request.exists():
            values = request.read_text().splitlines(); request.unlink()
            result = subprocess.run(['/usr/sbin/screencapture', '-x', '-l', values[0], values[1]], timeout=5)
            if result.returncode == 0:
                captures += 1
            (run / 'capture-done').write_text(str(result.returncode))
        time.sleep(0.1)
    if process.returncode:
        raise RuntimeError('UI verification failed; inspect ' + str(run / 'test.log'))
    if captures != 4:
        raise RuntimeError('Expected four actual native screenshots; received ' + str(captures) + '. Inspect ' + str(run / 'test.log'))
    print('UI verification passed; logs: ' + str(run), flush=True)
finally:
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
    (run / 'stop').touch()
    if shield is not None:
        try:
            shield.wait(timeout=3)
        except subprocess.TimeoutExpired:
            shield.terminate()
    print('Desktop isolation removed.', flush=True)
