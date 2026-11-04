"""Actual GTK close -> Flutter exit observer -> native history cleanup check."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
helper = Path(__file__).with_name("resize_x11.py")
with tempfile.TemporaryDirectory(prefix="hspterm-normal-exit-") as cache:
    process = subprocess.Popen([str(binary)], env={**os.environ, "TMPDIR": cache}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        root = Path(cache) / f"hspterm-history-v1-{os.geteuid()}"
        deadline = time.monotonic() + 30
        while not root.exists() or not list(root.glob("run-*")):
            if process.poll() is not None:
                raise RuntimeError("Application exited before terminal creation")
            if time.monotonic() > deadline:
                raise RuntimeError("Application did not create its terminal history")
            time.sleep(.02)
        time.sleep(2)
        def ticks():
            fields = Path(f"/proc/{process.pid}/stat").read_text().split(") ", 1)[1].split()
            return int(fields[11]) + int(fields[12])
        cpu_start, started = ticks(), time.monotonic()
        time.sleep(5.6)
        elapsed = time.monotonic() - started
        cpu_pct = (ticks() - cpu_start) / os.sysconf("SC_CLK_TCK") / elapsed * 100
        memory = {}
        for line in Path(f"/proc/{process.pid}/smaps_rollup").read_text().splitlines():
            fields = line.split()
            if fields[0] in ["Rss:", "Pss:", "Private_Clean:", "Private_Dirty:", "Shared_Clean:"]:
                memory[fields[0][:-1] + "_bytes"] = int(fields[1]) * 1024
        subprocess.run([sys.executable, str(helper), str(process.pid), "--close"], check=True)
        code = process.wait(timeout=20)
        if code != 0:
            raise RuntimeError(f"Application close exited {code}")
        remaining = list(root.glob("run-*"))
        if remaining:
            raise RuntimeError(f"Normal close retained {len(remaining)} terminal cache directories")
        report = {
            "phase": "main_idle_and_normal_exit",
            "mode": binary.parents[1].name,
            "elapsed_ms": round(elapsed * 1000),
            "cpu_pct": cpu_pct,
            **memory,
            "exit_code": code,
            "remaining_history_directories": len(remaining),
        }
        if len(sys.argv) == 3:
            Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + "\n")
        print("Normal GTK window close: exit 0; no terminal history directories remain")
        print(json.dumps(report))
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
