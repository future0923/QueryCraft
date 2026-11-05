#!/usr/bin/env python3
"""Load an explicitly supplied, locally packaged Milvus driver without network IO."""
from pathlib import Path
import os
import platform
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
dd = Path(os.environ.get("DERIVED_DATA", root / ".build/DerivedData"))
products = dd / "Build/Products/Debug"
frameworks = products / "PackageFrameworks"
binary = root / ".build/test-milvus-driver-loading"
args = [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
    "-parse-as-library", "-target", platform.machine() + "-apple-macosx15.0",
    str(root / "scripts/test-milvus-driver-loading.swift"),
    "-I", str(products), "-F", str(frameworks), "-framework", "QueryCraftFeature",
    "-o", str(binary), "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
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
if len(sys.argv) != 2:
    raise SystemExit("Usage: test-milvus-driver-loading.py /absolute/path/Milvus.querycraftdriver")
subprocess.run(args, check=True)
subprocess.run([str(binary), str(Path(sys.argv[1]).resolve())], check=True)
