"""Linux real workbench startup: Rust loaded, locked vault, no connection/history, normal exit."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
helper = Path(__file__).with_name('resize_x11.py')
with tempfile.TemporaryDirectory(prefix='hspterm-workbench-smoke-') as cache:
    process = subprocess.Popen([str(binary)], env={**os.environ, 'TMPDIR': cache, 'XDG_DATA_HOME': str(Path(cache) / 'data'), 'XDG_CONFIG_HOME': str(Path(cache) / 'config')}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 30
        while True:
            result = subprocess.run([sys.executable, str(helper), str(process.pid), '1100', '760'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode == 0:
                break
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('Workbench failed to create its GTK window')
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
        assert 'libhspterm_frb_bridge' in maps, 'Workbench failed to load its Rust library'
        subprocess.run([sys.executable, str(helper), str(process.pid), '--unfocus'], check=True)
        time.sleep(1)
        unfocused_started, unfocused_ticks = time.monotonic(), ticks()
        time.sleep(5)
        unfocused_elapsed = time.monotonic() - unfocused_started
        unfocused_cpu = (ticks() - unfocused_ticks) / os.sysconf('SC_CLK_TCK') / unfocused_elapsed * 100
        unfocused_status = Path(f'/proc/{process.pid}/status').read_text()
        unfocused_rss = int(next(line for line in unfocused_status.splitlines() if line.startswith('VmRSS:')).split()[1]) * 1024
        assert not list(Path(cache).glob('hspterm-history-*')), 'Locked workbench created terminal history before any SSH connection'
        assert not list(Path(cache).rglob('*.vault')), 'Startup created a vault without user confirmation'
        assert not list(Path(cache).rglob('hspterm-editing-v1')), 'Locked startup created external editor work files'
        previews = list(Path(cache).glob('hspterm-previews-v1*'))
        assert len(previews) == 1, 'Workbench did not initialize its platform preview cache'
        subprocess.run([sys.executable, str(helper), str(process.pid), '--close'], check=True)
        code = process.wait(timeout=15)
        assert code == 0, code
        remaining_previews = list(previews[0].glob('run-*'))
        assert not remaining_previews, 'Normal window close retained its preview cache run'
        report = {'mode': binary.parents[1].name, 'window': 'real GTK/X11', 'rss_bytes': rss, 'idle_elapsed_ms': round(elapsed * 1000), 'idle_cpu_pct': cpu_pct, 'rust_library_loaded': True, 'terminal_history_created': False, 'editor_work_files_created': False, 'remaining_preview_runs': len(remaining_previews), 'exit_code': code}
        report.update(unfocused_rss_bytes=unfocused_rss, unfocused_elapsed_ms=round(unfocused_elapsed * 1000), unfocused_cpu_pct=unfocused_cpu)
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
