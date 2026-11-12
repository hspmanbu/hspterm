"""CI protocol tests; no SSH credentials or real tmux server required."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('tmux_history', Path(__file__).with_name('tmux_history.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class HistoryTests(unittest.TestCase):
    def invoke(self, extra=None, snapshots=None):
        request = dict(id='$2', server_pid=123, created=456, readonly=False)
        request.update(extra or {})
        lines = iter(snapshots or ['123|456|%3|80|0|24||100'])
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            self.assertNotIn('shell', kwargs)
            self.assertEqual(argv[0], 'tmux')
            value = next(lines) if argv[1] == 'display-message' else ''
            return subprocess.CompletedProcess(argv, 0, value.encode())

        output = io.StringIO()
        with patch.object(module.sys, 'argv', ['probe', json.dumps(request).encode().hex()]), \
                patch.object(module.subprocess, 'run', run), contextlib.redirect_stdout(output):
            module.main()
        return json.loads(output.getvalue()), calls

    def test_bounded_snapshot(self):
        result, calls = self.invoke()
        self.assertEqual(result['history'], 80)
        self.assertEqual(result['offset'], 0)
        self.assertEqual(len(calls), 1)

    def test_seek_clamps_to_retained_history_and_guards_identity(self):
        result, calls = self.invoke(dict(pane='%3', offset=9999),
                                   ['123|456|%3|80|0|24||100', '123|456|%3|80|80|24|copy-mode|100'])
        action = calls[1]
        self.assertEqual(action[1:5], ['if-shell', '-F', '-t', '$2:'])
        self.assertIn('#{pane_id},%3', action[5])
        self.assertIn('history-top', action[6])
        self.assertNotIn('9999', action[6])
        self.assertEqual(result['offset'], 80)

    def test_scroll_down_count_and_bottom_cancel(self):
        _, calls = self.invoke(dict(pane='%3', offset=30),
                               ['123|456|%3|80|0|24||100', '123|456|%3|80|30|24|copy-mode|100'])
        self.assertIn('-N 50 scroll-down', calls[1][6])
        _, calls = self.invoke(dict(pane='%3', offset=0),
                               ['123|456|%3|80|30|24|copy-mode|100', '123|456|%3|80|0|24||100'])
        self.assertEqual(calls[1][6], 'send-keys -t %3 -X cancel')

    def test_refuses_restarted_server_changed_pane_readonly_and_other_modes(self):
        for extra, line in [
            ({}, '999|456|%3|80|0|24||100'),
            (dict(pane='%4', offset=10), '123|456|%3|80|0|24||100'),
            (dict(pane='%3', offset=10, readonly=True), '123|456|%3|80|0|24||100'),
            (dict(pane='%3', offset=10), '123|456|%3|80|0|24|tree-mode|100'),
            ({}, '123|456|%3|101|0|24||100'),
        ]:
            with self.subTest(extra=extra, line=line), self.assertRaises(ValueError):
                self.invoke(extra, [line])


if __name__ == '__main__':
    unittest.main()
