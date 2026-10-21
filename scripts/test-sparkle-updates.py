#!/usr/bin/env python3
"""Run the bundled Sparkle selector headlessly for Intel, ARM and native hardware."""
import argparse
import base64
import functools
import hashlib
import http.server
import importlib.util
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sparkle-directory', type=Path, required=True)
    args = parser.parse_args()
    frameworks = args.sparkle_directory.resolve() / 'Sparkle.xcframework/macos-arm64_x86_64'
    spec = importlib.util.spec_from_file_location('updates', ROOT / 'scripts/update-archives.py')
    updates = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(updates)
    with tempfile.TemporaryDirectory(prefix='querycraft-sparkle-fixture-') as temporary:
        directory = Path(temporary)
        executable = directory / 'selection'
        subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-Wno-protocol', '-mmacosx-version-min=15.0',
                        '-framework', 'Foundation', '-F', str(frameworks), '-framework', 'Sparkle',
                        '-Wl,-rpath,' + str(frameworks), str(ROOT / 'scripts/test-sparkle-update-selection.m'),
                        '-o', str(executable)], check=True)
        host = directory / 'Host.app/Contents'
        host.mkdir(parents=True)
        (host / 'Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='io.github.future0923.QueryCraft.SizeFixture.' + directory.name,
            CFBundleName='SizeFixture', CFBundleVersion='21', CFBundleShortVersionString='0.1.11',
            CFBundlePackageType='APPL', SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
            SUPublicEDKey=plistlib.loads((ROOT / 'QueryCraft/Info.plist').read_bytes())['SUPublicEDKey'])))
        notes = directory / 'notes.md'
        notes.write_text('中文 / English')
        for arch in updates.ARCHITECTURES:
            archive = directory / f'QueryCraft-0.2.0-{arch}.tar.xz'
            archive.write_bytes(b'fixture')
            (directory / f'update-{arch}.json').write_text(json.dumps(dict(
                schemaVersion=2, version='0.2.0', build='30', minimumSystemVersion='15.0',
                architecture=arch, archive=archive.name, length=archive.stat().st_size,
                sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                edSignature=base64.b64encode(bytes(64)).decode())))
        updates.assemble(directory, '0.2.0', notes, 'https://querycraft.test')

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args): pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=temporary))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        translated = subprocess.run(['/usr/sbin/sysctl', '-in', 'sysctl.proc_translated'], capture_output=True, text=True)
        native = 'arm64' if platform.machine() == 'arm64' or translated.stdout.strip() == '1' else 'x86_64'
        try:
            for hardware, expected in [('native', native), ('x86_64', 'x86_64'), ('arm64', 'arm64')]:
                subprocess.run([str(executable), str(host.parent),
                    f'http://127.0.0.1:{server.server_port}/appcast.xml', hardware, expected], check=True, timeout=25)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__': main()
