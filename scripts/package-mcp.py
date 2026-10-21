#!/usr/bin/env python3
"""Package the independent MCP runtime. The host application never embeds it.

Requires completed Xcode QueryCraft and querycraft-mcp scheme builds. Does not publish or install anything.
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
    # The independent package references Feature as an external dynamic product.
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
    source_executable = build / 'querycraft-mcp'
    if not source_executable.is_file():
        raise RuntimeError('Build the independent querycraft-mcp scheme before packaging MCP.')
    executable_archs = run('lipo', '-archs', source_executable).decode().split()
    if set(executable_archs) != set(archs):
        raise RuntimeError('MCP executable architecture must match the requested single-architecture package.')
    # This executable depends on the dynamic Feature product. Never relink its
    # sources here or embed a second copy of driver/registry types.
    shutil.copy2(source_executable, executable)
    libraries = run('otool', '-L', executable).decode()
    if '@rpath/QueryCraftFeature.framework/' not in libraries:
        raise RuntimeError('MCP must link the shared QueryCraftFeature framework dynamically.')
    processed = set()
    owned_frameworks = {frameworks / 'QueryCraftFeature.framework'}
    pending = [executable, frameworks / 'QueryCraftFeature.framework/Versions/A/QueryCraftFeature']
    # Xcode can emit shared transitive products (e.g. swift-collections) for
    # this executable. Copy only its dependency closure, never other drivers.
    while pending:
        binary = pending.pop()
        if binary in processed:
            continue
        processed.add(binary)
        if set(run('lipo', '-archs', binary).decode().split()) != set(archs):
            raise RuntimeError(f'Dependency architecture does not match MCP: {binary.name}')
        lines = run('otool', '-l', binary).decode().splitlines()
        if binary == executable and not any('path @executable_path/../Frameworks (offset' in line for line in lines):
            run('install_name_tool', '-add_rpath', '@executable_path/../Frameworks', binary)
        for i, line in enumerate(lines):
            if line.strip() == 'cmd LC_RPATH':
                value = lines[i + 2].strip().split('path ', 1)[1].split(' (offset')[0]
                if value.startswith('/') and not value.startswith(('/usr/lib/', '/System/')):
                    run('install_name_tool', '-delete_rpath', value, binary)
        for line in run('otool', '-L', binary).decode().splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            if dependency.startswith(('/System/', '/usr/lib/', '@loader_path/', '@executable_path/')):
                continue
            if dependency == '@rpath/libswiftCore.dylib':
                # macOS 15 supplies Swift's stable runtime in the dyld cache.
                run('install_name_tool', '-change', dependency, '/usr/lib/swift/libswiftCore.dylib', binary)
                continue
            if dependency.startswith('@rpath/'):
                relative = Path(dependency[len('@rpath/'):])
                if str(relative).startswith('libswiftCompatibility'):
                    continue
                destination = frameworks / relative
                if not destination.exists() and relative.parts[0].endswith('.framework'):
                    source = build / 'PackageFrameworks' / relative.parts[0]
                    if source.is_dir():
                        copied = frameworks / source.name
                        shutil.copytree(source, copied, symlinks=True)
                        owned_frameworks.add(copied)
                if destination.exists():
                    # Preserve the upstream Sparkle framework and its nested signatures.
                    if relative.parts[0] != 'Sparkle.framework':
                        owned_frameworks.add(frameworks / relative.parts[0])
                        pending.append(destination)
                    continue
            raise RuntimeError(f'Unresolved or nonportable dependency: {dependency}')
    for binary in processed:
        run('strip', '-x', binary)
    metadata = json.loads((ROOT/'Components/versions.json').read_text())['mcp']
    version = metadata['version']
    app_version = next(line.split('=',1)[1].strip() for line in (ROOT/'Config/Shared.xcconfig').read_text().splitlines() if line.startswith('MARKETING_VERSION'))
    info = {'CFBundleIdentifier': 'io.github.future0923.QueryCraft.MCP' + ('.Dev' if development else ''),
            'CFBundleName': 'QueryCraft Dev MCP' if development else 'QueryCraft MCP',
            'CFBundleDisplayName': 'QueryCraft Dev MCP' if development else 'QueryCraft MCP', 'CFBundleExecutable': 'querycraft-mcp', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': version, 'CFBundleVersion': metadata['build'], 'QCMCPVersion': version, 'LSMinimumSystemVersion': '15.0',
            'LSUIElement': True, 'QCAppVersion': app_version, 'QCCredentialHelperRequired': True, 'QCSharedCredentialHelperRequired': True,
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
    helper_spec = importlib.util.spec_from_file_location('credential_helper', ROOT/'scripts/credential-helper.py')
    helper_packager = importlib.util.module_from_spec(helper_spec); helper_spec.loader.exec_module(helper_packager)
    helper_packager.embed_shared(output, signer, identity, archs)
    for stale in list(output.rglob('AgentSkills')):
        if stale.is_dir(): shutil.rmtree(stale)
    for framework in sorted(owned_frameworks):
        run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', framework)
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
