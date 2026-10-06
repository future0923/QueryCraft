#!/usr/bin/env python3
"""Prepare two signed copies of the installed Dev app, or install one for testing."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "artifacts/signing-trial"
INSTALLED = Path("/Applications/QueryCraftDev.app")
SIGNER = ROOT / "scripts/code-signing.py"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def validate_dev(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != "io.github.future0923.QueryCraft.Dev":
        raise RuntimeError("The trial only accepts the isolated QueryCraftDev application.")
    return info


def prepare(source):
    info = validate_dev(source)
    if OUTPUT.exists():
        raise RuntimeError(f"Trial directory already exists; preserve its backups before preparing another: {OUTPUT}")
    OUTPUT.mkdir(parents=True)
    signatures = {}
    for index, variant in enumerate(("A", "B"), start=1):
        app = OUTPUT / variant / "QueryCraftDev.app"
        run("ditto", source, app)
        variant_info = dict(info)
        variant_info["CFBundleVersion"] = str(info["CFBundleVersion"]).split(".")[0] + f".100{index}"
        variant_info["CFBundleDisplayName"] = "QueryCraftDev " + variant
        variant_info["QCSelfSigningTrial"] = variant
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(variant_info))
        run(sys.executable, SIGNER, "sign", app)
        result = subprocess.run(["codesign", "-d", "-r-", "--verbose=4", str(app)],
                                capture_output=True, text=True, check=True)
        signatures[variant] = result.stdout + result.stderr
        launcher = OUTPUT / f"Install-{variant}.command"
        launcher.write_text("#!/bin/bash\n" + shlex.join([
            sys.executable, str(Path(__file__).resolve()), "install", variant,
        ]) + '\nresult=$?\nif [[ "$result" != 0 ]]; then read -r -p "Press Return to close..."; fi\nexit "$result"\n')
        launcher.chmod(0o755)
    requirements = [next(line for line in value.splitlines() if "designated =>" in line)
                    for value in signatures.values()]
    hashes = [next(line for line in value.splitlines() if line.startswith("CDHash="))
              for value in signatures.values()]
    if requirements[0] != requirements[1] or hashes[0] == hashes[1]:
        raise RuntimeError("Trial versions must have different hashes and identical designated requirements.")
    (OUTPUT / "signatures.json").write_text(json.dumps(signatures, indent=2) + "\n")
    (OUTPUT / "使用说明.txt").write_text("""QueryCraft 固定签名测试

1. 退出正在运行的 QueryCraftDev。正式版 QueryCraft 可以继续运行。
2. 双击 Install-A.command，自动备份并安装 A 版，然后启动。
3. 在 A 版打开已有连接。如果钥匙串要求授权，请选择“始终允许”。
   也可以创建一个临时连接，保存密码后退出并重新打开，确认 A 版能读取。
4. 退出 QueryCraftDev，双击 Install-B.command，再打开相同连接。
5. B 版不应再因签名变化要求钥匙串授权。

A/B 都来自当前已安装的开发版，使用同一张持久证书、相同 Bundle ID，
但构建号与代码签名哈希不同。测试使用 QueryCraftDev 的原有数据目录。
每次安装都将原来的开发版备份到本目录 backups 中；不会覆盖正式版。
安装器发现开发版仍在运行时会停止，请先自行退出，避免丢失未保存内容。
本测试通过本地替换应用模拟升级，没有向线上发布 Sparkle 更新。
""")
    print("Trial ready: " + str(OUTPUT))


def install(variant):
    source = OUTPUT / variant / "QueryCraftDev.app"
    validate_dev(source)
    run(sys.executable, SIGNER, "verify", source)
    running = subprocess.run(["pgrep", "-f", r"/QueryCraftDev\.app/Contents/MacOS/QueryCraft( |$)"],
                             stdout=subprocess.DEVNULL)
    if running.returncode == 0:
        raise RuntimeError("请先退出正在运行的 QueryCraftDev，再双击安装；未修改现有应用。")
    if running.returncode != 1:
        raise RuntimeError("Could not check whether QueryCraftDev is running.")
    if INSTALLED.exists():
        validate_dev(INSTALLED)
    token = datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    staged = INSTALLED.parent / (".QueryCraftDev-" + token + ".app")
    backup = OUTPUT / "backups" / token / INSTALLED.name
    run("ditto", source, staged)
    run(sys.executable, SIGNER, "verify", staged)
    if INSTALLED.exists():
        backup.parent.mkdir(parents=True)
        INSTALLED.rename(backup)
    try:
        staged.rename(INSTALLED)
    except OSError:
        if backup.exists() and not INSTALLED.exists():
            backup.rename(INSTALLED)
        raise
    run("open", INSTALLED)
    print(f"已安装并启动测试 {variant} 版。原开发版备份：{backup}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "install"])
    parser.add_argument("variant", nargs="?", choices=["A", "B"])
    parser.add_argument("--source", type=Path, default=INSTALLED)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(args.source)
        elif args.variant:
            install(args.variant)
        else:
            parser.error("install requires A or B")
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
