#!/usr/bin/env python3
"""Prepare the Dev profile and check the installed Milvus driver read-only."""
from pathlib import Path
import os
import platform
import subprocess
import sys
import plistlib
import importlib.util

root = Path(__file__).resolve().parent.parent
dd = Path(os.environ.get("DERIVED_DATA", root / ".build/DerivedData"))
products = dd / "Build/Products/Debug"
frameworks = products / "PackageFrameworks"
app = root / ".build/MilvusAcceptance.app"
binary = app / "Contents/MacOS/MilvusAcceptance"
binary.parent.mkdir(parents=True, exist_ok=True)
host_info = plistlib.loads(Path("/Applications/QueryCraftDev.app/Contents/Info.plist").read_bytes())
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "io.github.future0923.QueryCraft.Dev", "CFBundleExecutable": "MilvusAcceptance", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": host_info["CFBundleShortVersionString"], "NSAppTransportSecurity": host_info["NSAppTransportSecurity"]}))
args = [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
    "-parse-as-library", "-target", platform.machine() + "-apple-macosx15.0",
    str(root / "scripts/milvus-mac-acceptance.swift"),
    "-I", str(products), "-F", str(frameworks), "-framework", "QueryCraftFeature",
    "-o", str(binary), "-Xlinker", "-rpath", "-Xlinker", "/Applications/QueryCraftDev.app/Contents/Frameworks",
]
for name in ["TreeSitterJSON", "TreeSitterSQL", "TreeSitter", "Internal", "CQueryCraftSSHPluginAPI"]:
    args += ["-Xcc", "-fmodule-map-file=" + str(dd / f"Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap")]
args += ["-Xcc", "-fmodule-map-file=" + str(dd / "SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap")]
for path in [
    root / "ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include",
    root / "ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include",
    root / "QueryCraftPackage/Sources/CQueryCraftSSHPluginAPI/include",
    dd / "SourcePackages/checkouts/tree-sitter/lib/include",
    dd / "SourcePackages/checkouts/TextStory/Sources/Internal",
    root / "ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include",
]:
    args += ["-Xcc", "-I" + str(path)]
subprocess.run(args, check=True)
spec = importlib.util.spec_from_file_location("signer", root / "scripts/code-signing.py")
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
identity = signer.activate()
subprocess.run(["ditto", "/Applications/QueryCraftDev.app/Contents/Helpers", str(app / "Contents/Helpers")], check=True)
signer.run("codesign", "--force", "--sign", identity, "--keychain", signer.KEYCHAIN, "--timestamp=none", app)
env = dict(os.environ, DYLD_FRAMEWORK_PATH="/Applications/QueryCraftDev.app/Contents/Frameworks")
subprocess.run([str(binary)], input=sys.stdin.buffer.read(), env=env, check=True)
