#!/usr/bin/env python3
"""Render the unified welcome connection catalog, SSH selection and script-only settings offscreen with isolated data."""
import argparse
import importlib.util
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--language', choices=['en', 'zh-Hans'], default='zh-Hans')
    args = parser.parse_args(); args.output = args.output.resolve(); args.output.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('signer', ROOT / 'scripts/code-signing.py')
    signer = importlib.util.module_from_spec(spec); spec.loader.exec_module(signer); identity = signer.activate()
    dd = ROOT / '.build/DerivedData'; products = dd / 'Build/Products/Debug'; frameworks = products / 'PackageFrameworks'
    with tempfile.TemporaryDirectory(prefix='qc-welcome-ssh-') as temporary:
        temporary = Path(temporary); host = temporary / 'Verifier.app'; binary = host / 'Contents/MacOS/Verifier'; binary.parent.mkdir(parents=True)
        (host / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='io.github.future0923.QueryCraft.Dev.WelcomeSSHUIValidation', CFBundleExecutable='Verifier', CFBundleShortVersionString='0.1.12', CFBundleIconFile='AppIcon', CFBundlePackageType='APPL', LSUIElement=True, CFBundleDevelopmentRegion=args.language, CFBundleLocalizations=[args.language])))
        sdk = subprocess.check_output(['xcode-select', '-p'], text=True).strip() + '/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
        command = ['swiftc', '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0', '-sdk', sdk, str(ROOT / 'scripts/test-welcome-ssh-ui.swift'), '-I', str(products), '-F', str(frameworks), '-framework', 'QueryCraftFeature', '-o', str(binary), '-Xlinker', '-rpath', '-Xlinker', str(frameworks)]
        for name in ['TreeSitterJSON', 'TreeSitterSQL', 'TreeSitter', 'Internal', 'CQueryCraftSSHPluginAPI']:
            path = dd / f'Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap'
            if path.exists(): command += ['-Xcc', '-fmodule-map-file=' + str(path)]
        command += ['-Xcc', '-fmodule-map-file=' + str(dd / 'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
        for path in [ROOT / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include', ROOT / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include', dd / 'SourcePackages/checkouts/tree-sitter/lib/include', dd / 'SourcePackages/checkouts/TextStory/Sources/Internal', ROOT / 'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
            command += ['-Xcc', '-I' + str(path)]
        subprocess.run(command, check=True)
        resources = host / 'Contents/Resources'; resources.mkdir()
        icon = Path('/Applications/QueryCraftDev.app/Contents/Resources/AppIcon.icns')
        if icon.exists(): shutil.copy2(icon, resources / 'AppIcon.icns')
        for bundle in products.glob('*.bundle'): shutil.copytree(bundle, resources / bundle.name, symlinks=True)
        signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', host)
        subprocess.run([str(binary), str(temporary / 'Data'), str(args.output)], check=True, timeout=90)


if __name__ == '__main__': main()
