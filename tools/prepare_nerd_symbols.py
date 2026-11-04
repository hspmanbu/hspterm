#!/usr/bin/env python3
"""Reproduce the checked-in MIT icon subset; never runs during app startup.

Uses the installed HarfBuzz C subset API (no pip/module cache). Pinned source
hashes fail closed on changes. --write only replaces these generated assets.
App builds consume the committed TTF and do not need HarfBuzz or networking.
"""
import argparse
import ctypes as C
import ctypes.util
import hashlib
import json
from pathlib import Path
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BASE = "https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v3.5.1/"
FONT = BASE + "patched-fonts/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf"
FONT_SHA = "fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749"
MAP = BASE + "glyphnames.json"
MAP_SHA = "d2fa6615a38eb527462cb71ff17aa44b1d6453d437ed263ab8d5b458393669e8"
PREFIXES = ("dev-", "oct-", "seti-", "pl-", "ple-")
NOTICES = (
    ("Nerd Fonts Symbols", BASE + "patched-fonts/NerdFontsSymbolsOnly/LICENSE",
     "84a7a98c82140fb12c37fe42b93805baa16024cb3e5acc599b7ffe612c55d847"),
    ("Devicon", "https://raw.githubusercontent.com/devicons/devicon/v2.17.0/LICENSE",
     "121194741d4a915b9f5890fdd6dd95121f9b1f816517c792358d72d7c838d664"),
    ("Octicons", "https://raw.githubusercontent.com/primer/octicons/v18.3.0/LICENSE",
     "4f886642f9e8d99eeadd484acdac011c3fde8a338faf52f5ca1408c13b9a9b63"),
    ("Seti", "https://raw.githubusercontent.com/jesseweed/seti-ui/master/LICENSE.md",
     "d4d2d888c6a0a220a7b0e2d6013cf37539b0e05ef937002b3b33bdb364575b88"),
    ("Powerline", "https://raw.githubusercontent.com/powerline/powerline/develop/LICENSE",
     "46d5355e4734468135d8e4a30d0916292cc4df2b3ec30aa68c866f82497933be"),
    ("Powerline Extra", "https://raw.githubusercontent.com/ryanoasis/powerline-extra-symbols/master/LICENSE",
     "544307a58e6826c24145b2af1c3578b53e2e21ae0e6c67ab4c6abd544304d26a"),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def download(url, expected):
    with urllib.request.urlopen(url, timeout=25) as response:
        if not response.url.startswith("https://raw.githubusercontent.com/"):
            raise ValueError("unexpected font-source redirect")
        data = response.read(8 * 1024 * 1024 + 1)
    if len(data) > 8 * 1024 * 1024 or digest(data) != expected:
        raise ValueError("font source or license hash changed: " + url)
    return data


def bind(library, name, args, result):
    function = getattr(library, name)
    function.argtypes = args
    function.restype = result
    return function


def subset(data, wanted):
    hb = C.CDLL(ctypes.util.find_library("harfbuzz") or "libharfbuzz.so.0")
    sub = C.CDLL(ctypes.util.find_library("harfbuzz-subset") or "libharfbuzz-subset.so.0")
    ptr, uint = C.c_void_p, C.c_uint
    blob_create = bind(hb, "hb_blob_create", [ptr, uint, C.c_int, ptr, ptr], ptr)
    blob_destroy = bind(hb, "hb_blob_destroy", [ptr], None)
    face_create = bind(hb, "hb_face_create", [ptr, uint], ptr)
    face_destroy = bind(hb, "hb_face_destroy", [ptr], None)
    face_blob = bind(hb, "hb_face_reference_blob", [ptr], ptr)
    blob_data = bind(hb, "hb_blob_get_data", [ptr, C.POINTER(uint)], ptr)
    input_create = bind(sub, "hb_subset_input_create_or_fail", [], ptr)
    input_destroy = bind(sub, "hb_subset_input_destroy", [ptr], None)
    unicode_set = bind(sub, "hb_subset_input_unicode_set", [ptr], ptr)
    subset_face = bind(sub, "hb_subset_or_fail", [ptr, ptr], ptr)
    set_create = bind(hb, "hb_set_create", [], ptr)
    set_destroy = bind(hb, "hb_set_destroy", [ptr], None)
    set_clear = bind(hb, "hb_set_clear", [ptr], None)
    set_add = bind(hb, "hb_set_add", [ptr, uint], None)
    set_next = bind(hb, "hb_set_next", [ptr, C.POINTER(uint)], C.c_int)
    collect = bind(hb, "hb_face_collect_unicodes", [ptr, ptr], None)
    version = bind(hb, "hb_version_string", [], C.c_char_p)().decode("ascii")
    backing = C.create_string_buffer(data)
    blob = face = configuration = output = output_blob = coverage = None
    try:
        # DUPLICATE copies source bytes; HarfBuzz owns that copy.
        blob = blob_create(backing, len(data), 0, None, None)
        face = face_create(blob, 0) if blob else None
        configuration = input_create()
        if not face or not configuration:
            raise RuntimeError("HarfBuzz could not create font subset input")
        codes = unicode_set(configuration)
        set_clear(codes)
        for code in sorted(wanted):
            set_add(codes, code)
        output = subset_face(face, configuration)
        if not output:
            raise RuntimeError("HarfBuzz rejected font subset")
        coverage = set_create()
        if not coverage:
            raise RuntimeError("HarfBuzz could not allocate coverage set")
        collect(output, coverage)
        actual, code = set(), uint(0xFFFFFFFF)
        while set_next(coverage, C.byref(code)):
            actual.add(code.value)
        if actual != wanted:
            raise ValueError("subset cmap differs from the licensed allowlist")
        output_blob = face_blob(output)
        length = uint()
        body = blob_data(output_blob, C.byref(length))
        if not body or not 12 <= length.value <= 8 * 1024 * 1024:
            raise ValueError("invalid subset font length")
        font = C.string_at(body, length.value)
        if font[:4] not in (b"\0\1\0\0", b"OTTO"):
            raise ValueError("invalid subset SFNT signature")
        return font, version
    finally:
        for value, destroy in ((coverage, set_destroy), (output_blob, blob_destroy),
                               (output, face_destroy), (configuration, input_destroy),
                               (face, face_destroy), (blob, blob_destroy)):
            if value:
                destroy(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="publish the three generated assets")
    args = parser.parse_args()
    metadata = json.loads(download(MAP, MAP_SHA))
    selected = {name: int(value["code"], 16) for name, value in metadata.items()
                if name.startswith(PREFIXES)}
    wanted = set(selected.values())
    if not 100 <= len(wanted) <= 4000 or any(c not in {0x2665, 0x26A1} and not 0xE000 <= c <= 0xF8FF for c in wanted):
        raise ValueError("unexpected allowlisted glyph coverage")
    original_aliases = {}
    for name, value in metadata.items():
        if isinstance(value, dict) and "code" in value and int(value["code"], 16) in wanted and name not in selected:
            # Nerd's own original glyphs are MIT under the bundled aggregate
            # notice. Keep only aliases of already selected Seti codepoints;
            # this does not pull in additional custom/unreviewed codepoints.
            if name.startswith("custom-"):
                original_aliases[name] = value["code"]
            else:
                raise ValueError("cross-license codepoint alias requires review: " + name)
    font, tool_version = subset(download(FONT, FONT_SHA), wanted)
    notices = [f"HSPTerm MIT Nerd symbol subset, derived from Nerd Fonts v3.5.1.\n"
               f"Only {', '.join(PREFIXES)} glyph groups retained. Other upstream icon sets excluded.\n"]
    for name, url, sha in NOTICES:
        notices.append(f"\n--- {name} ---\nSource: {url}\nSHA256: {sha}\n\n" + download(url, sha).decode("utf-8"))
    # Preserve complete license wording/line breaks while normalizing upstream
    # trailing spaces for reviewable text assets.
    notice_body = ("\n".join(line.rstrip() for line in "\n".join(notices).splitlines()) + "\n").encode()
    manifest = {
        "version": 1, "upstream": "Nerd Fonts v3.5.1", "font_url": FONT,
        "font_sha256": FONT_SHA, "glyph_map_url": MAP, "glyph_map_sha256": MAP_SHA,
        "subset_sha256": digest(font), "subset_bytes": len(font), "notices_sha256": digest(notice_body),
        "harfbuzz_version": tool_version, "prefixes": PREFIXES,
        "codepoints": [f"{code:04x}" for code in sorted(wanted)],
        "aliases": len(selected), "glyphs": len(wanted), "original_aliases": original_aliases,
        "licenses": [{"component": n, "url": u, "sha256": h, "license": "MIT"} for n, u, h in NOTICES],
    }
    if args.write:
        directory = ROOT / "ui_flutter/assets/fonts"
        for filename, body in (
            ("HSPNerdSymbols.ttf", font),
            ("HSPNerdSymbols-LICENSES.txt", notice_body),
            ("HSPNerdSymbols-MANIFEST.json", (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode()),
        ):
            with tempfile.NamedTemporaryFile(dir=directory, prefix=".nerd-", delete=False) as f:
                temporary = Path(f.name)
                try:
                    f.write(body)
                    f.flush()
                    f.close()
                    temporary.chmod(0o644)  # public source assets, never secrets
                    temporary.replace(directory / filename)
                finally:
                    temporary.unlink(missing_ok=True)
    print(json.dumps({k: manifest[k] for k in ("glyphs", "subset_bytes", "subset_sha256", "harfbuzz_version")}, indent=2))


if __name__ == "__main__":
    main()
