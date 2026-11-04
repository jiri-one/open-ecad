#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('desktop', ROOT / 'scripts/linux_desktop.py')
desktop = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(desktop)


class DesktopTests(unittest.TestCase):
    def setUp(self):
        directory = ROOT / '.ai/linux-desktop-tests'
        directory.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=directory)
        self.root = Path(self.temporary.name)
        (self.root / 'scripts').mkdir()
        shutil.copyfile(ROOT / 'scripts/check_publication.py', self.root / 'scripts/check_publication.py')
        for name in ('pubspec.yaml', 'pubspec.lock', 'lib/main.dart', 'linux/CMakeLists.txt'):
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('initial')
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        self.state = self.root / '.ai/desktop'
        self.sdk = {'frameworkVersion': 'test', 'engineRevision': 'a'}
        self.builds = 0

    def tearDown(self):
        self.temporary.cleanup()

    def build(self, root, state, files, flutter, env):
        self.builds += 1
        bundle = state / 'test-bundle'
        bundle.mkdir(exist_ok=True)
        executable = bundle / 'open_ecad'
        executable.write_bytes(files['lib/main.dart'])
        executable.chmod(0o755)
        return bundle

    def current(self):
        with patch.object(desktop, 'notify'), patch.object(desktop, 'build_snapshot', self.build):
            return desktop.ensure_current(self.root, self.state, Path('/flutter'), self.sdk, {})

    def test_content_changes_rebuild_without_replacing_running_binary(self):
        first = self.current()
        self.assertEqual(self.current(), first)
        self.assertEqual(self.builds, 1)
        source = self.root / 'lib/main.dart'
        stat = source.stat()
        source.write_text('changed')
        os.utime(source, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        second = self.current()
        self.assertNotEqual(first, second)
        self.assertEqual(first.read_text(), 'initial')
        self.assertEqual(second.read_text(), 'changed')
        self.assertEqual((self.state / 'current').resolve(), second.parent)

    def test_added_deleted_files_and_sdk_changes_rebuild(self):
        first = self.current()
        extra = self.root / 'lib/extra.dart'
        extra.write_text('new file')
        second = self.current()
        self.assertNotEqual(first, second)
        extra.unlink()
        self.assertEqual(self.current(), first)
        self.sdk['engineRevision'] = 'b'
        self.assertNotEqual(self.current(), first)

    def test_failure_keeps_previous_release_and_does_not_return_it(self):
        first = self.current()
        (self.root / 'lib/main.dart').write_text('broken')
        with patch.object(desktop, 'notify'), patch.object(
            desktop, 'build_snapshot', side_effect=RuntimeError('Build failed'),
        ):
            with self.assertRaisesRegex(RuntimeError, 'Build failed'):
                desktop.ensure_current(self.root, self.state, Path('/flutter'), self.sdk, {})
        self.assertEqual((self.state / 'current').resolve(), first.parent)
        self.assertEqual(first.read_text(), 'initial')

    def test_edit_during_build_is_not_published_as_current(self):
        original = self.build

        def changing_build(*args):
            result = original(*args)
            if self.builds == 1:
                (self.root / 'lib/main.dart').write_text('newest')
            return result

        with patch.object(desktop, 'notify'), patch.object(desktop, 'build_snapshot', changing_build):
            binary = desktop.ensure_current(self.root, self.state, Path('/flutter'), self.sdk, {})
        self.assertEqual(self.builds, 2)
        self.assertEqual(binary.read_text(), 'newest')

    def test_private_files_are_never_build_inputs(self):
        for name in ('private/house.oecad', '.ai/house.pdf', 'test/house.oecad'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('PRIVATE')
        inputs = desktop.source_snapshot(self.root)
        self.assertNotIn(b'PRIVATE', inputs.values())
        (self.root / 'assets').mkdir()
        (self.root / 'assets/house.oecad').write_text('PRIVATE')
        with self.assertRaisesRegex(RuntimeError, 'Soukromý'):
            desktop.source_snapshot(self.root)
        (self.root / 'assets/house.oecad').unlink()
        (self.root / 'lib/link.dart').symlink_to(self.root / 'private/house.oecad')
        with self.assertRaisesRegex(RuntimeError, 'Odkaz'):
            desktop.source_snapshot(self.root)

    def test_install_handles_spaces_and_refuses_an_unrelated_launcher(self):
        brand = self.root / 'assets/brand'
        brand.mkdir(parents=True)
        shutil.copyfile(ROOT / 'assets/brand/open-ecad.svg', brand / 'open-ecad.svg')
        target = self.root / 'scripts/linux_desktop.py'
        shutil.copyfile(ROOT / 'scripts/linux_desktop.py', target)
        target.chmod(0o755)
        prefix = self.root / 'local install'
        with patch.object(desktop.subprocess, 'run'):
            entry = desktop.install(self.root, prefix)
        self.assertIn(desktop.desktop_quote(str(prefix / 'bin/open-ecad')), entry.read_text())
        self.assertTrue((prefix / 'bin/open-ecad').is_symlink())
        if shutil.which('desktop-file-validate'):
            subprocess.run(['desktop-file-validate', str(entry)], check=True)
        (prefix / 'bin/open-ecad').unlink()
        (prefix / 'bin/open-ecad').write_text('other app')
        with self.assertRaisesRegex(RuntimeError, 'jiné instalaci'):
            desktop.install(self.root, prefix)


if __name__ == '__main__':
    unittest.main()
