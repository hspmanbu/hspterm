#!/usr/bin/env python3
"""Maintain source-only FRB error boundaries and public literal summaries.

Does not touch generated bindings, resolve dependencies, or compile anything.
Tokenizes strings/comments before matching top-level functions; never rewrites
Rust with a brace regex that could mistake payload text for executable code.
"""
from pathlib import Path
import argparse
import re

ROOT = Path(__file__).resolve().parents[1]
API = ROOT / 'crates/frb-bridge/src/api.rs'
LITERALS = ROOT / 'crates/frb-bridge/src/public_error_literals.rs'
MARKER = 'HSPTERM_PUBLIC_ERROR_BOUNDARY'


def tokens(text):
    i, length = 0, len(text)
    while i < length:
        start = i
        if text[i].isspace():
            i += 1
            continue
        if text.startswith('//', i):
            end = text.find('\n', i)
            i = length if end == -1 else end + 1
            continue
        if text.startswith('/*', i):
            depth = 1
            i += 2
            while depth:
                if i >= length:
                    raise ValueError('unterminated comment')
                if text.startswith('/*', i):
                    depth += 1
                    i += 2
                elif text.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        raw = re.match(r'(?:br|r)(#+)?"', text[i:])
        if raw:
            ending = '"' + (raw[1] or '')
            end = text.find(ending, i + raw.end())
            if end < 0:
                raise ValueError('unterminated raw string')
            i = end + len(ending)
            yield ('bytes' if text[start] == 'b' else 'string', text[start:i], start, i)
            continue
        prefix = 1 if text.startswith('b"', i) else 0
        if text[i] == '"' or prefix:
            i += prefix + 1
            while i < length:
                c = text[i]
                i += 1
                if c == '\\':
                    i += 1
                elif c == '"':
                    break
            else:
                raise ValueError('unterminated string')
            yield ('bytes' if prefix else 'string', text[start:i], start, i)
            continue
        char = re.match(r"(?:b)?'(?:\\u\{[0-9a-fA-F_]+\}|\\x[0-9a-fA-F]{2}|\\[^\n]|[^'\\\n])'", text[i:])
        if char:
            i += char.end()
            yield ('char', text[start:i], start, i)
            continue
        identifier = re.match(r'[A-Za-z_][A-Za-z_0-9]*', text[i:])
        i += identifier.end() if identifier else 1
        yield ('word' if identifier else 'punct', text[start:i], start, i)


def functions(text):
    stream = list(tokens(text))
    depth, i = 0, 0
    while i < len(stream):
        _, word, start, end = stream[i]
        if depth == 0 and word == 'pub':
            j = i + 1
            asynchronous = stream[j][1] == 'async'
            j += int(asynchronous)
            if stream[j][1] == 'fn':
                name = stream[j + 1][1]
                opening = next(k for k in range(j + 2, len(stream)) if stream[k][0] == 'punct' and stream[k][1] == '{')
                header = text[end:stream[opening][2]]
                if re.search(r'->\s*(?:anyhow::)?Result\s*<', header):
                    balance, closing = 1, opening + 1
                    while balance:
                        kind, value, _, _ = stream[closing]
                        if kind == 'punct':
                            balance += (value == '{') - (value == '}')
                        closing += 1
                    yield name, asynchronous, stream[opening][3], stream[closing - 1][2]
                    i = closing
                    continue
        if stream[i][0] == 'punct':
            depth += (word == '{') - (word == '}')
        i += 1


def wrap(text):
    edits = []
    for name, asynchronous, start, end in functions(text):
        body = text[start:end]
        guard = 'guard' if asynchronous else 'guard_sync'
        if MARKER in body:
            stream = list(tokens(body))
            values = [t[1] for t in stream]
            finish = ['crate', ':', ':', 'public_errors', ':', ':', 'finish', '(', 'outcome', ')']
            if values[:8] != ['let', 'outcome', ':', 'Result', '<', '_', '>', '='] or values[-10:] != finish:
                raise ValueError(f'{name}: unknown boundary shape; inspect manually')
            if values[8:16] == ['crate', ':', ':', 'public_errors', ':', ':', guard, '(']:
                continue
            if not asynchronous:
                tail = [')', '(', ')', ';'] + finish
                if values[8:12] != ['(', 'move', '|', '|'] or values[-14:] != tail or len(values) <= 26:
                    raise ValueError(f'{name}: legacy sync boundary changed; inspect manually')
                if values[12] == '{' and values[-15] == '}':
                    body = body[stream[12][3]:stream[-15][2]]
                else:
                    # rustfmt removes redundant braces around one expression.
                    body = body[stream[12][2]:stream[-14][2]]
                expression = f'crate::public_errors::guard_sync(move || {{{body}}})'
                edits.append((start, end, f'\n    /* {MARKER} */\n    let outcome: Result<_> = {expression};\n    crate::public_errors::finish(outcome)\n'))
                continue
            # Upgrade the previous, result-only boundary without replacing any
            # business tokens or trusting raw braces inside strings/comments.
            expected = ['(', 'async', 'move', '{']
            if values[8:8 + len(expected)] != expected:
                raise ValueError(f'{name}: legacy boundary expression is unknown')
            opening = 8 + len(expected) - 1
            balance, closing = 1, opening + 1
            while balance:
                kind, value, _, _ = stream[closing]
                if kind == 'punct':
                    balance += (value == '{') - (value == '}')
                closing += 1
            tail = [')', '.', 'await', ';']
            if values[closing:] != tail + finish:
                raise ValueError(f'{name}: legacy boundary tail changed; inspect manually')
            body = body[stream[opening][3]:stream[closing - 1][2]]
        expression = f'crate::public_errors::{guard}(async move {{{body}}}).await' if asynchronous else f'crate::public_errors::{guard}(move || {{{body}}})'
        replacement = f'\n    /* {MARKER} */\n    let outcome: Result<_> = {expression};\n    crate::public_errors::finish(outcome)\n'
        edits.append((start, end, replacement))
    for start, end, replacement in reversed(edits):
        text = text[:start] + replacement + text[end:]
    return text, len(edits)


def production_tokens(text):
    stream = list(tokens(text))
    i = 0
    while i < len(stream):
        if [t[1] for t in stream[i:i + 7]] == ['#', '[', 'cfg', '(', 'test', ')', ']']:
            j = i + 7
            while j < len(stream) and not (stream[j][0] == 'punct' and stream[j][1] in {'{', ';'}):
                j += 1
            if j == len(stream):
                raise ValueError('test attribute without an item')
            if stream[j][1] == ';':
                i = j + 1
                continue
            balance = 1
            j += 1
            while balance:
                kind, value, _, _ = stream[j]
                if kind == 'punct':
                    balance += (value == '{') - (value == '}')
                j += 1
            i = j
            continue
        yield stream[i]
        i += 1


def literals():
    # Exact public, static Chinese summaries. Never trust arbitrary error text
    # because it merely contains Chinese, a familiar prefix, or a regex match.
    choices = set()
    for source in sorted((ROOT / 'crates').rglob('*.rs')):
        if 'src' not in source.relative_to(ROOT / 'crates').parts or source.name in {'frb_generated.rs', LITERALS.name} or source.stem in {'test', 'tests'} or 'tests' in source.relative_to(ROOT / 'crates').parts or source.stem.endswith(('_test', '_tests')):
            continue
        for kind, value, _, _ in production_tokens(source.read_text()):
            if kind == 'string' and re.search(r'[\u3400-\u9fff]', value) and not any(c in value for c in '{}\n\r') and len(value) <= 512:
                choices.add(value)
    return '// Generated from public static source literals by tools/bridge_error_boundaries.py.\n// Not FRB generated code. Never add runtime/error/input values here.\npub(super) const PUBLIC_LITERALS: &[&str] = &[\n' + ''.join(f'    {v},\n' for v in sorted(choices)) + '];\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='update source boundaries and exact static summaries')
    args = parser.parse_args()
    original = API.read_text()
    updated, count = wrap(original)
    summaries = literals()
    if args.write:
        API.write_text(updated)
        LITERALS.write_text(summaries)
        print(f'Source boundaries added: {count}; public summaries updated. No build/tests run.')
    else:
        if count or not LITERALS.exists() or LITERALS.read_text() != summaries:
            raise SystemExit(f'Uncovered public Result functions: {count}; run --write then inspect the source diff.')
        print(f'All {len(list(functions(original)))} public Result entries have source error boundaries. Syntax inventory only, not compilation.')


if __name__ == '__main__':
    main()
