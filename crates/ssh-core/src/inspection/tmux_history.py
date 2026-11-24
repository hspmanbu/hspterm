"""Bounded tmux viewport/navigation and explicit guarded clicks; never read user text."""
import json
import re
import subprocess
import sys


def run(*args):
    return subprocess.run(['tmux', *args], check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=3).stdout.decode('utf-8', 'replace').strip()


def click_cursor(request, target, pane, mode):
    click = request['click']
    keys = {'column', 'row', 'cursor_column', 'cursor_row', 'steps'}
    if (not isinstance(click, dict) or set(click) != keys
            or any(type(click[k]) is not int or not 0 <= click[k] <= 65535 for k in keys)):
        raise ValueError('click')
    if request.get('readonly') or request.get('pane') != pane or mode != '':
        return 'ignored'
    fmt = '#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{cursor_x}|#{cursor_y}|#{cursor_flag}|#{mouse_any_flag}|#{pane_in_mode}'
    fields = run('display-message', '-p', '-t', target, fmt).split('|')
    if len(fields) != 10 or fields[0] != pane:
        return 'ignored'
    left, top, width, height, cx, cy, cursor, mouse, in_mode = map(int, fields[1:])
    if (not (0 <= left <= 65535 and 0 <= top <= 65535
             and 1 <= width <= 65535 and 1 <= height <= 65535
             and 0 <= cx < width and 0 <= cy < height)
            or cursor not in (0, 1) or mouse not in (0, 1) or in_mode not in (0, 1)):
        raise ValueError('pane geometry')
    if in_mode:
        return 'ignored'
    # Query the inner application, never infer support from tmux's outer mouse
    # mode, command names, or a speculative synthetic click sent to the shell.
    if mouse:
        return 'mouse'
    x, y, expected_x, expected_y, steps = [click[k] for k in
        ('column', 'row', 'cursor_column', 'cursor_row', 'steps')]
    if (not cursor or y != expected_y or expected_y != top + cy
            or expected_x != left + cx or not left <= x < left + width
            or not 0 < steps <= abs(x - expected_x) <= width):
        return 'ignored'
    def both(a, b):
        return '#{&&:%s,%s}' % (a, b)
    checks = [('pid', request['server_pid']), ('session_created', request['created']),
              ('pane_id', pane), ('pane_left', left), ('pane_top', top),
              ('pane_width', width), ('pane_height', height),
              ('cursor_x', cx), ('cursor_y', cy), ('cursor_flag', 1),
              ('mouse_any_flag', 0), ('pane_in_mode', 0)]
    condition = '1'
    for key, value in checks:
        condition = both(condition, '#{==:#{%s},%s}' % (key, value))
    # Atomic tmux-queue guard: a pane switch, program mouse-mode change,
    # resize or cursor change cancels the move. Never replay an unknown ACK.
    action = 'send-keys -t %s -N %d %s' % (pane, steps, 'Right' if x > expected_x else 'Left')
    run('if-shell', '-F', '-t', target, condition, action, '')
    return 'handled'


def main():
    request = json.loads(bytes.fromhex(sys.argv[1]))
    sid, pid, created = request['id'], request['server_pid'], request['created']
    if not re.fullmatch(r'\$[0-9]{1,12}', sid) or not isinstance(pid, int) or pid <= 0:
        raise ValueError('identity')
    target = sid + ':'
    fmt = '#{pid}|#{session_created}|#{pane_id}|#{history_size}|#{scroll_position}|#{pane_height}|#{pane_mode}|#{history_limit}|#{pane_current_command}'

    def snapshot():
        fields = run('display-message', '-p', '-t', target, fmt).split('|')
        if len(fields) != 9 or fields[0] != str(pid) or fields[1] != str(created):
            raise ValueError('stale session')
        pane, mode = fields[2], fields[6]
        if not re.fullmatch(r'%[0-9]{1,12}', pane):
            raise ValueError('pane')
        history, offset, height, limit = [int(fields[i] or '0') for i in (3, 4, 5, 7)]
        if not (0 <= history <= limit <= 10_000_000 and 1 <= height <= 65535 and 0 <= offset <= history):
            raise ValueError('bounds')
        return pane, mode, history, offset, height, mode == '' and fields[8] in ('bash', 'sh', 'zsh', 'fish', 'dash', 'ksh', 'ash')

    pane, mode, history, offset, height, shell = snapshot()
    if request.get('click') is not None:
        if request.get('offset') is not None:
            raise ValueError('mixed operation')
        print(json.dumps(dict(pointer=click_cursor(request, target, pane, mode))))
        return
    wanted = request.get('offset')
    if wanted is not None:
        if request.get('readonly') or request.get('pane') != pane or mode not in ('', 'copy-mode'):
            raise ValueError('stale or unavailable viewport')
        if not isinstance(wanted, int) or isinstance(wanted, bool) or wanted < 0:
            raise ValueError('offset')
        wanted = min(wanted, history)
        # Checked and executed in the tmux queue. Do not redirect a delayed drag
        # to a newly selected pane or a reused session on a restarted server.
        condition = '#{&&:#{==:#{pid},%s},#{&&:#{==:#{session_created},%s},#{&&:#{==:#{pane_id},%s},#{||:#{==:#{pane_mode},},#{==:#{pane_mode},copy-mode}}}}}' % (pid, created, pane)
        if wanted == 0:
            action = 'send-keys -t %s -X cancel' % pane if mode == 'copy-mode' else ''
        else:
            # history-top is deterministic; -N is bounded by actual history.
            action = 'copy-mode -t %s ; send-keys -t %s -X history-top' % (pane, pane)
            if history > wanted:
                action += ' ; send-keys -t %s -X -N %d scroll-down' % (pane, history - wanted)
        if action:
            run('if-shell', '-F', '-t', target, condition, action, '')
        pane, mode, history, offset, height, shell = snapshot()
    print(json.dumps(dict(pane=pane, history=history, offset=offset, rows=height,
                          available=mode in ('', 'copy-mode'), readonly=request['readonly'], shell=shell)))


if __name__ == '__main__':
    main()
