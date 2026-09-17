#!/usr/bin/env python3
"""Allow only the unmodified, pinned Sparkle artifact inside the distribution."""
import hashlib
from pathlib import Path
import sys


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            target = path.readlink()
            if not path.resolve().is_relative_to(root.resolve()):
                raise ValueError(f'External framework link: {relative}')
            result[relative] = ('link', str(target))
        elif path.is_file():
            result[relative] = ('file', path.stat().st_mode & 0o777, hashlib.sha256(path.read_bytes()).hexdigest())
        elif path.is_dir():
            result[relative] = ('dir',)
        else:
            raise ValueError(f'Unsupported framework entry: {relative}')
    return result


if __name__ == '__main__':
    app_root = Path(__file__).resolve().parents[1]
    original = app_root / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
    installed = Path(sys.argv[1]) / 'Contents/Frameworks/Sparkle.framework'
    if not original.is_dir() or installed.is_symlink() or not installed.is_dir():
        sys.exit('Missing pinned or embedded Sparkle framework')
    if inventory(original) != inventory(installed):
        sys.exit('Embedded Sparkle differs from the pinned dependency')
    original_license = app_root / '.build/checkouts/Sparkle/LICENSE'
    if original_license.read_bytes() != (Path(sys.argv[1]) / 'Contents/Resources/Sparkle-LICENSE.txt').read_bytes():
        sys.exit('Sparkle license differs from the pinned dependency')
    print('Pinned Sparkle framework and license verified.')
