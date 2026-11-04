"""Private filesystem capability tests; source only until unified validation."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RECEIVER = Path(__file__).resolve().parents[2] / 'crates/ssh-core/src/direct_transfer/receiver.py'
RUNNER = "import pathlib,sys; p=pathlib.Path(sys.argv[1]);g={'__name__':'fixture'};exec(compile((p.parent/'receipt.py').read_text()+'\\n'+p.read_text(),str(p),'exec'),g);g['shutil'].which=lambda *a,**k:'/bin/false';sys.argv=['fixture',sys.argv[2],'--server'];sys.exit(g['main']())"


class ReceiverCapabilityTests(unittest.TestCase):
    def attempt(self, path, nonce, size=0, attempt=1, previous=None):
        payload = base64.b64encode(json.dumps({'staged': str(path), 'bytes': size,
            'nonce': base64.b64encode(nonce).decode(), 'attempt': attempt, 'previous': previous}).encode()).decode()
        return subprocess.run([sys.executable, '-I', '-S', '-c', RUNNER,
            str(RECEIVER), payload], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_wrong_capability_and_nonprivate_mode_do_not_truncate_existing_data(self):
        with tempfile.TemporaryDirectory(prefix='hspterm-receiver-fixture-') as directory:
            path = Path(directory) / '.hspterm-copy-0123456789abcdef0123456789abcdef-0.part'
            marker = b's' * 32
            path.write_bytes(marker)
            path.chmod(0o600)
            self.assertNotEqual(self.attempt(path, b'x' * 32).returncode, 0)
            self.assertEqual(path.read_bytes(), marker)
            path.chmod(0o644)
            self.assertNotEqual(self.attempt(path, marker).returncode, 0)
            self.assertEqual(path.read_bytes(), marker)

    def test_missing_marker_or_final_symlink_cannot_create_or_modify_another_file(self):
        with tempfile.TemporaryDirectory(prefix='hspterm-receiver-fixture-') as directory:
            path = Path(directory) / '.hspterm-copy-0123456789abcdef0123456789abcdef-0.part'
            self.assertNotEqual(self.attempt(path, b'x' * 32).returncode, 0)
            self.assertFalse(path.exists())
            protected = Path(directory) / 'protected-fixture'
            protected.write_bytes(b'x' * 32)
            path.symlink_to(protected)
            self.assertNotEqual(self.attempt(path, b'x' * 32).returncode, 0)
            self.assertEqual(protected.read_bytes(), b'x' * 32)
            self.assertTrue(path.is_symlink())


    def inspect(self, path, nonce, size):
        namespace = {'__name__': 'fixture'}
        exec(compile((RECEIVER.parent / 'receipt.py').read_text() + '\n' +
            (RECEIVER.parent / 'inspect.py').read_text(), '<fixture-receipt>', 'exec'), namespace)
        return namespace['inspect']({'staged': str(path), 'bytes': size,
            'nonce': base64.b64encode(nonce).decode()})

    def test_valid_claim_partial_delta_resume_and_stale_attempt_rejection(self):
        # /bin/false is a controlled failed rsync: no network or account use.
        with tempfile.TemporaryDirectory(prefix='hspterm-receipt-fixture-') as directory:
            path = Path(directory) / '.hspterm-copy-0123456789abcdef0123456789abcdef-0.part'
            nonce = b's' * 32
            path.write_bytes(nonce)
            path.chmod(0o600)
            self.assertNotEqual(self.attempt(path, nonce, size=10).returncode, 0)
            # Positive control: correct capability really ran claim/truncate,
            # rather than a missing import making every negative test "pass".
            self.assertEqual(path.read_bytes(), b'')
            self.assertNotIn(nonce, os.getxattr(path, 'user.hspterm.direct.v1'))
            path.write_bytes(b'part')
            self.assertEqual(self.inspect(path, nonce, 10)['status'], 'partial')
            self.assertNotEqual(self.attempt(path, nonce, size=10, attempt=2, previous=1).returncode, 0)
            self.assertEqual(path.read_bytes(), b'part')
            self.assertEqual(self.inspect(path, nonce, 10)['attempt'], 2)
            self.assertNotEqual(self.attempt(path, nonce, size=10, attempt=1).returncode, 0)
            self.assertEqual(path.read_bytes(), b'part')
            self.assertEqual(self.inspect(path, b'x' * 32, 10)['status'], 'unavailable')
            # File length alone must never manufacture a completed receipt.
            path.write_bytes(b'0123456789')
            self.assertEqual(self.inspect(path, nonce, 10)['status'], 'partial')

    def test_tampered_receipt_and_live_writer_do_not_allow_reuse(self):
        with tempfile.TemporaryDirectory(prefix='hspterm-receipt-fixture-') as directory:
            path = Path(directory) / '.hspterm-copy-0123456789abcdef0123456789abcdef-0.part'
            nonce = b's' * 32
            path.write_bytes(nonce)
            path.chmod(0o600)
            self.attempt(path, nonce, size=10)
            path.write_bytes(b'0123456789')
            self.assertEqual(self.inspect(path, nonce, 10)['status'], 'partial')
            raw = os.getxattr(path, 'user.hspterm.direct.v1')
            record = json.loads(raw)
            record['state'] = 'complete'
            os.setxattr(path, 'user.hspterm.direct.v1', json.dumps(record).encode())
            self.assertEqual(self.inspect(path, nonce, 10)['status'], 'unavailable')
            os.setxattr(path, 'user.hspterm.direct.v1', raw)
            import fcntl
            with path.open('r+b') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertNotEqual(self.attempt(path, nonce, size=10, attempt=2, previous=1).returncode, 0)
            self.assertEqual(path.read_bytes(), b'0123456789')

    def test_empty_success_receipt_and_unknown_process_gap_are_distinct(self):
        with tempfile.TemporaryDirectory(prefix='hspterm-receipt-fixture-') as directory:
            path = Path(directory) / '.hspterm-copy-0123456789abcdef0123456789abcdef-0.part'
            nonce = b's' * 32
            path.write_bytes(nonce)
            path.chmod(0o600)
            payload = base64.b64encode(json.dumps({'staged': str(path), 'bytes': 0,
                'nonce': base64.b64encode(nonce).decode(), 'attempt': 1, 'previous': None}).encode()).decode()
            successful = RUNNER.replace("'/bin/false'", "'/bin/true'")
            result = subprocess.run([sys.executable, '-I', '-S', '-c', successful,
                str(RECEIVER), payload], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), b'')
            self.assertEqual(self.inspect(path, nonce, 0)['status'], 'complete')
            # Reproduce only the authenticated crash-gap metadata, no process
            # is sent a signal. Unknown pgid must remain busy, never resumable.
            namespace = {'__name__': 'fixture'}
            exec(compile((RECEIVER.parent / 'receipt.py').read_text(), '<fixture-receipt>', 'exec'), namespace)
            with path.open('r+b') as held:
                record = namespace['read_record'](held.fileno())
                record.update(state='writing', pgid=0)
                namespace['write_record'](held.fileno(), record, nonce)
            self.assertEqual(self.inspect(path, nonce, 0)['status'], 'busy')
            self.assertNotEqual(self.attempt(path, nonce, attempt=2, previous=1).returncode, 0)


if __name__ == '__main__':
    unittest.main()
