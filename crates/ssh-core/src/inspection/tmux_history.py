"""Bounded tmux viewport metadata and copy-mode navigation; never read user text."""
import json
import re
import subprocess
import sys


def run(*args):
    return subprocess.run(['tmux', *args], check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=3).stdout.decode('ascii').strip()


def main():
    request = json.loads(bytes.fromhex(sys.argv[1]))
    sid, pid, created = request['id'], request['server_pid'], request['created']
    if not re.fullmatch(r'\$[0-9]{1,12}', sid) or not isinstance(pid, int) or pid <= 0:
        raise ValueError('identity')
    target = sid + ':'
    fmt = '#{pid}|#{session_created}|#{pane_id}|#{history_size}|#{scroll_position}|#{pane_height}|#{pane_mode}|#{history_limit}'

    def snapshot():
        fields = run('display-message', '-p', '-t', target, fmt).split('|')
        if len(fields) != 8 or fields[0] != str(pid) or fields[1] != str(created):
            raise ValueError('stale session')
        pane, mode = fields[2], fields[6]
        if not re.fullmatch(r'%[0-9]{1,12}', pane):
            raise ValueError('pane')
        history, offset, height, limit = [int(fields[i] or '0') for i in (3, 4, 5, 7)]
        if not (0 <= history <= limit <= 10_000_000 and 1 <= height <= 65535 and 0 <= offset <= history):
            raise ValueError('bounds')
        return pane, mode, history, offset, height

    pane, mode, history, offset, height = snapshot()
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
        pane, mode, history, offset, height = snapshot()
    print(json.dumps(dict(pane=pane, history=history, offset=offset, rows=height,
                          available=mode in ('', 'copy-mode'), readonly=request['readonly'])))


if __name__ == '__main__':
    main()
