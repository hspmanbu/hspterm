"""Synthetic task-authentication protocol tests; no accounts or SSH servers.

Not run by the build-only Windows CI; execute explicitly when runtime validation
is requested. Production sends only a random task capability on exec stdin.
"""
import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

DIRECT = Path(__file__).resolve().parents[2] / 'crates/ssh-core/src/direct_transfer'


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, DIRECT / file)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


class TaskAuthenticationTests(unittest.TestCase):
    def test_password_askpass_uses_private_broker_not_argv_environment_or_files(self):
        if not hasattr(socket, 'AF_UNIX') or os.name != 'posix':
            self.skipTest('source-side helper runs on a POSIX SSH server')
        auth = module('direct_auth_test', 'auth.py')
        token = b'T' * 32
        password = b'synthetic-test-only-password'
        with tempfile.TemporaryDirectory() as directory:
            original = str(Path(directory) / 'original')
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(original)
            server.listen(1)
            server.settimeout(5)
            errors = []

            def reply():
                try:
                    stream, _ = server.accept()
                    with stream:
                        stream.settimeout(5)
                        request = auth._frame(stream)
                        name = b'hspterm-direct-auth-v1'
                        self.assertEqual(request, b'\x1b' + struct.pack('!I', len(name))
                                         + name + struct.pack('!I', 32) + token)
                        response = b'\x06' + struct.pack('!I', len(password)) + password
                        stream.sendall(struct.pack('!I', len(response)) + response)
                except BaseException as error:
                    errors.append(error)

            worker = threading.Thread(target=reply, daemon=True)
            worker.start()
            broker = auth._TaskAuthentication(1, token, original, sys.executable)
            try:
                helper = Path(broker.helper)
                self.assertEqual(stat.S_IMODE(helper.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(Path(broker.path).stat().st_mode), 0o600)
                self.assertNotIn(password, helper.read_bytes())
                self.assertNotIn(token, helper.read_bytes())
                environment = {'PATH': os.defpath, 'HSPTERM_DIRECT_AUTH_SOCKET': broker.path}
                self.assertNotIn(password.decode(), repr(environment))
                result = subprocess.run([str(helper)], env=environment, capture_output=True,
                                        timeout=5, check=False)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, password + b'\n')
                self.assertEqual(result.stderr, b'')
            finally:
                broker.close()
                server.close()
                worker.join(timeout=6)
            self.assertFalse(worker.is_alive())
            self.assertFalse(errors, repr(errors))
            self.assertFalse(helper.exists())
            self.assertFalse(Path(broker.path).exists())

    def test_password_mode_preserves_pin_and_disables_keys_agent_forwarding_and_shell(self):
        probe = module('direct_probe_auth_test', 'probe.py')
        probe.authentication_password = lambda: True
        endpoint = {'address': '127.0.0.1', 'port': 2222, 'username': 'fixture',
                    'fingerprint': 'SHA256:' + base64.b64encode(hashlib.sha256(b'public').digest()).decode().rstrip('='),
                    'algorithm': 'ssh-ed25519'}
        argv = probe.ssh_arguments(endpoint, '/usr/bin/ssh', '/usr/bin/python3')
        for option in ['BatchMode=no', 'NumberOfPasswordPrompts=1',
                       'PreferredAuthentications=password', 'PubkeyAuthentication=no',
                       'StrictHostKeyChecking=yes', 'ForwardAgent=no',
                       'IdentityFile=none', 'ProxyCommand=none']:
            self.assertIn(option, argv)
        self.assertIn('-T', argv)
        self.assertNotIn('StrictHostKeyChecking=no', argv)


if __name__ == '__main__':
    unittest.main()
