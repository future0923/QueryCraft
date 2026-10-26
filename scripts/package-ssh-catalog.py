#!/usr/bin/env python3
"""Prepare signed immutable SSH component records and architecture catalogs; no upload."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import struct
from urllib.parse import urlparse
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ARCHITECTURES = ('x86_64', 'arm64')


def inspect_package(source, arch, metadata):
    """Validate the signed bundle's descriptor, identity and actual native CPU slice."""
    root = 'QueryCraftSSH.bundle/'
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        if len(entries) > 256 or len({e.filename for e in entries}) != len(entries):
            raise ValueError('Invalid SSH ZIP entry count or duplicate paths')
        if sum(e.file_size for e in entries) > 128 * 1024 * 1024:
            raise ValueError('SSH package exceeds the expanded size limit')
        for entry in entries:
            if not entry.filename.startswith(root) or '..' in entry.filename.split('/') or '\\' in entry.filename:
                raise ValueError('SSH ZIP contains an escaping path')
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError('SSH ZIP must not contain symbolic links')
        info = plistlib.loads(archive.read(root + 'Contents/Info.plist'))
        build = json.loads(archive.read(root + 'Contents/Resources/build.json'))
        descriptor = json.loads(archive.read(root + 'Contents/Resources/component.json'))
        expected = dict(metadata, component='ssh', architectures=[arch])
        if descriptor != expected:
            raise ValueError('SSH package compatibility differs from Components/versions.json')
        if (info['CFBundleIdentifier'] != 'io.github.future0923.QueryCraft.SSH'
                or info['QCSSHPluginABIVersion'] != 1 or build['abi'] != 1
                or build['architecture'] != arch or build['local_crypto_override']
                or (info['CFBundleShortVersionString'], info['CFBundleVersion']) != (metadata['version'], metadata['build'])):
            raise ValueError('SSH package identity/ABI differs or uses development crypto')
        with archive.open(root + 'Contents/MacOS/QueryCraftSSH') as binary:
            magic, cpu = struct.unpack('<II', binary.read(8))
        if magic != 0xfeedfacf or cpu != {'x86_64': 0x01000007, 'arm64': 0x0100000c}[arch]:
            raise ValueError('SSH package must contain exactly the requested native architecture')
        # SSH 0.9+ carries its optional local UI as nested signed code. Validate
        # it without loading AppKit/Swift or executing an untrusted binary.
        if tuple(map(int, metadata['version'].split('.'))) >= (0, 9, 0):
            renderer = root + 'Contents/PlugIns/TerminalRenderer.bundle/'
            ui = plistlib.loads(archive.read(renderer + 'Contents/Info.plist'))
            if (info.get('QCSSHTerminalRendererABIVersion') != 1
                    or build.get('terminal_renderer_abi') != 1 or build.get('swiftterm') != '1.10.1'
                    or ui.get('CFBundleIdentifier') != 'io.github.future0923.QueryCraft.SSH.TerminalRenderer'
                    or ui.get('CFBundleExecutable') != 'QueryCraftSSHTerminalRenderer'
                    or ui.get('QCSSHTerminalRendererABIVersion') != 1 or ui.get('QCSwiftTermVersion') != '1.10.1'
                    or (ui.get('CFBundleShortVersionString'), ui.get('CFBundleVersion')) != (metadata['version'], metadata['build'])):
                raise ValueError('SSH terminal renderer identity/ABI/version differs')
            with archive.open(renderer + 'Contents/MacOS/QueryCraftSSHTerminalRenderer') as binary:
                ui_magic, ui_cpu = struct.unpack('<II', binary.read(8))
            if ui_magic != magic or ui_cpu != cpu:
                raise ValueError('SSH terminal renderer has a different native architecture')
            for name in ['Contents/_CodeSignature/CodeResources', 'Contents/Resources/SwiftTerm-LICENSE.txt']:
                if not archive.getinfo(renderer + name).file_size:
                    raise ValueError('SSH terminal renderer signature or license is missing')
        for name in ['Contents/_CodeSignature/CodeResources', 'Contents/Resources/Licenses/libssh2.txt',
                     'Contents/Resources/Licenses/OpenSSL.txt']:
            if not archive.getinfo(root + name).file_size:
                raise ValueError('SSH signature or license is missing')
    return descriptor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--arch', choices=ARCHITECTURES, help='CI native job; omit to require both architectures')
    parser.add_argument('--key-file', type=Path)
    parser.add_argument('--sign-tool', type=Path)
    parser.add_argument('--minimum-app-version', help='Compatibility assertion; version source is Components/versions.json')
    parser.add_argument('--allow-local-http', action='store_true')
    args = parser.parse_args()
    url = urlparse(args.base_url)
    if url.username or url.password or url.query or url.fragment or not url.hostname:
        parser.error('Use a distribution origin without credentials, query or fragment')
    if url.scheme != 'https' and not (args.allow_local_http and url.scheme == 'http' and url.hostname in ('localhost', '127.0.0.1', '::1')):
        parser.error('Distribution requires HTTPS; loopback HTTP needs explicit development opt-in')
    metadata = json.loads((ROOT / 'Components/versions.json').read_text())['ssh']
    if args.minimum_app_version and args.minimum_app_version != metadata['minimumAppVersion']:
        parser.error('Minimum app version differs from Components/versions.json')
    architectures = [args.arch] if args.arch else ARCHITECTURES
    prepared = []
    # Validate every selected input before writing any output.
    for arch in architectures:
        source = args.packages / f'QueryCraftSSH-{arch}.zip'
        descriptor = inspect_package(source, arch, metadata)
        name = f"querycraft-ssh-{metadata['version']}-{metadata['build']}-{arch}.zip"
        target = args.output / name
        if target.exists() and target.read_bytes() != source.read_bytes():
            raise ValueError('Refusing to replace an immutable SSH package')
        prepared.append((arch, source, target, descriptor))
    args.output.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('components', ROOT / 'scripts/package-components.py')
    components = importlib.util.module_from_spec(spec); spec.loader.exec_module(components)
    tool = args.sign_tool or ROOT / '.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update'
    for arch, source, target, descriptor in prepared:
        shutil.copyfile(source, target)
        release = dict(descriptor, sha256=hashlib.sha256(target.read_bytes()).hexdigest(),
                       size=target.stat().st_size, url=args.base_url.rstrip('/') + '/' + target.name)
        package = target.with_suffix('.package.json')
        encoded = json.dumps(release, indent=2) + '\n'
        if package.exists() and package.read_text() != encoded:
            raise ValueError('Refusing to replace immutable SSH release metadata')
        package.write_text(encoded)
        envelope = components.sign(package, tool, args.key_file)
        catalog = args.output / f'ssh-{arch}.json'
        catalog.write_text(json.dumps(dict(schemaVersion=1, component='ssh', releases=[json.loads(envelope.read_text())]), indent=2) + '\n')
        print(catalog)


if __name__ == '__main__':
    main()
