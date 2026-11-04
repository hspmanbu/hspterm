#!/usr/bin/env python3
"""Prepare an explicit, reproducible local fork; never patch the global pub cache.

Run BEFORE flutter pub get (also after flutter clean). Does not execute package
code, resolve dependencies, build or test. Existing edited trees are refused.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
URL = "https://pub.dev/api/archives/super_native_extensions-0.9.1.tar.gz"
ARCHIVE_SHA256 = "b9611dcb68f1047d6f3ef11af25e4e68a21b1a705bbcc3eb8cb4e9f5c3148569"
DESTINATION = ROOT / "ui_flutter/.dart_tool/hspterm_native_extensions"
STAMP = ".hspterm-source.json"
MAX_ARCHIVE = 4 * 1024 * 1024
MAX_EXPANDED = 16 * 1024 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def patch_source(source, replacement):
    parts = replacement.split("// HSPTERM_OUTSIDE_IMPL\n")
    if len(parts) != 2:
        raise ValueError("Descriptor patch is incomplete")
    replacement, tests = parts
    start = "    fn file_descriptor_for_item("
    end = "    fn create_virtual_stream_session("
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError("Pinned descriptor patch anchors changed")
    left, middle = source.split(start)
    _, right = middle.split(end)
    source = left + replacement.rstrip() + "\n\n" + end + right
    anchor = "        System::{\n"
    shell = "            FD_PROGRESSUI, FILEDESCRIPTORW,"
    if source.count(anchor) != 1 or source.count(shell) != 1:
        raise ValueError("Pinned import anchors changed")
    return source.replace(anchor, "        Storage::FileSystem::{FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL},\n" + anchor).replace(
        shell, "            FD_PROGRESSUI, FD_FILESIZE, FILEDESCRIPTORW,") + "\n" + tests


def archive_files(payload):
    if len(payload) > MAX_ARCHIVE or sha(payload) != ARCHIVE_SHA256:
        raise ValueError("Unexpected upstream archive checksum or size")
    files = {}
    size = 0
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            canonical = member.name.rstrip("/") if member.isdir() else member.name
            if path.is_absolute() or not path.parts or path.as_posix() != canonical or any(p in (".", "..") for p in path.parts) or "\\" in member.name or ":" in member.name:
                raise ValueError("Unsafe archive name")
            if member.isdir():
                continue
            if not member.isfile() or member.name in files:
                raise ValueError("Archive contains a link, special file or duplicate")
            size += member.size
            if size > MAX_EXPANDED or len(files) >= 4096:
                raise ValueError("Expanded archive exceeds the source budget")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError("Missing archived file")
            files[member.name] = stream.read()
    if "LICENSE" not in files or "pubspec.yaml" not in files:
        raise ValueError("Incomplete upstream source or license")
    return files


def patch_drop_source(source):
    # Outgoing drags initialize raw.DropContext too. Upstream otherwise revokes
    # an existing target unconditionally; the runner owns inbound CF_HDROP.
    anchor = "        self.weak_self.set(weak_self.clone());\n"
    destructor = "            let hook = *self.hook;\n"
    if source.count(anchor) != 1 or source.count(destructor) != 1:
        raise ValueError("Pinned drop ownership anchors changed")
    guard = '''        // HSPTerm reserves its HWND before plugin registration. Do not revoke
        // its inbound target, install a destruction hook, or register another.
        if unsafe {
            windows::Win32::UI::WindowsAndMessaging::GetPropW(
                self.view, &windows::core::HSTRING::from("HSPTerm.ExplorerDropOwner.v1"),
            ).0 != 0
        } {
            self.hook.set(HWINEVENTHOOK(0));
            return;
        }
'''
    return source.replace(anchor, anchor + guard).replace(
        destructor, destructor + "            if hook.0 == 0 { return; } // HSPTerm owns this HWND.\n")


def inventory(path):
    result = {}
    for parent, dirs, names in os.walk(path, followlinks=False):
        parent = Path(parent)
        # Build systems may add these after pub get. They are not upstream source
        # and are intentionally excluded from verification, never deleted here.
        dirs[:] = [d for d in dirs if d not in (".dart_tool", "build", "target")]
        for name in dirs + names:
            if (parent / name).is_symlink():
                raise ValueError("Prepared source contains a symbolic link")
        for name in names:
            relative = (parent / name).relative_to(path).as_posix()
            if relative == STAMP:
                continue
            result[relative] = sha((parent / name).read_bytes())
    return result


def prepare(payload, replacement, destination=DESTINATION):
    files = archive_files(payload)
    source_path = "rust/src/win32/data_object.rs"
    files[source_path] = patch_source(files[source_path].decode("utf-8"), replacement).encode("utf-8")
    source_path = "rust/src/win32/drop.rs"
    files[source_path] = patch_drop_source(files[source_path].decode("utf-8")).encode("utf-8")
    expected = {name: sha(data) for name, data in files.items()}
    stamp = {"archive_sha256": ARCHIVE_SHA256, "patch_sha256": sha(replacement.encode()), "files": expected}
    if destination.is_symlink():
        raise ValueError("Prepared destination is a symbolic link")
    if destination.exists():
        saved = json.loads((destination / STAMP).read_text())
        if saved != stamp or inventory(destination) != expected:
            raise ValueError("Existing prepared source changed; preserve/review it explicitly")
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    # All cleanup is limited to this newly owned private directory. Publishing
    # never replaces an existing destination or deletes an unknown source tree.
    temporary = Path(tempfile.mkdtemp(prefix=".hspterm-native-", dir=destination.parent))
    try:
        for name, data in files.items():
            target = temporary.joinpath(*PurePosixPath(name).parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (temporary / STAMP).write_text(json.dumps(stamp, sort_keys=True), encoding="utf-8")
        # An empty concurrent directory is also unknown and must not be replaced.
        if destination.exists():
            raise ValueError("Prepared source appeared concurrently; retry explicitly")
        # mkdir acts as a no-clobber reservation; rename into that reservation is
        # deliberately avoided because POSIX rename can replace an empty tree.
        destination.mkdir()
        try:
            for child in temporary.iterdir():
                child.rename(destination / child.name)
        except BaseException:
            # Preserve the incomplete destination for inspection, do not reset it.
            raise
    finally:
        shutil.rmtree(temporary)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Offline copy of the exact pinned upstream archive")
    args = parser.parse_args()
    if args.archive:
        with args.archive.open("rb") as source:
            payload = source.read(MAX_ARCHIVE + 1)
    else:
        with urllib.request.urlopen(URL, timeout=45) as response:
            payload = response.read(MAX_ARCHIVE + 1)
    print(prepare(payload, (ROOT / "tools/native_extensions_descriptor.rs").read_text(encoding="utf-8")))


if __name__ == "__main__":
    main()
