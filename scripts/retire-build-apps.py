#!/usr/bin/env python3
"""Keep old builds without advertising them as Finder applications."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent.parent
LSREGISTER = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
                  'LaunchServices.framework/Support/lsregister')


def unregister(path):
    result = subprocess.run([str(LSREGISTER), '-u', str(path)],
                            capture_output=True, text=True)
    # kLSApplicationNotFoundErr is normal for a backup that was never registered.
    if result.returncode and '-10814' not in result.stdout + result.stderr:
        raise SystemExit(f'Could not unregister {path}: {result.stdout}{result.stderr}')


def retire(path, destination):
    # These are generated bundles only. Keep their contents and signatures intact,
    # including executable files that an older running instance may still use.
    if path.is_symlink() or destination.exists():
        raise SystemExit(f'Refusing unexpected backup path: {path}')
    with (path / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    if not info.get('CFBundleIdentifier', '').startswith('app.clipper.'):
        raise SystemExit(f'Refusing to archive a non-Clipper bundle: {path}')
    unregister(path)
    path.rename(destination)
    # Launch Services can follow an already registered app when it is moved.
    try:
        unregister(destination)
    except SystemExit:
        destination.rename(path)
        raise
    print(f'Archived {path.name} as {destination.name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-current', action='store_true',
                        help='also retire dist/Clipper.app before publishing a new build')
    args = parser.parse_args()
    for pattern in ('previous-app-*.app', 'previous-glass-prototype-*.app'):
        for path in sorted((ROOT / '.build').glob(pattern)):
            retire(path, path.with_suffix('.app-backup'))
    current = ROOT / 'dist/Clipper.app'
    if args.include_current and current.exists():
        destination = ROOT / '.build' / f'previous-app-{uuid.uuid4()}.app-backup'
        retire(current, destination)


if __name__ == '__main__':
    main()
