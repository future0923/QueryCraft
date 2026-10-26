#!/usr/bin/env python3
"""Apply the checked-in viewport fix to the exact pinned SwiftTerm checkout."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def apply(checkout):
    checkout = Path(checkout)
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != '5c83a9d214e7354697624c11deb4e488bdcfabad':
        raise RuntimeError('The SwiftTerm viewport patch requires the pinned 1.10.1 revision')
    patch = str(ROOT / 'ThirdParty/SwiftTerm/QueryCraft.patch')
    check = subprocess.run(['git', '-C', str(checkout), 'apply', '--check', patch], capture_output=True)
    if check.returncode == 0:
        subprocess.run(['git', '-C', str(checkout), 'apply', patch], check=True)
    elif subprocess.run(['git', '-C', str(checkout), 'apply', '--reverse', '--check', patch], capture_output=True).returncode:
        raise RuntimeError('SwiftTerm sources do not match the viewport patch')


if __name__ == '__main__':
    apply(sys.argv[1])
