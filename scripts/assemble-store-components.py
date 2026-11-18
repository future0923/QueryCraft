#!/usr/bin/env python3
"""Assemble universal Store-only copies from two trusted release component sets.

Never changes the downloaded source bundles or publishes independent components.
Both slices must have identical release identity and non-architecture resources.
"""
import argparse
import importlib.util
import plistlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('embed', Path(__file__).with_name('embed-store-components.py'))
embed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(embed)


def run(*args):
    try:
        return subprocess.check_output(list(map(str, args)), stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(error.output.decode(errors='replace')) from error


def entries(root):
    return {p.relative_to(root): p for p in root.rglob('*')
            if '_CodeSignature' not in p.parts and p.name != '.DS_Store' and (p.is_file() or p.is_symlink())}


def assemble(intel, arm, destination, identity):
    if destination.exists():
        raise ValueError('Destination already exists; use a new directory')
    def bundle_id(path):
        return plistlib.loads((path / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
    arm_drivers = {bundle_id(p): p for p in (arm / 'Drivers').glob('*.querycraftdriver')}
    bundles = [(p, arm_drivers[bundle_id(p)], Path('Drivers') / p.name.replace('-x86_64', ''))
               for p in (intel / 'Drivers').glob('*.querycraftdriver')]
    bundles.append((intel / 'QueryCraftSSH.bundle', arm / 'QueryCraftSSH.bundle', Path('QueryCraftSSH.bundle')))
    if len(bundles) != 8 or len(arm_drivers) != 7:
        raise ValueError('Expected seven drivers and SSH')
    for source_a, source_b, name in bundles:
        for source in [source_a, source_b]:
            run('codesign', '--verify', '--deep', '--strict', '-R', embed.TRUST, source)
        a = plistlib.loads((source_a / 'Contents/Info.plist').read_bytes())
        b = plistlib.loads((source_b / 'Contents/Info.plist').read_bytes())
        if a != b:
            raise ValueError('Component metadata differs between architectures: ' + str(name))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='store-universal-', dir=destination.parent) as temp:
        staged = Path(temp) / 'components'
        for source_a, source_b, name in bundles:
            output = staged / name
            shutil.copytree(source_a, output, symlinks=True)
            files_a, files_b = entries(source_a), entries(source_b)
            for relative in files_a.keys() | files_b.keys():
                a, b = files_a.get(relative), files_b.get(relative)
                result = output / relative
                if a is None or b is None:
                    # Different architectures may link different major versions
                    # of a dependency. Preserve that exact, signed input slice;
                    # never substitute ABI-incompatible libraries. The final app
                    # gate walks each architecture's actual load commands.
                    only = a or b
                    if only.suffix == '.dylib' and embed.is_macho(only):
                        if a is None:
                            result.parent.mkdir(parents=True, exist_ok=True)
                            shutil.copy2(b, result)
                        continue
                    # Compiler module metadata is legitimately slice-specific.
                    if not any(part.endswith('.swiftmodule') for part in relative.parts):
                        raise ValueError('Unexpected architecture-only resource: ' + str(name / relative))
                    if a is None:
                        result.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(b, result, follow_symlinks=False)
                    continue
                if a.is_symlink() or b.is_symlink():
                    if not (a.is_symlink() and b.is_symlink() and a.readlink() == b.readlink()):
                        raise ValueError('Mismatched resource link: ' + str(name / relative))
                elif embed.is_macho(a) and embed.is_macho(b):
                    slices = []
                    for binary, architecture in [(a, 'x86_64'), (b, 'arm64')]:
                        archs = run('lipo', '-archs', binary).decode().split()
                        if architecture not in archs:
                            raise ValueError('Missing architecture in ' + str(binary))
                        target = Path(temp) / (architecture + '.slice')
                        if len(archs) > 1:
                            run('lipo', binary, '-thin', architecture, '-output', target)
                        else:
                            shutil.copy2(binary, target)
                        slices.append(target)
                    run('lipo', '-create', *slices, '-output', result)
                elif a.read_bytes() != b.read_bytes():
                    if relative == Path('Contents/Resources/component.json'):
                        info_a, info_b = json.loads(a.read_bytes()), json.loads(b.read_bytes())
                        if info_a.pop('architectures', None) == ['x86_64'] and info_b.pop('architectures', None) == ['arm64'] and info_a == info_b:
                            info_a['architectures'] = ['arm64', 'x86_64']
                            result.write_text(json.dumps(info_a, indent=2) + '\n')
                            continue
                    if relative == Path('Contents/Resources/build.json'):
                        info_a, info_b = json.loads(a.read_bytes()), json.loads(b.read_bytes())
                        if info_a.pop('architecture', None) == 'x86_64' and info_b.pop('architecture', None) == 'arm64' and info_a == info_b:
                            info_a['architecture'] = 'universal'
                            result.write_text(json.dumps(info_a, indent=2) + '\n')
                            continue
                    if relative.name == 'Info.plist':
                        info_a, info_b = plistlib.loads(a.read_bytes()), plistlib.loads(b.read_bytes())
                        # Intel and ARM releases were built on different Macs;
                        # this provenance field has no runtime semantics.
                        info_a.pop('BuildMachineOSBuild', None)
                        info_b.pop('BuildMachineOSBuild', None)
                        if info_a == info_b:
                            result.write_bytes(plistlib.dumps(info_a))
                            continue
                    raise ValueError('Non-code resources differ: ' + str(name / relative))
            code = [p for p in output.rglob('*') if not p.is_symlink() and
                    p.suffix in {'.dylib', '.so', '.framework', '.bundle'}]
            for item in sorted(code, key=lambda p: len(p.parts), reverse=True) + [output]:
                run('codesign', '--force', '--sign', identity, '--timestamp=none', item)
            run('codesign', '--verify', '--deep', '--strict', '-R', embed.TRUST, output)
        shutil.move(staged, destination)
    print('Assembled universal Store component copies: ' + str(destination))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('intel', type=Path)
    parser.add_argument('arm', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--identity', required=True, help='An installed Apple signing identity in the same team')
    args = parser.parse_args()
    assemble(args.intel.resolve(), args.arm.resolve(), args.destination.resolve(), args.identity)
