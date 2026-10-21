from pathlib import Path
import importlib.util,tempfile,unittest
from types import SimpleNamespace
from unittest.mock import patch

module_path=Path(__file__).parents[1]/'scripts/verify_macos_runtime.py'
spec=importlib.util.spec_from_file_location('runtime_verify',module_path)
verify=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify)

class RuntimeVerificationTests(unittest.TestCase):
    def fixture(self,folder):
        root=Path(folder)/'runtime'
        for name in ('bin/ffmpeg','bin/ffprobe','lib/libmpv.2.dylib','lib/libavcodec.dylib'):
            p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'fake Mach-O')
        return root

    def errors(self,root,deps=()):
        def run(cmd,**kwargs):
            if cmd[0]=='file':
                return SimpleNamespace(stdout='Mach-O 64-bit dynamically linked shared library')
            return SimpleNamespace(stdout=cmd[-1]+':\n'+''.join('\t'+dep+' (compatibility version 1.0)\n' for dep in deps))
        with patch.object(verify.subprocess,'run',side_effect=run),patch.object(verify.os,'access',return_value=True):
            return verify.verify(root)

    def test_reject_missing_runtime(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertTrue(verify.verify(Path(folder)/'missing'))

    def test_complete_runtime_and_system_or_bundled_libraries(self):
        with tempfile.TemporaryDirectory() as folder:
            root=self.fixture(folder)
            self.assertFalse(self.errors(root,('/usr/lib/libSystem.B.dylib','@rpath/libavcodec.dylib')))
            self.assertFalse(self.errors(root,('@loader_path/../lib/libavcodec.dylib',)))

    def test_reject_external_or_unresolved_dependency(self):
        with tempfile.TemporaryDirectory() as folder:
            root=self.fixture(folder)
            for dep in ('/opt/homebrew/lib/private.dylib','@rpath/absent.dylib'):
                self.assertTrue(self.errors(root,(dep,)))

    def test_reject_rpath_traversal_outside_runtime(self):
        with tempfile.TemporaryDirectory() as folder:
            root=self.fixture(folder);(Path(folder)/'outside.dylib').write_bytes(b'outside')
            self.assertTrue(self.errors(root,('@rpath/../../outside.dylib',)))

    def test_reject_missing_required_tool(self):
        with tempfile.TemporaryDirectory() as folder:
            root=self.fixture(folder);(root/'bin/ffprobe').unlink()
            self.assertTrue(self.errors(root))

if __name__=='__main__':
    unittest.main(verbosity=2)
