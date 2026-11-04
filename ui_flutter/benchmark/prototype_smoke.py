"""Linux mock app smoke: real window, no Rust loaded, idle sample, normal exit."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
helper = Path(__file__).with_name('resize_x11.py')
with tempfile.TemporaryDirectory(prefix='hspterm-prototype-smoke-') as cache:
    process = subprocess.Popen([str(binary)], env={**os.environ, 'TMPDIR': cache}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 30
        while True:
            result = subprocess.run([sys.executable, str(helper), str(process.pid), '1100', '760'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode == 0:
                break
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('Prototype failed to create its GTK window')
            time.sleep(.1)
        time.sleep(2)
        def ticks():
            fields = Path(f'/proc/{process.pid}/stat').read_text().split(') ', 1)[1].split()
            return int(fields[11]) + int(fields[12])
        started, cpu = time.monotonic(), ticks()
        time.sleep(5)
        elapsed = time.monotonic() - started
        cpu_pct = (ticks() - cpu) / os.sysconf('SC_CLK_TCK') / elapsed * 100
        status = Path(f'/proc/{process.pid}/status').read_text()
        rss = int(next(line for line in status.splitlines() if line.startswith('VmRSS:')).split()[1]) * 1024
        maps = Path(f'/proc/{process.pid}/maps').read_text()
        assert 'libhspterm_frb_bridge' not in maps, 'Mock entry loaded Rust library'
        assert not list(Path(cache).glob('hspterm-history-*')), 'Mock entry created terminal history'
        subprocess.run([sys.executable, str(helper), str(process.pid), '--close'], check=True)
        code = process.wait(timeout=15)
        assert code == 0, code
        report = {'mode': binary.parents[1].name, 'window': 'real GTK/X11', 'rss_bytes': rss, 'idle_elapsed_ms': round(elapsed * 1000), 'idle_cpu_pct': cpu_pct, 'rust_library_loaded': False, 'terminal_history_created': False, 'exit_code': code}
        if len(sys.argv) == 3:
            Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
