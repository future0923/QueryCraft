#!/usr/bin/env python3
"""Package the independent MCP runtime. The host application never embeds it.

Requires a completed Xcode QueryCraft app build. Does not publish or install anything.
The payload includes SwiftPM resources, private libraries and a separately versioned
credential helper. Original desktop credential-helper v1 is never modified.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def run(*args):
    return subprocess.check_output(list(map(str, args)), stderr=subprocess.STDOUT)

def package(build, output, development=False, archive_enabled=True, architecture=None):
    source_app = build / 'QueryCraft.app'
    source_framework = source_app / 'Contents/Frameworks/QueryCraftFeature.framework'
    if not source_framework.exists():
        raise RuntimeError('Build the QueryCraft scheme with xcodebuildmcp first; --build-dir is its Products/Debug or Products/Release directory.')
    if output.exists():
        raise RuntimeError('Output already exists; choose a new staging path.')
    macos = output / 'Contents/MacOS'
    frameworks = output / 'Contents/Frameworks'
    resources = output / 'Contents/Resources'
    for directory in [macos, frameworks, resources]: directory.mkdir(parents=True, exist_ok=True)
    # Exactly one dynamically linked Feature module must serve both MCP and drivers.
    # Linking the SwiftPM executable would embed a second, static copy of that module.
    for source in (source_app / 'Contents/Frameworks').iterdir():
        if source.is_dir(): shutil.copytree(source, frameworks / source.name, symlinks=True)
        else: shutil.copy2(source, frameworks / source.name)
    for source in build.glob('*.bundle'):
        shutil.copytree(source, resources / source.name, symlinks=True)
    for source in build.glob('*.dylib'):
        shutil.copy2(source, frameworks / source.name)
    notices = resources / 'ThirdPartyLicenses'
    shutil.copytree(ROOT / 'ThirdPartyLicenses', notices)
    shutil.copy2(ROOT / 'THIRD_PARTY_NOTICES.md', resources)
    executable = macos / 'querycraft-mcp'
    available_archs = run('lipo', '-archs', source_framework / 'QueryCraftFeature').decode().split()
    import platform
    archs = [architecture or platform.machine()]
    if not set(archs) <= set(available_archs): raise RuntimeError('Build does not support the requested MCP architecture.')
    with tempfile.TemporaryDirectory(prefix='querycraft-mcp-launcher-') as temporary:
        launcher = Path(temporary) / 'main.c'
        launcher.write_text('extern void QueryCraftMCPRun(int argc, char **argv);\nint main(int argc, char **argv) { QueryCraftMCPRun(argc, argv); return 0; }\n')
        binaries = []
        for arch in archs:
            binary = Path(temporary) / arch
            run('clang', '-target', arch+'-apple-macosx15.0', launcher, '-F', frameworks,
                '-framework', 'QueryCraftFeature', '-Wl,-rpath,@executable_path/../Frameworks', '-o', binary)
            binaries.append(binary)
        run('lipo', '-create', *binaries, '-output', executable)
    processed = {executable, frameworks / 'QueryCraftFeature.framework/Versions/A/QueryCraftFeature'}
    # Keep upstream framework signatures intact. Only our framework/launcher are edited.
    for binary in processed:
        lines = run('otool', '-l', binary).decode().splitlines()
        for i, line in enumerate(lines):
            if line.strip() == 'cmd LC_RPATH':
                value = lines[i + 2].strip().split('path ', 1)[1].split(' (offset')[0]
                if value.startswith('/') and not value.startswith(('/usr/lib/', '/System/')):
                    run('install_name_tool', '-delete_rpath', value, binary)
        for line in run('otool', '-L', binary).decode().splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            if dependency.startswith(('/System/', '/usr/lib/', '@loader_path/', '@executable_path/')): continue
            if dependency.startswith('@rpath/'):
                relative = dependency[len('@rpath/'):]
                # Compatibility libraries may be supplied by the OS dyld shared cache.
                if relative.startswith('libswiftCompatibility'): continue
                if (frameworks / relative).exists(): continue
            raise RuntimeError(f'Unresolved or nonportable dependency: {dependency}')
    metadata = json.loads((ROOT/'Components/versions.json').read_text())['mcp']
    version = metadata['version']
    app_version = next(line.split('=',1)[1].strip() for line in (ROOT/'Config/Shared.xcconfig').read_text().splitlines() if line.startswith('MARKETING_VERSION'))
    info = {'CFBundleIdentifier': 'io.github.future0923.QueryCraft.MCP' + ('.Dev' if development else ''),
            'CFBundleName': 'QueryCraft MCP', 'CFBundleExecutable': 'querycraft-mcp', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': version, 'CFBundleVersion': metadata['build'], 'QCMCPVersion': version, 'LSMinimumSystemVersion': '15.0',
            'LSUIElement': True, 'QCAppVersion': app_version, 'QCCredentialHelperRequired': True,
            'QCComponentCatalogBaseURL': 'https://querycraft.debug-tools.cc/components/',
            'QCComponentPublicKey': '8dcu6cE1Vh6kUXtkeuDsSEWIy6sLbuHaqdnnZhE3rP8='}
    (output/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    spec = importlib.util.spec_from_file_location('signer', ROOT/'scripts/code-signing.py')
    signer = importlib.util.module_from_spec(spec); spec.loader.exec_module(signer)
    identity = signer.activate()
    launcher = output/'Contents/Helpers/querycraft-mcp-launcher'
    launcher.parent.mkdir(parents=True, exist_ok=True)
    run('swiftc', '-O', '-target', archs[0]+'-apple-macosx15.0', ROOT/'MCPLauncher/main.swift', '-o', launcher)
    run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', '--identifier', 'io.github.future0923.QueryCraft.MCP.Launcher', launcher)
    helper = output/'Contents/Helpers/QueryCraft Credentials.app'
    (helper/'Contents/MacOS').mkdir(parents=True)
    source = (ROOT/'CredentialHelper/main.swift').read_text().replace('__PINNED_CERTIFICATE_SHA1__', identity)
    source = '\n'.join(line.replace('QueryCraft', 'QueryCraft.MCP') if line.startswith('let callerRequirement =') else line for line in source.splitlines()) + '\n'
    with tempfile.TemporaryDirectory(prefix='querycraft-mcp-helper-') as temporary:
        source_path = Path(temporary)/'main.swift'; source_path.write_text(source)
        binaries = []
        for arch in archs:
            binary = Path(temporary)/arch
            run('swiftc', '-O', '-target', arch+'-apple-macosx15.0', source_path, '-o', binary); binaries.append(binary)
        run('lipo', '-create', *binaries, '-output', helper/'Contents/MacOS/QueryCraftCredentials')
    (helper/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'io.github.future0923.QueryCraft.CredentialHelper',
        'CFBundleName': 'QueryCraft MCP Credentials', 'CFBundleExecutable': 'QueryCraftCredentials', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'LSUIElement': True, 'QCCredentialProtocolVersion': 1}))
    for stale in list(output.rglob('AgentSkills')):
        if stale.is_dir(): shutil.rmtree(stale)
    run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', frameworks / 'QueryCraftFeature.framework')
    run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', helper)
    run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', output)
    run('codesign', '--verify', '--deep', '--strict', output)
    print(run(macos/'querycraft-mcp', '--self-test').decode().strip())
    if archive_enabled:
        descriptor = dict(metadata, component='mcp', architectures=archs)
        base = __import__('os').environ.get('QUERYCRAFT_COMPONENT_DOWNLOAD_BASE_URL','https://querycraft.debug-tools.cc/components').rstrip('/')
        archive = output.parent / f"querycraft-mcp-{version}-{metadata['build']}-{archs[0]}.zip"
        with tempfile.TemporaryDirectory(prefix='qc-component-') as temporary:
            payload = Path(temporary)/'QueryCraftMCP';payload.mkdir()
            shutil.copytree(output,payload/'QueryCraft MCP.app',symlinks=True)
            (payload/'component.json').write_text(json.dumps(descriptor,sort_keys=True))
            run('ditto','-c','-k','--norsrc','--noextattr','--keepParent',payload,archive)
        release = dict(descriptor,size=archive.stat().st_size,sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),url=base+'/'+archive.name)
        archive.with_suffix('.package.json').write_text(json.dumps(release,indent=2)+'\n')
    print(output)

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--architecture', choices=['arm64','x86_64'])
    parser.add_argument('--development', action='store_true')
    parser.add_argument('--no-archive', action='store_true')
    args=parser.parse_args()
    package(args.build_dir.resolve(), args.output.resolve(), args.development, not args.no_archive, args.architecture)
