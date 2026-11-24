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
            if argv[1] == 'display-message' and value.count('|') == 7: value += '|bash'
            return subprocess.CompletedProcess(argv, 0, value.encode())

        output = io.StringIO()
        with patch.object(module.sys, 'argv', ['probe', json.dumps(request).encode().hex()]), \
                patch.object(module.subprocess, 'run', run), contextlib.redirect_stdout(output):
            module.main()
        return json.loads(output.getvalue()), calls

    def test_non_mouse_pointer_uses_guarded_bounded_arrow_keys(self):
        click = dict(column=8, row=3, cursor_column=5, cursor_row=3, steps=2)
        result, calls = self.invoke(dict(pane='%3', click=click),
            ['123|456|%3|80|0|24||100', '%3|0|0|80|24|5|3|1|0|0'])
        self.assertEqual(result, dict(pointer='handled'))
        self.assertEqual(calls[-1][-2], 'send-keys -t %3 -N 2 Right')
        self.assertIn('#{mouse_any_flag},0', calls[-1][-3])
        self.assertIn('#{cursor_x},5', calls[-1][-3])
        self.assertIn('#{pane_id},%3', calls[-1][-3])
        self.assertIn('#{session_created},456', calls[-1][-3])

    def test_cross_row_direction_uses_the_row_before_the_column(self):
        for click, key in [
            (dict(column=1, row=4, cursor_column=5, cursor_row=3, steps=20), 'Right'),
            (dict(column=12, row=2, cursor_column=5, cursor_row=3, steps=20), 'Left'),
        ]:
            result, calls = self.invoke(dict(pane='%3', click=click),
                ['123|456|%3|80|0|24||100', '%3|0|0|80|24|5|3|1|0|0'])
            self.assertEqual(result, dict(pointer='handled'))
            self.assertEqual(calls[-1][-2], 'send-keys -t %3 -N 20 ' + key)

    def test_native_mouse_routes_to_application_without_injecting_keys(self):
        click = dict(column=8, row=10, cursor_column=5, cursor_row=3, steps=0)
        result, calls = self.invoke(dict(pane='%3', click=click),
            ['123|456|%3|80|0|24||100', '%3|0|0|80|24|5|3|1|1|0'])
        self.assertEqual(result, dict(pointer='mouse'))
        self.assertEqual(len(calls), 2)

    def test_pointer_refuses_readonly_modes_stale_cursor_pane_and_geometry(self):
        original = dict(column=8, row=3, cursor_column=5, cursor_row=3, steps=2)
        for extra, pane, change in [
            ({'readonly': True}, '%3|0|0|80|24|5|3|1|0|0', {}),
            ({}, '%4|0|0|80|24|5|3|1|0|0', {}),
            ({}, '%3|0|0|80|24|6|3|1|0|0', {}),
            ({}, '%3|0|0|80|24|5|3|0|0|0', {}),
            ({}, '%3|0|0|80|24|5|3|1|0|1', {}),
            ({}, '%3|0|0|80|24|5|3|1|0|0', {'row': 24}),
            ({}, '%3|0|0|80|24|5|3|1|0|0', {'steps': 99}),
        ]:
            request = dict(pane='%3', click=dict(original, **change), **extra)
            result, calls = self.invoke(request, ['123|456|%3|80|0|24||100', pane])
            self.assertEqual(result, dict(pointer='ignored'))
            self.assertFalse(any(c[1] == 'if-shell' for c in calls))

    def test_pointer_rejects_unbounded_or_non_integer_parameters(self):
        for value in [True, -1, 65536, '3; display-message unsafe']:
            click = dict(column=8, row=3, cursor_column=5, cursor_row=3, steps=value)
            with self.assertRaises(ValueError):
                self.invoke(dict(pane='%3', click=click))

    def test_bounded_snapshot(self):
        result, calls = self.invoke()
        self.assertEqual(result['history'], 80)
        self.assertEqual(result['offset'], 0)
        self.assertEqual(len(calls), 1)

    def test_shell_metadata_is_name_only_and_never_enables_input_trust(self):
        for command, expected in [('bash', True), ('zsh', True), ('codex', False), ('python3', False)]:
            result, calls = self.invoke(snapshots=['123|456|%3|80|0|24||100|' + command])
            self.assertEqual(result['shell'], expected)
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
