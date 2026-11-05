import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'crates/ssh-core/src/inspection/server_copy.py'

class ServerCopyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hspterm-server-copy-')
        self.root = Path(self.temp.name)
        self.marker = self.root / 'namespace-proof'
        self.marker.write_bytes(bytes(32))
    def tearDown(self): self.temp.cleanup()
    def copy(self, source, target, nonce='00' * 32):
        st = source.lstat()
        request = dict(source=str(source), destination=str(target), marker=str(self.marker), nonce=nonce,
                       metadata=dict(size=st.st_size, mtime=int(st.st_mtime), permissions=st.st_mode, uid=st.st_uid, gid=st.st_gid))
        return subprocess.run([sys.executable, '-I', '-S', str(SCRIPT), json.dumps(request).encode().hex()], capture_output=True, timeout=5)
    def test_tree_unicode_quotes_and_symlinks_are_copied_on_server_without_following(self):
        source = self.root / "source ' $; 中文"
        source.mkdir()
        (source / 'empty').mkdir()
        body = b'synthetic-server-only' * 9000
        (source / "payload ' 中文").write_bytes(body)
        outside = self.root / 'outside'
        outside.write_bytes(b'do not copy through the symlink')
        (source / 'link').symlink_to(outside)
        target = self.root / 'copy'
        result = self.copy(source, target)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, b"\nHSPTERM_SERVER_COPY_V1_" + b"00" * 32 + b"\n")
        self.assertEqual((target / "payload ' 中文").read_bytes(), body)
        self.assertTrue((target / 'empty').is_dir())
        self.assertTrue((target / 'link').is_symlink())
        self.assertEqual(os.readlink(target / 'link'), str(outside))
    def test_existing_destination_is_never_overwritten(self):
        source, target = self.root / 'from', self.root / 'to'
        source.write_bytes(b'new'); target.write_bytes(b'original')
        self.assertNotEqual(self.copy(source, target).returncode, 0)
        self.assertEqual(target.read_bytes(), b'original')
    def test_wrong_namespace_and_descendant_target_are_rejected(self):
        source = self.root / 'source'; source.mkdir()
        target = self.root / 'to'
        self.assertNotEqual(self.copy(source, target, '11' * 32).returncode, 0)
        self.assertFalse(target.exists())
        self.assertNotEqual(self.copy(source, source / 'inside').returncode, 0)
        self.assertFalse((source / 'inside').exists())

if __name__ == '__main__': unittest.main()
