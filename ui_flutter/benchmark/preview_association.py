"""Isolated XDG default viewer for actual GTK file-URI launch verification.

No user MIME settings change; the viewer records hashes/counts, never file text.
Run: python3 benchmark/preview_association.py --run <flutter test ...>
"""
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile


def viewer(receipt, source):
    source = Path(source)
    if source.name != 'preview.txt' or not source.parent.name.startswith('file-'):
        raise RuntimeError('Viewer accepts only its controlled cached text fixture')
    digest = hashlib.sha256()
    size = 0
    with source.open('rb') as stream:
        for block in iter(lambda: stream.read(65536), b''):
            digest.update(block)
            size += len(block)
    receipt = Path(receipt)
    items = json.loads(receipt.read_text()) if receipt.exists() else []
    items.append({'path': str(source), 'bytes': size, 'sha256': digest.hexdigest()})
    with tempfile.NamedTemporaryFile(mode='w', dir=receipt.parent, delete=False) as staged:
        json.dump(items, staged)
        stage = staged.name
    os.replace(stage, receipt)


def quote(value):
    # Desktop Entry Exec quoting/field escaping; not a shell command.
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%') + '"'


if __name__ == '__main__':
    if sys.argv[1] == '--viewer':
        viewer(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == '--run':
        with tempfile.TemporaryDirectory(prefix='hspterm-preview-association-') as folder:
            root = Path(folder)
            data = root / 'data'
            config = root / 'config'
            cache = root / 'cache'
            temporary = root / 'tmp'
            applications = data / 'applications'
            for directory in (applications, config, cache, temporary):
                directory.mkdir(parents=True, exist_ok=True)
            receipt = root / 'viewed.json'
            app_id = 'hspterm-preview-fixture.desktop'
            (applications / app_id).write_text(
                '[Desktop Entry]\nType=Application\nName=HSPTerm controlled preview viewer\n'
                'NoDisplay=true\nTerminal=false\nMimeType=text/plain;\nExec='
                + quote(sys.executable) + ' ' + quote(Path(__file__).resolve())
                + ' --viewer ' + quote(receipt) + ' %f\n'
            )
            (config / 'mimeapps.list').write_text('[Default Applications]\ntext/plain=' + app_id + ';\n')
            environment = {**os.environ, 'XDG_DATA_HOME': str(data), 'XDG_CONFIG_HOME': str(config),
                           'XDG_CACHE_HOME': str(cache), 'TMPDIR': str(temporary),
                           'HSPTERM_PREVIEW_RECEIPT': str(receipt)}
            result = subprocess.run(['xvfb-run', '-a', 'dbus-run-session', '--', *sys.argv[2:]], env=environment)
            capture = os.environ.get('HSPTERM_PREVIEW_CAPTURE')
            screenshot = temporary / 'hspterm-file-preview.png'
            if capture and screenshot.exists():
                shutil.copyfile(screenshot, capture)
            sys.exit(result.returncode)
    else:
        raise RuntimeError('Expected --run or --viewer')
