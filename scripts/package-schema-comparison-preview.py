#!/usr/bin/env python3
"""Stage a self-contained local Dev preview without replacing /Applications."""
from pathlib import Path
import datetime
import importlib.util
import os
import plistlib
import re
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
dd = Path(os.environ.get('DERIVED_DATA', root / 'output/schema-comparison-build')).resolve()
products = dd / 'Build/Products/Debug'
destination = Path(os.environ.get('QC_SCHEMA_PREVIEW_DIRECTORY', dd / 'preview')).resolve() / 'QueryCraftDev.app'
if destination.exists():
    raise SystemExit('Preview already exists; preserve it or choose a different derived-data directory.')
destination.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', str(products / 'QueryCraft.app'), str(destination)], check=True)
info_path = destination / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info.update(CFBundleIdentifier='io.github.future0923.QueryCraft.Dev', CFBundleName='QueryCraft Dev',
            CFBundleDisplayName='QueryCraft Dev', QCDevelopmentBuild='schema-comparison-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
info_path.write_bytes(plistlib.dumps(info))
sparkle = destination / 'Contents/Frameworks/Sparkle.framework'
shutil.rmtree(sparkle)
subprocess.run(['ditto', str(dd / 'SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'), str(sparkle)], check=True)
for binary in [destination / 'Contents/MacOS/QueryCraft', destination / 'Contents/Frameworks/QueryCraftFeature.framework/QueryCraftFeature']:
    commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
    for path in re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset', commands):
        if path.startswith('/') and not path.startswith(('/usr/lib/', '/System/Library/')):
            subprocess.run(['install_name_tool', '-delete_rpath', path, str(binary)], check=True)
    verified = subprocess.check_output(['otool', '-l', str(binary)], text=True)
    assert str(dd) not in '\n'.join(verified.splitlines()[1:]), 'Mutable build path remains'
spec = importlib.util.spec_from_file_location('signer', root / 'scripts/code-signing.py')
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
identity = signer.activate()
subprocess.run([sys.executable, str(root / 'scripts/credential-helper.py'), str(destination)], check=True)
signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', destination / 'Contents/Frameworks/QueryCraftFeature.framework')
signer.run('codesign', '--force', '--sign', identity, '--keychain', signer.KEYCHAIN, '--timestamp=none', '--entitlements', root / 'Config/Release.entitlements', destination)
signer.verify(destination)
(destination.parent / '开始测试.txt').write_text('''结构对比测试版

1. 先退出正在运行的 QueryCraft Dev，再打开本目录的 QueryCraftDev.app。
2. 工具 → 结构对比与同步…（⌃⌥⌘S）。
3. 第一页选择两端连接与数据库，可指定表、忽略注释或设置选项，然后点「开始比较」。
4. 读取结构后，第二页上方选择对象，下方查看 DDL 和 SQL；勾选支持的变更，点「下一步：审核 SQL」。
5. 独立审核页查看全部或单项 SQL，复制或导出；「上一步」返回并保留选择。
6. 确认目标与风险后可部署；执行前重读结构，执行后回读核对。结果页保留逐条日志。
7. 选项中启用回退后，可在成功结果页审核回退脚本。回退仅恢复结构，不能恢复已删除的数据。

此包使用现有 Dev 连接配置与 API 5 驱动；不会安装或覆盖 /Applications 内的程序。
当前适用于 MySQL 5.7 / 8.0 / 8.4；其他数据库未接入本工具。
''')
print('PASS standalone Dev preview and pinned signature:', destination)
