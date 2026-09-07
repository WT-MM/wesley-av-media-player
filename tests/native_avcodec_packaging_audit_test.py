"""Exercise the audit against compiled Mach-O bundles, without Homebrew inputs."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import native_avcodec_packaging_audit as audit


class PackagingAuditTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='wam-bundle-audit-', dir='/private/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.app = self.root / 'Relocated.app'
        self.exe = self.app / 'Contents/MacOS/WAM'
        self.exe.parent.mkdir(parents=True)
        self.frameworks = self.app / 'Contents/Frameworks'
        self.frameworks.mkdir()
        self.compile(self.exe, '13.3')
        for name in audit.NATIVE_NAMES:
            shutil.copyfile(self.exe, self.frameworks / name)
        notices = self.app / 'Contents/Resources/native-ffmpeg'
        notices.mkdir(parents=True)
        for name in audit.NOTICES:
            (notices / name).write_text('test notice')

    def compile(self, destination, floor):
        source = self.root / 'source.c'
        source.write_text('int test_symbol(void) { return 0; }\n')
        subprocess.run(['/usr/bin/clang', '-target', 'arm64-apple-macos' + floor,
                        '-dynamiclib', str(source), '-o', str(destination)],
                       capture_output=True, check=True)

    def test_clean_13_3_closure_and_high_floor_plugin(self):
        self.assertTrue(audit.audit(self.app)['clean_machine_ready'])
        plugin = self.app / 'Contents/PlugIns/late.dylib'
        plugin.parent.mkdir()
        self.compile(plugin, '26.0')
        result = audit.audit(self.app)
        self.assertFalse(result['clean_machine_ready'])
        self.assertFalse(result['bundled_floor_13_3_pass'])
        self.assertEqual([row['minos'] for row in result['bundled_machos'] if row['path'] == str(plugin)], [['26.0']])
        self.assertTrue(result['closure_relocatable'])

    def test_external_symlink_is_never_inspected(self):
        outside = self.root / 'homebrew-input.dylib'
        self.compile(outside, '26.0')
        (self.frameworks / 'escape.dylib').symlink_to(outside)
        inspect = audit.inspect
        def bundled_only(path):
            self.assertTrue(path.is_relative_to(self.app))
            return inspect(path)
        with patch.object(audit, 'inspect', bundled_only):
            result = audit.audit(self.app)
        self.assertTrue(result['bundled_floor_13_3_pass'])
        self.assertFalse(result['closure_relocatable'])
        self.assertTrue(any('BundlePathEscapes' in value for value in result['errors']))

    def test_missing_lazy_library_and_notices_fail_closed(self):
        (self.frameworks / audit.NATIVE_NAMES[0]).unlink()
        result = audit.audit(self.app)
        self.assertFalse(result['clean_machine_ready'])
        shutil.copyfile(self.exe, self.frameworks / audit.NATIVE_NAMES[0])
        (self.app / 'Contents/Resources/native-ffmpeg/LICENSE.md').unlink()
        self.assertFalse(audit.audit(self.app)['clean_machine_ready'])

    def test_eager_native_dependency_fails_closed(self):
        source = self.root / 'main.c'
        source.write_text('extern int test_symbol(void); int main(void) { return test_symbol(); }\n')
        library = self.frameworks / audit.NATIVE_NAMES[0]
        subprocess.run(['/usr/bin/install_name_tool', '-id', '@executable_path/../Frameworks/' + library.name, str(library)], check=True, capture_output=True)
        subprocess.run(['/usr/bin/clang', '-target', 'arm64-apple-macos13.3', str(source), str(library), '-o', str(self.exe)], check=True, capture_output=True)
        result = audit.audit(self.app)
        self.assertTrue(result['eager_native_ffmpeg'])
        self.assertTrue(result['closure_relocatable'])
        self.assertFalse(result['clean_machine_ready'])


if __name__ == '__main__':
    unittest.main()
