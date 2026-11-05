"""Run the actual fixed helper validator without sourcing user startup files."""
from pathlib import Path
import subprocess
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'crates/ssh-core/src/integration/bash.bash'

class BashInputValidationTests(unittest.TestCase):
    def test_hex_decoder_accepts_hyphens_unicode_quotes_and_rejects_every_control(self):
        source = SOURCE.read_text()
        decoder = source[source.index('__hspterm_decode() {'):source.index('__hspterm_emit() {')]
        cases = [('cd -- "/中文 space/has-hyphen"', True)]
        cases += [('left' + chr(code) + 'right', False) for code in [*range(1, 32), 127]]
        cases.append(('nul\x00reject', False))
        for value, accepted in cases:
            with self.subTest(value=repr(value)):
                result = subprocess.run(['bash', '--noprofile', '--norc', '-c',
                    decoder + '\n__hspterm_decode "$1"', 'fixture', value.encode().hex()],
                    env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, capture_output=True, timeout=2)
                self.assertEqual(result.returncode == 0, accepted)
                self.assertEqual(result.stdout, b'')

if __name__ == '__main__': unittest.main()
