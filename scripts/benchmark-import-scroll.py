#!/usr/bin/env python3
"""Guarded native scrolling benchmark. Escape or the five-minute watchdog restores input.

Displays only synthetic fixtures above a screen mask. No user databases are opened.
Measures native scrollWheel handling and drawing, not physical trackpad/display-link FPS.
"""
from pathlib import Path
import os
import platform
import signal
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
output = root / '.build/validation/import-scroll'
output.mkdir(parents=True, exist_ok=True)
developer = Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
compiler = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
sdk = developer / 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
dd = root / '.build/DerivedData'
products = dd / 'Build/Products/Debug'
frameworks = products / 'PackageFrameworks'
binary = root / '.build/benchmark-import-scroll'
command = [str(compiler),'-parse-as-library','-target',platform.machine()+'-apple-macosx15.0','-sdk',str(sdk),
           str(root/'scripts/benchmark-import-scroll.swift'),'-I',str(products),'-F',str(frameworks),
           '-framework','QueryCraftFeature','-o',str(binary),'-Xlinker','-rpath','-Xlinker',str(frameworks)]
for name in ['TreeSitterJSON','TreeSitterSQL','TreeSitter','Internal']:
    command += ['-Xcc','-fmodule-map-file='+str(dd/f'Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap')]
command += ['-Xcc','-fmodule-map-file='+str(dd/'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
for path in [root/'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include',root/'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include',
             dd/'SourcePackages/checkouts/tree-sitter/lib/include',dd/'SourcePackages/checkouts/TextStory/Sources/Internal',
             root/'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
    command += ['-Xcc','-I'+str(path)]
subprocess.run(command,check=True)
shield_binary = root/'.build/ui-isolation/querycraft-shield'
if not shield_binary.exists():
    shield_binary.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run([str(compiler),'-target',platform.machine()+'-apple-macosx15.0','-sdk',str(sdk),str(root/'scripts/ui-test-shield.swift'),'-o',str(shield_binary)],check=True)
run = Path(tempfile.mkdtemp(prefix='querycraft-scroll-isolation-'))
shield = None
process = None
try:
    with (run/'shield.log').open('w') as log:
        shield = subprocess.Popen([str(shield_binary),str(run)],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    deadline = time.monotonic()+10
    while not (run/'shield.ready').exists():
        if shield.poll() is not None or time.monotonic()>deadline:
            raise RuntimeError('Reliable input/screen isolation did not start; no UI input was simulated. '+str(run))
        time.sleep(.1)
    print('Screen/input isolation verified. Escape exits immediately.',flush=True)
    with (output/'harness.log').open('w') as log:
        process = subprocess.Popen([str(binary),str(run),str(output)],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    while process.poll() is None:
        if shield.poll() is not None or not (run/'shield.ready').exists():
            raise RuntimeError('Isolation ended; stopping the benchmark')
        request = run/'capture-request'
        if request.exists():
            lines = request.read_text().splitlines(); request.unlink()
            subprocess.run(['/usr/sbin/screencapture','-x','-l',lines[0],lines[1]],timeout=5,check=False)
        time.sleep(.1)
    if process.returncode: raise RuntimeError('Scrolling harness failed; see '+str(output/'harness.log'))
    import json
    report = json.loads((output/'scroll.json').read_text())
    if report.get('error'): raise RuntimeError(report['error'])
    print(json.dumps(report,ensure_ascii=False),flush=True)
finally:
    if process is not None and process.poll() is None:
        os.killpg(process.pid,signal.SIGTERM)
    (run/'stop').touch()
    if shield is not None:
        try: shield.wait(timeout=3)
        except subprocess.TimeoutExpired: shield.terminate()
    print('Screen/input isolation removed.',flush=True)
