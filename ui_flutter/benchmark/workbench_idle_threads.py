"""Measure only a new, locked workbench; never attach to a user's application.

Run inside external_editor_gtk.py's disposable Xvfb/desktop. Per-thread /proc
counters locate CPU work without ptrace, perf privileges, VM service or secrets.
This does not measure Flutter frame times or establish a memory-leak conclusion.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
if len(sys.argv) != 3:
    raise SystemExit('Usage: workbench_idle_threads.py FORMAL_BUNDLE/hspterm OUTPUT.json')
binary = Path(sys.argv[1]).resolve()
if binary not in {root / 'build/linux/x64' / mode / 'bundle/hspterm' for mode in ('debug', 'release')}:
    raise SystemExit('Only this project\'s freshly built formal bundles may be sampled')
helper = Path(__file__).with_name('resize_x11.py')
clock_ticks = os.sysconf('SC_CLK_TCK')

def ticks(path):
    fields = path.read_text().rsplit(') ', 1)[1].split()
    return int(fields[11]) + int(fields[12])

def threads(pid):
    result = {}
    for path in Path(f'/proc/{pid}/task').iterdir():
        try:
            result[path.name] = (path.joinpath('comm').read_text().strip(), ticks(path / 'stat'))
        except FileNotFoundError:
            pass  # A transient thread ended between directory/stat reads.
    return result

def sample(pid):
    before = threads(pid)
    process_before = ticks(Path(f'/proc/{pid}/stat'))
    start = time.monotonic()
    time.sleep(5)
    process_after = ticks(Path(f'/proc/{pid}/stat'))
    elapsed = time.monotonic() - start
    after = threads(pid)
    records = []
    for tid in before.keys() & after.keys():
        name, total = after[tid]
        delta = total - before[tid][1]
        if delta:
            records.append({'thread': name, 'cpu_ticks': delta,
                            'cpu_pct': delta / clock_ticks / elapsed * 100})
    status = Path(f'/proc/{pid}/status').read_text()
    return {'elapsed_ms': round(elapsed * 1000),
            'process_cpu_pct': (process_after-process_before) / clock_ticks / elapsed * 100,
            'rss_bytes': int(next(s for s in status.splitlines() if s.startswith('VmRSS:')).split()[1])*1024,
            'threads': sorted(records, key=lambda r: -r['cpu_ticks']),
            'new_threads': len(after.keys()-before.keys()),
            'ended_threads': len(before.keys()-after.keys())}

with tempfile.TemporaryDirectory(prefix='hspterm-idle-threads-') as temporary:
    cache = Path(temporary)
    env = {**os.environ, 'TMPDIR': temporary, 'XDG_DATA_HOME': str(cache/'data'),
           'XDG_CONFIG_HOME': str(cache/'config'), 'XDG_CACHE_HOME': str(cache/'cache')}
    process = subprocess.Popen([str(binary)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic()+30
        while subprocess.run([sys.executable, str(helper), str(process.pid), '1100', '760'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('New locked workbench did not create its window')
            time.sleep(.1)
        assert Path(f'/proc/{process.pid}/exe').resolve() == binary
        time.sleep(2)
        focused = sample(process.pid)
        subprocess.run([sys.executable, str(helper), str(process.pid), '--unfocus'], check=True)
        time.sleep(1)
        unfocused = sample(process.pid)
        maps = Path(f'/proc/{process.pid}/maps').read_text()
        assert 'libhspterm_frb_bridge' in maps
        assert not list(cache.rglob('*.vault'))
        assert not list(cache.glob('hspterm-history-*'))
        subprocess.run([sys.executable, str(helper), str(process.pid), '--close'], check=True)
        code = process.wait(timeout=15)
        assert code == 0
        assert not list(cache.glob('hspterm-previews-v1*/run-*'))
        report = {'mode': binary.parents[1].name, 'window': 'new locked GTK/X11',
                  'ticks_per_second': clock_ticks, 'focused': focused, 'unfocused': unfocused,
                  'exit_code': code, 'rust_loaded': True, 'history_or_vault_created': False,
                  'note': 'Short /proc samples; no frame timing, ptrace, passwords, SSH or leak proof.'}
        Path(sys.argv[2]).write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report))
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
