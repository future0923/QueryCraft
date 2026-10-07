#!/usr/bin/env python3
"""Install an isolated, persistently signed Dev app from a completed Debug build."""
from pathlib import Path
import datetime
import importlib.util
import plistlib
import re
import shutil
import subprocess
import time
import uuid

root = Path(__file__).resolve().parent.parent
products = root / '.build/DerivedData/Build/Products/Debug'
installed = Path('/Applications/QueryCraftDev.app')
dev_id = 'io.github.future0923.QueryCraft.Dev'
token = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8]
staged = installed.parent / ('.QueryCraftDev-' + token + '.app')
backup = root / '.build/dev-app-backups' / token / installed.name
if installed.exists():
    assert plistlib.loads((installed / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == dev_id
subprocess.run(['ditto', str(products / 'QueryCraft.app'), str(staged)], check=True)
info_path = staged / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info.update(CFBundleIdentifier=dev_id, CFBundleName='QueryCraft Dev',
            CFBundleDisplayName='QueryCraft Dev', QCDevelopmentBuild=token)
info_path.write_bytes(plistlib.dumps(info))
sparkle = staged / 'Contents/Frameworks/Sparkle.framework'
shutil.rmtree(sparkle)
subprocess.run(['ditto', str(root / '.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'), str(sparkle)], check=True)
# Keep the installed app independent of mutable, unsigned build products.
for binary in (staged / 'Contents/MacOS/QueryCraft', staged / 'Contents/Frameworks/QueryCraftFeature.framework/QueryCraftFeature'):
    output = subprocess.run(['otool', '-l', str(binary)], check=True, capture_output=True, text=True).stdout
    paths = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset', output)
    for path in paths:
        if path.startswith('/') and not path.startswith(('/usr/lib/', '/System/Library/')):
            subprocess.run(['install_name_tool', '-delete_rpath', path, str(binary)], check=True)
    verified = subprocess.run(['otool', '-l', str(binary)], check=True, capture_output=True, text=True).stdout
    assert str(root / '.build') not in verified, 'Build path remains in installed binary'
spec = importlib.util.spec_from_file_location('querycraft_signer', root / 'scripts/code-signing.py')
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
identity = signer.activate()
subprocess.run(['python3', str(root / 'scripts/credential-helper.py'), str(staged)], check=True)
signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', staged / 'Contents/Frameworks/QueryCraftFeature.framework')
signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', '--entitlements', root / 'Config/Release.entitlements', staged)
signer.verify(staged)

def running():
    result = subprocess.run(['pgrep', '-f', r'/QueryCraftDev\.app/Contents/MacOS/QueryCraft( |$)'], capture_output=True)
    if result.returncode not in (0, 1):
        raise RuntimeError('Could not check Dev process')
    return result.returncode == 0

if running():
    subprocess.run(['osascript', '-e', 'tell application id "io.github.future0923.QueryCraft.Dev" to quit'], check=True, timeout=15)
    for _ in range(25):
        if not running():
            break
        time.sleep(0.2)
    if running():
        raise RuntimeError('Dev is still running; replacement canceled')
backup.parent.mkdir(parents=True, exist_ok=True)
if installed.exists():
    installed.rename(backup)
try:
    staged.rename(installed)
except BaseException:
    if backup.exists():
        backup.rename(installed)
    raise
print('Installed:', installed)
print('Backup:', backup)
