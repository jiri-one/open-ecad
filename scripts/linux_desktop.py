#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'org.openecad.open_ecad'
INPUTS = (
    '.metadata', 'pubspec.yaml', 'pubspec.lock', 'lib', 'linux', 'assets',
    'packages/ecad_core/pubspec.yaml', 'packages/ecad_core/lib',
)


def notify(message, error=False):
    if shutil.which('notify-send'):
        subprocess.run(
            ['notify-send', '--app-name=Open ECAD', f'--icon={APP_ID}',
             '--urgency=critical' if error else '--urgency=normal',
             'Open ECAD', message],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )


def build_environment(state):
    env = os.environ.copy()
    for key, name in (
        ('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data'),
        ('XDG_CACHE_HOME', 'cache'), ('TMPDIR', 'tmp'),
    ):
        path = state / name
        path.mkdir(parents=True, exist_ok=True)
        env[key] = str(path)
    env['FLUTTER_SUPPRESS_ANALYTICS'] = 'true'
    return env


def find_sdk(root, env):
    explicit = os.environ.get('ECAD_FLUTTER_BIN')
    candidates = [explicit] if explicit else [
        root / '.fvm/flutter_sdk/bin/flutter',
        Path.home() / 'snap/flutter/common/flutter/bin/flutter',
        shutil.which('flutter'), Path.home() / 'flutter/bin/flutter',
        Path.home() / 'development/flutter/bin/flutter', '/opt/flutter/bin/flutter',
    ]
    for candidate in candidates:
        executable = shutil.which(str(candidate)) if candidate else None
        if executable:
            output = subprocess.check_output(
                [executable, '--no-version-check', '--suppress-analytics',
                 '--version', '--machine'], env=env, text=True,
            )
            info = json.loads(output)
            native = Path(info['flutterRoot']) / 'bin/flutter'
            return native, info
    raise RuntimeError('Flutter SDK nebylo nalezeno. Nastavte ECAD_FLUTTER_BIN.')


def source_snapshot(root):
    spec = importlib.util.spec_from_file_location(
        'publication_policy', root / 'scripts/check_publication.py',
    )
    policy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(policy)
    output = subprocess.check_output(
        ['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others',
         '--exclude-standard', '--', *INPUTS],
    )
    files = {}
    for name in sorted(set(os.fsdecode(n) for n in output.split(b'\0') if n)):
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise RuntimeError(f'Odkaz mimo zdrojový strom není vstup sestavení: {name}')
        if not path.is_file():
            continue
        if not policy.permitted(name):
            raise RuntimeError(f'Soukromý nebo nepovolený vstup sestavení: {name}')
        files[name] = path.read_bytes()
    for name in ('pubspec.yaml', 'pubspec.lock', 'lib/main.dart', 'linux/CMakeLists.txt'):
        if name not in files:
            raise RuntimeError(f'Chybí vstup sestavení: {name}')
    return files


def fingerprint(files, sdk):
    digest = hashlib.sha256()
    digest.update(Path(__file__).read_bytes())
    digest.update(json.dumps(sdk, sort_keys=True).encode())
    digest.update(platform.machine().encode())
    for name, data in sorted(files.items()):
        digest.update(name.encode() + b'\0' + hashlib.sha256(data).digest())
    return digest.hexdigest()


def build_snapshot(root, state, files, flutter, env):
    source = state / 'source'
    source.mkdir(exist_ok=True)
    index = state / 'source-inputs.json'
    previous = json.loads(index.read_text()) if index.exists() else []
    for name in set(previous) - files.keys():
        path = source / name
        if not path.resolve().is_relative_to(source):
            raise RuntimeError('Neplatný index vstupů sestavení.')
        path.unlink(missing_ok=True)
    for name, contents in files.items():
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists() or path.read_bytes() != contents:
            path.write_bytes(contents)
    index.write_text(json.dumps(sorted(files)))
    log_path = state / 'build.log'
    with log_path.open('w') as log:
        for args in (
            ['pub', 'get', '--enforce-lockfile'],
            ['build', 'linux', '--release', '--no-pub'],
        ):
            result = subprocess.run(
                [str(flutter), '--no-version-check', '--suppress-analytics', *args],
                cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT,
                check=False,
            )
            if result.returncode:
                raise RuntimeError(f'Sestavení selhalo. Podrobnosti: {log_path}')
    bundles = list((source / 'build/linux').glob('*/release/bundle'))
    if len(bundles) != 1:
        raise RuntimeError(f'Sestavení nemá jednoznačný Linux bundle: {log_path}')
    bundle = bundles[0]
    for name in ('open_ecad', 'lib/libapp.so', 'lib/libflutter_linux_gtk.so',
                 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin'):
        if not (bundle / name).is_file():
            raise RuntimeError(f'Neúplné sestavení: {name}; podrobnosti: {log_path}')
    return bundle


def ensure_current(root, state, flutter, sdk, env):
    state.mkdir(parents=True, exist_ok=True)
    with (state / 'build.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for attempt in range(3):
            files = source_snapshot(root)
            key = fingerprint(files, sdk)
            release = state / 'releases' / key
            binary = release / 'open_ecad'
            if binary.is_file() and (release / 'ready.json').is_file():
                activate(state, release)
                return binary
            if attempt == 0:
                notify('Připravuji aktuální verzi aplikace. Po sestavení se otevře.')
            bundle = build_snapshot(root, state, files, flutter, env)
            if fingerprint(source_snapshot(root), sdk) != key:
                continue
            release.parent.mkdir(exist_ok=True)
            pending = Path(tempfile.mkdtemp(prefix='pending-', dir=release.parent))
            try:
                shutil.copytree(bundle, pending, dirs_exist_ok=True)
                (pending / 'ready.json').write_text(json.dumps({
                    'fingerprint': key, 'flutter': sdk['frameworkVersion'],
                    'inputs': sorted(files),
                }, indent=2) + '\n')
                pending.rename(release)
            finally:
                if pending.exists():
                    shutil.rmtree(pending)
            activate(state, release)
            return binary
    raise RuntimeError('Zdroje se během sestavení opakovaně změnily. Spusťte aplikaci znovu.')


def activate(state, release):
    current = state / 'current'
    if current.is_symlink() and current.resolve() == release:
        return
    pending = state / 'current.new'
    pending.unlink(missing_ok=True)
    pending.symlink_to(release.relative_to(state), target_is_directory=True)
    pending.replace(current)


def desktop_quote(value):
    escaped = value.replace('\\', '\\\\')
    for char in ('"', '`', '$'):
        escaped = escaped.replace(char, '\\' + char)
    return '"' + escaped.replace('\\', '\\\\').replace('%', '%%') + '"'


def install(root, prefix):
    launcher = prefix / 'bin/open-ecad'
    applications = prefix / 'share/applications'
    icons = prefix / 'share/icons/hicolor/scalable/apps'
    mime = prefix / 'share/mime'
    for directory in (launcher.parent, applications, icons, mime / 'packages'):
        directory.mkdir(parents=True, exist_ok=True)
    target = root / 'scripts/linux_desktop.py'
    if launcher.exists() or launcher.is_symlink():
        if not launcher.is_symlink() or launcher.resolve() != target:
            raise RuntimeError(f'Spouštěč už existuje a patří jiné instalaci: {launcher}')
    else:
        launcher.symlink_to(target)
    shutil.copyfile(root / 'assets/brand/open-ecad.svg', icons / f'{APP_ID}.svg')
    desktop = applications / f'{APP_ID}.desktop'
    desktop.write_text(
        '[Desktop Entry]\nType=Application\nName=Open ECAD\n'
        'Comment=Electrical schematic editor\n'
        'Comment[cs]=Editor elektrotechnických schémat\n'
        f'Exec={desktop_quote(str(launcher))} %f\n'
        f'TryExec={launcher}\nIcon={APP_ID}\n'
        'Terminal=false\nStartupNotify=false\n'
        'Categories=Graphics;Engineering;\nKeywords=ECAD;electrical;schematic;\n'
        f'StartupWMClass={APP_ID}\nMimeType=application/x-open-ecad;\n'
    )
    (mime / 'packages' / f'{APP_ID}.xml').write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">\n'
        '  <mime-type type="application/x-open-ecad">\n'
        '    <comment>Open ECAD project</comment>\n'
        '    <sub-class-of type="application/json"/>\n'
        '    <glob pattern="*.oecad"/>\n'
        '  </mime-type>\n</mime-info>\n'
    )
    for command, path in (
        ('desktop-file-validate', desktop),
        ('update-desktop-database', applications),
        ('update-mime-database', mime),
    ):
        if shutil.which(command):
            subprocess.run([command, str(path)], check=True)
    return desktop


def main():
    parser = argparse.ArgumentParser(description='Open ECAD: current local Linux build')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--install', action='store_true', help='Install for the current user')
    mode.add_argument('--build-only', action='store_true', help='Build without opening a window')
    mode.add_argument('--status', action='store_true', help='Check whether the build is current')
    parser.add_argument('--prefix', type=Path, default=Path.home() / '.local')
    parser.add_argument('--project', type=Path)
    parser.add_argument('file', type=Path, nargs='?')
    args = parser.parse_args()
    if args.file and args.project:
        parser.error('Use either a file argument or --project.')
    state = ROOT / '.ai/desktop'
    try:
        env = build_environment(state)
        flutter, sdk = find_sdk(ROOT, env)
        if args.status:
            key = fingerprint(source_snapshot(ROOT), sdk)
            ready = state / 'releases' / key
            print(json.dumps({
                'current': (ready / 'ready.json').is_file() and (ready / 'open_ecad').is_file(),
                'source': str(ROOT), 'fingerprint': key,
            }, ensure_ascii=False))
            return 0
        binary = ensure_current(ROOT, state, flutter, sdk, env)
        if args.install:
            print(install(ROOT, args.prefix.expanduser().resolve()))
            return 0
        if args.build_only:
            print(binary)
            return 0
        project = args.file or args.project
        command = [str(binary)]
        if project:
            command += ['--project', str(project.expanduser().resolve())]
        os.chdir(ROOT)
        os.execv(binary, command)
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        message = str(error)
        print(f'Open ECAD: {message}', file=sys.stderr)
        notify(message, error=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
