"""Run the actual external-editor GTK test with disposable desktop settings.

Usage: python3 benchmark/external_editor_gtk.py flutter test \
    integration_test/live_workbench_test.dart -d linux --reporter expanded
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

for dependency in ("mousepad", "xclip", "xvfb-run", "dbus-run-session"):
    if shutil.which(dependency) is None:
        raise SystemExit(f"External editor GTK validation requires {dependency}")
if len(sys.argv) < 2:
    raise SystemExit("A Flutter test command is required")
with tempfile.TemporaryDirectory(prefix="hspterm-external-desktop-") as folder:
    root = Path(folder)
    env = {**os.environ,
           "CARGO_INCREMENTAL": os.environ.get("CARGO_INCREMENTAL", "0"),
           "XDG_CONFIG_HOME": str(root / "config"),
           "XDG_DATA_HOME": str(root / "data"),
           "XDG_CACHE_HOME": str(root / "cache")}
    result = subprocess.run(["xvfb-run", "-a", "dbus-run-session", "--", *sys.argv[1:]], env=env)
    sys.exit(result.returncode)
