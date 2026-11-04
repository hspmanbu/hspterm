"""Source-only tests; run with the final unified checks, not during coding."""
import base64
import hashlib
import importlib.util
from pathlib import Path
import shlex
import subprocess
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'crates/ssh-core/src/direct_transfer/probe.py'
spec = importlib.util.spec_from_file_location('direct_probe_under_test', SOURCE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class DirectTransferProbeTests(unittest.TestCase):
    def setUp(self):
        # Synthetic public wire-shaped material, never a private key or account.
        self.public = b'synthetic-test-public-key-wire-data'
        self.key = base64.b64encode(self.public).decode()
        self.digest = 'SHA256:' + base64.b64encode(hashlib.sha256(self.public).digest()).decode().rstrip('=')
        self.endpoint = {'version': 1, 'address': '::1', 'port': 2222,
                         'username': "synthetic' $(unsafe); user", 'fingerprint': self.digest,
                         'algorithm': 'ssh-ed25519'}

    def verifier(self, reason, digest, public):
        return subprocess.run([sys.executable, '-I', '-S', '-c',
                               probe.known_hosts_program(self.digest), reason,
                               digest, 'ssh-ed25519', public], capture_output=True)

    def test_original_fingerprint_is_recomputed_and_mismatch_never_emits_trust(self):
        accepted = self.verifier('HOSTNAME', self.digest, self.key)
        self.assertEqual(accepted.returncode, 0)
        self.assertEqual(accepted.stdout.decode(), 'hspterm-direct-target ssh-ed25519 ' + self.key + '\n')
        changed = base64.b64encode(self.public + b'changed').decode()
        for digest, key in [(self.digest, changed), ('SHA256:wrong', self.key)]:
            rejected = self.verifier('HOSTNAME', digest, key)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(rejected.stdout, b'')
        ordering = self.verifier('ORDER', 'NONE', 'NONE')
        self.assertEqual(ordering.returncode, 0)
        self.assertEqual(ordering.stdout, b'')

    def test_ssh_argv_disables_external_configuration_and_never_interpolates_username(self):
        argv = probe.ssh_arguments(self.endpoint, '/usr/bin/ssh', '/usr/bin/python3')
        self.assertEqual(argv[:4], ['/usr/bin/ssh', '-F', '/dev/null', '-T'])
        self.assertEqual(argv[-6:-1], ['2222', '-l', self.endpoint['username'], '--', '::1'])
        self.assertTrue(argv[-1].startswith('/usr/bin/python3 -I -S -c '))
        self.assertNotIn(self.endpoint['username'], argv[-1])
        for option in ['StrictHostKeyChecking=yes', 'IdentityFile=none',
                       'UserKnownHostsFile=/dev/null', 'GlobalKnownHostsFile=/dev/null',
                       'IdentityAgent=SSH_AUTH_SOCK', 'PreferredAuthentications=publickey',
                       'ForwardAgent=no', 'ProxyCommand=none', 'ControlPath=none']:
            self.assertIn(option, argv)
        verifier = next(arg.split('=', 1)[1] for arg in argv if arg.startswith('KnownHostsCommand='))
        self.assertEqual(shlex.split(verifier), ['/usr/bin/python3', '-I', '-S', '-c',
                                               probe.known_hosts_program(self.digest), '%I', '%f', '%t', '%K'])
        self.assertNotIn(self.endpoint['username'], verifier)
        rsa = dict(self.endpoint, algorithm='ssh-rsa')
        self.assertIn('HostKeyAlgorithms=rsa-sha2-512,rsa-sha2-256',
                      probe.ssh_arguments(rsa, '/usr/bin/ssh', '/usr/bin/python3'))


if __name__ == '__main__':
    unittest.main()
