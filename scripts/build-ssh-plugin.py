#!/usr/bin/env python3
"""Build a self-contained signed SSH plugin; no Homebrew runtime dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    'libssh2': ('1.11.1', 'https://libssh2.org/download/libssh2-1.11.1.tar.gz',
                'd9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7'),
    'openssl': ('3.6.3', 'https://github.com/openssl/openssl/releases/download/openssl-3.6.3/openssl-3.6.3.tar.gz',
                '243a86649cf6f23eeb6a2ff2456e09e5d77dd9018a54d3d96b0c6bdd6ba6c7f1'),
}


def run(args, log, cwd=None, env=None):
    with log.open('ab') as output:
        subprocess.run([str(a) for a in args], cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)


def source(name, cache, destination):
    version, url, digest = SOURCES[name]
    archive = cache / f'{name}-{version}.tar.gz'
    if not archive.exists():
        partial = archive.with_suffix('.download')
        try:
            with urllib.request.urlopen(url, timeout=60) as response, partial.open('wb') as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(partial.read_bytes()).hexdigest() != digest:
                raise RuntimeError(f'{name} source checksum mismatch')
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError(f'{name} cached source checksum mismatch')
    if not destination.exists():
        destination.mkdir(parents=True)
        with tarfile.open(archive) as tar:
            # Sources are pinned, but still reject escaping archive entries.
            for item in tar.getmembers():
                path = Path(*Path(item.name).parts[1:])
                if path.is_absolute() or '..' in path.parts or item.issym() or item.islnk():
                    raise RuntimeError(f'Unsupported source archive entry: {item.name}')
                if not path.parts:
                    continue
                item.name = str(path)
                tar.extract(item, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['x86_64', 'arm64'], default=os.uname().machine)
    parser.add_argument('--identity', default='-', help='Code signing identity; - creates a local ad-hoc development plugin')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/ssh-plugin/packages')
    parser.add_argument('--openssl-prefix', type=Path, help='Use an existing static OpenSSL development installation (local builds only)')
    args = parser.parse_args()
    build = ROOT / '.build/ssh-plugin'
    build.mkdir(parents=True, exist_ok=True)
    architecture = build / args.arch
    architecture.mkdir(exist_ok=True)
    log = architecture / 'build.log'
    print(f'Building SSH plugin for {args.arch}; log: {log}', flush=True)
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET='15.0')
    jobs = str(min(os.cpu_count() or 2, 4))
    if args.openssl_prefix:
        crypto = args.openssl_prefix.resolve()
    else:
        crypto = architecture / 'openssl-install'
        if not (crypto / 'lib/libcrypto.a').exists():
            openssl = source('openssl', build, architecture / 'openssl-source')
            run(['./Configure', f'darwin64-{args.arch}-cc', 'no-shared', 'no-tests', 'no-apps', 'no-docs',
                 '--libdir=lib', f'--prefix={crypto}', '-mmacosx-version-min=15.0'], log, openssl, env)
            run(['make', f'-j{jobs}'], log, openssl, env)
            run(['make', 'install_sw'], log, openssl, env)
    if not (crypto / 'lib/libcrypto.a').is_file():
        raise RuntimeError('A static libcrypto.a is required')
    ssh = source('libssh2', build, architecture / 'libssh2-source')
    install = architecture / 'libssh2-install'
    crypto_fingerprint = hashlib.sha256((crypto / 'lib/libcrypto.a').read_bytes()).hexdigest()
    crypto_record = install / 'crypto-source.txt'
    if not (install / 'lib/libssh2.a').exists() or not crypto_record.exists() or crypto_record.read_text() != crypto_fingerprint:
        if (ssh / 'Makefile').exists():
            run(['make', 'distclean'], log, ssh, env)
        configure_env = dict(env, CFLAGS=f'-arch {args.arch} -mmacosx-version-min=15.0 -fvisibility=hidden',
                             LDFLAGS=f'-arch {args.arch}', PKG_CONFIG='/usr/bin/false')
        run(['./configure', f'--host={"aarch64" if args.arch == "arm64" else "x86_64"}-apple-darwin',
             '--disable-shared', '--enable-static', '--disable-examples-build', '--disable-tests',
             '--with-crypto=openssl', f'--with-libssl-prefix={crypto}', '--without-libz',
             f'--prefix={install}'], log, ssh, configure_env)
        run(['make', f'-j{jobs}'], log, ssh, configure_env)
        run(['make', 'install'], log, ssh, configure_env)
        crypto_record.write_text(crypto_fingerprint)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    bundle = args.output / f'{args.arch}/QueryCraftSSH.bundle'
    if bundle.exists():
        shutil.rmtree(bundle)
    binary = bundle / 'Contents/MacOS/QueryCraftSSH'
    binary.parent.mkdir(parents=True)
    licenses = bundle / 'Contents/Resources/Licenses'
    licenses.mkdir(parents=True)
    header = ROOT / 'QueryCraftPackage/Sources/CQueryCraftSSHPluginAPI/include'
    exports = architecture / 'exports.txt'
    exports.write_text(''.join('_querycraft_ssh_plugin_' + name + '\n' for name in ['version', 'create', 'run', 'cancel', 'destroy', 'file_version', 'file_create', 'file_management_version', 'pool_version', 'pool_create', 'pool_run', 'pool_invalidate', 'pool_prune', 'pool_destroy', 'progress_version', 'set_progress', 'route_version', 'set_route', 'diagnostic_version', 'diagnostic']))
    run(['clang', '-arch', args.arch, '-mmacosx-version-min=15.0', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
         '-fvisibility=hidden', '-dynamiclib', '-I', header, '-I', install / 'include',
         ROOT / 'QueryCraftSSHPlugin/src/ssh_plugin.c', install / 'lib/libssh2.a', crypto / 'lib/libcrypto.a',
         '-framework', 'Security', '-framework', 'CoreFoundation', '-lpthread',
         '-Wl,-install_name,@rpath/QueryCraftSSH', '-Wl,-exported_symbols_list,' + str(exports), '-o', binary], log)
    dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    if any(line.strip().startswith(('/usr/local/', '/opt/homebrew/', str(build))) for line in dependencies.splitlines()[1:]):
        raise RuntimeError('Plugin leaked a development dependency')
    metadata = json.loads((ROOT / 'Components/versions.json').read_text())['ssh']
    descriptor = dict(metadata, component='ssh', architectures=[args.arch])
    (bundle / 'Contents/Resources/component.json').write_text(json.dumps(descriptor, sort_keys=True) + '\n')
    info = {'CFBundleIdentifier': 'io.github.future0923.QueryCraft.SSH', 'CFBundleName': 'QueryCraftSSH',
            'CFBundleExecutable': 'QueryCraftSSH', 'CFBundlePackageType': 'BNDL', 'CFBundleShortVersionString': metadata['version'],
            'CFBundleVersion': metadata['build'], 'QCSSHPluginABIVersion': 1, 'QCSSHFileABIVersion': 1, 'LSMinimumSystemVersion': '15.0'}
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copyfile(ssh / 'COPYING', licenses / 'libssh2.txt')
    if args.openssl_prefix:
        crypto_license = crypto / 'LICENSE.txt'
    else:
        crypto_license = architecture / 'openssl-source/LICENSE.txt'
    shutil.copyfile(crypto_license, licenses / 'OpenSSL.txt')
    (bundle / 'Contents/Resources/build.json').write_text(json.dumps({
        'abi': 1, 'architecture': args.arch, 'libssh2': SOURCES['libssh2'][0],
        'openssl': subprocess.check_output([str(crypto / 'bin/openssl'), 'version'], text=True).strip()
            if (crypto / 'bin/openssl').exists() else SOURCES['openssl'][0],
        'local_crypto_override': bool(args.openssl_prefix),
    }, indent=2) + '\n')
    signing = ['codesign', '--force', '--sign', args.identity]
    signing += ['--timestamp', '--options', 'runtime'] if args.identity.startswith('Developer ID Application:') else ['--timestamp=none']
    run(signing + [bundle], log)
    run(['codesign', '--verify', '--deep', '--strict', bundle], log)
    archive = args.output / f'QueryCraftSSH-{args.arch}.zip'
    archive.unlink(missing_ok=True)
    run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', bundle, archive], log)
    print(json.dumps({'bundle': str(bundle), 'archive': str(archive),
                      'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}, indent=2))


if __name__ == '__main__':
    main()
