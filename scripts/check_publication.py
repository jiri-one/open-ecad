#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Enforce the source-only publication path policy; content still needs review."""
import argparse
from pathlib import PurePosixPath
import re
import subprocess
import sys

ROOT_FILES = {
    '.gitignore', '.metadata', 'LICENSE', 'README.md', 'THIRD_PARTY_NOTICES.md',
    'analysis_options.yaml', 'pubspec.yaml', 'pubspec.lock',
}
SOURCE_ROOTS = {
    '.github', '.githooks', 'assets', 'integration_test', 'lib', 'linux',
    'macos', 'packages', 'scripts', 'test', 'test_driver', 'web', 'windows',
}
DOCUMENTS = {
    'docs/architecture.md', 'docs/pdf-import.md', 'docs/testing.md',
    'docs/windows-native-build.md',
}
PRIVATE_PARTS = {
    'output', 'tmp', 'dist', 'build', 'artifacts', 'examples', 'datasets',
    'training-data', 'input-data', '.venv-pdf', '.dart_tool', '__pycache__',
}
DATA_SUFFIXES = {
    '.pdf', '.oecad', '.csv', '.tsv', '.xlsx', '.xls', '.zip', '.gz', '.7z',
    '.sqlite', '.db', '.pem', '.key', '.log', '.pyc',
}
SOURCE_SUFFIXES = {
    '.dart', '.py', '.ps1', '.sh', '.cc', '.cpp', '.h', '.cmake', '.yaml',
    '.yml', '.md', '.txt', '.lock', '.xcconfig', '.swift', '.plist',
    '.entitlements', '.json', '.pbxproj', '.xcscheme', '.xcworkspacedata',
    '.xib', '.html', '.rc', '.manifest',
}
PRODUCT_ASSETS = {
    'assets/brand/open-ecad.svg',
    'assets/fonts/NotoSans-Regular.ttf', 'assets/fonts/NotoSans-SemiBold.ttf',
    'windows/runner/resources/app_icon.ico', 'web/favicon.png',
} | {
    f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png'
    for size in (16, 32, 64, 128, 256, 512, 1024)
} | {
    f'web/icons/{name}.png'
    for name in ('Icon-192', 'Icon-512', 'Icon-maskable-192', 'Icon-maskable-512')
}


def permitted(name: str) -> bool:
    path = PurePosixPath(name)
    if any(part.lower() in PRIVATE_PARTS for part in path.parts):
        return False
    if path.suffix.lower() in DATA_SUFFIXES or path.name.startswith('.env'):
        return False
    if path.name == 'AGENTS.md' or name.lower().endswith('.oecad.json'):
        return False
    if name in PRODUCT_ASSETS:
        return True
    if path.suffix.lower() not in SOURCE_SUFFIXES and path.name not in {
        'LICENSE', '.gitignore', '.metadata', 'pre-push',
    }:
        return False
    if path.suffix.lower() == '.txt' and path.name not in {
        'CMakeLists.txt', 'LICENSE.txt', 'import_pdf_requirements.txt',
    }:
        return False
    if path.suffix.lower() == '.md' and name not in DOCUMENTS and path.name not in {
        'README.md', 'THIRD_PARTY_NOTICES.md',
    }:
        return False
    if path.suffix.lower() == '.json' and not (
        name == 'web/manifest.json'
        or (name.startswith('macos/Runner/Assets.xcassets/') and path.name == 'Contents.json')
    ):
        return False
    return name in ROOT_FILES or name in DOCUMENTS or path.parts[0] in SOURCE_ROOTS


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', help='Full commit ID to check instead of the Git index')
    parser.add_argument('--history', action='store_true', help='Check every ancestor of --revision, including deleted paths')
    args = parser.parse_args()
    if args.history and not args.revision:
        parser.error('--history requires --revision')
    if args.revision:
        if not re.fullmatch(r'[0-9a-fA-F]{40,64}', args.revision):
            parser.error('--revision requires a full Git commit ID')
        revisions = (
            subprocess.check_output(['git', 'rev-list', args.revision]).decode().splitlines()
            if args.history else [args.revision]
        )
        paths = set()
        for revision in revisions:
            paths.update(p for p in subprocess.check_output(
                ['git', 'ls-tree', '-r', '-z', '--name-only', revision]
            ).decode().split('\0') if p)
    else:
        paths = set(p for p in subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0') if p)
    rejected = sorted(p for p in paths if not permitted(p))
    if rejected:
        print('Publication blocked: these paths must stay local:', file=sys.stderr)
        print('\n'.join(rejected), file=sys.stderr)
        return 1
    print(f'Publication path check passed for {len(paths)} source files. Review their content before pushing.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
