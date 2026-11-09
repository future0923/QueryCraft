#!/usr/bin/env python3
"""Developer ID is the default. QUERYCRAFT_SIGNING_MODE=legacy is recovery only."""
import importlib.util
import os
from pathlib import Path
import subprocess

_mode = os.environ.get('QUERYCRAFT_SIGNING_MODE', 'developer-id')
if _mode not in ('developer-id', 'legacy'):
    raise RuntimeError('Unsupported QUERYCRAFT_SIGNING_MODE.')
_path = Path(__file__).with_name('legacy-code-signing.py' if _mode == 'legacy' else 'developer-id-signing.py')
_spec = importlib.util.spec_from_file_location('querycraft_signer_impl', _path)
_impl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_impl)
for _name in dir(_impl):
    if not _name.startswith('__'):
        globals()[_name] = getattr(_impl, _name)

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
