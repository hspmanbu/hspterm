#!/usr/bin/env python3
"""Source-only named-call audit for Flutter's api.dart aliases and Rust API.

No generated bindings, dependency resolution, build, Analyze or tests. This
checks direct named calls and unique public bridge struct field names only.
It does not type-check values, resolve symbols, inspect closures or verify FRB ABI.
String interpolation is deliberately opaque; never execute application text.
"""
from pathlib import Path
import re
import sys

from bridge_error_boundaries import tokens as rust_tokens, production_tokens

ROOT = Path(__file__).resolve().parents[1]


def camel(name):
    head, *tail = name.split('_')
    return head + ''.join(word[:1].upper() + word[1:] for word in tail)


def rust_signatures(source):
    stream = list(rust_tokens(source))
    result = {}
    depth = 0
    for i, (_, value, _, _) in enumerate(stream):
        if value == 'pub' and depth == 0:
            j = i + 1
            if stream[j][1] == 'async':
                j += 1
            if stream[j][1] == 'fn':
                name = stream[j + 1][1]
                j += 2
                # Generic public helpers are outside this direct FRB surface.
                if stream[j][1] != '(':
                    continue
                balance = 1
                start = j + 1
                parameters = []
                j += 1
                while balance:
                    word = stream[j][1]
                    if stream[j][0] == 'punct':
                        if word == ',' and balance == 1:
                            parameters.append(stream[start:j])
                            start = j + 1
                        balance += int(word in '(<[{') - int(word in ')>]}')
                    if balance == 0:
                        parameters.append(stream[start:j])
                    j += 1
                all_names, required = set(), set()
                for parameter in parameters:
                    if not parameter:
                        continue
                    colon = next((n for n, t in enumerate(parameter) if t[1] == ':'), None)
                    if colon is None:
                        raise ValueError('unsupported Rust parameter in ' + name)
                    field = parameter[colon - 1][1]
                    kind = ''.join(t[1] for t in parameter[colon + 1:])
                    # FRB hides stream sink parameters in the generated stream.
                    if 'StreamSink<' in kind:
                        continue
                    all_names.add(camel(field))
                    if not kind.startswith('Option<'):
                        required.add(camel(field))
                wire = camel(name)
                if wire in result:
                    raise ValueError('duplicate Rust API wire name ' + wire)
                result[wire] = (all_names, required)
        if stream[i][0] == 'punct':
            depth += int(value == '{') - int(value == '}')
    return result


def string_end(source, start):
    """Skip one whole Dart literal, including nested interpolation strings."""
    raw = source[start] == 'r'
    i = start + int(raw)
    quote = source[i]
    delimiter = quote * (3 if source.startswith(quote * 3, i) else 1)
    i += len(delimiter)
    while not source.startswith(delimiter, i):
        if i >= len(source):
            raise ValueError('unterminated Dart string')
        if not raw and source[i] == '\\':
            i += 2
        elif not raw and source.startswith('${', i):
            balance = 1
            i += 2
            while balance:
                if i >= len(source):
                    raise ValueError('unterminated Dart interpolation')
                if source.startswith('//', i):
                    end = source.find('\n', i)
                    i = len(source) if end < 0 else end + 1
                elif source.startswith('/*', i):
                    i = comment_end(source, i)
                elif source[i] in "'\"" or (source[i] == 'r' and i + 1 < len(source) and source[i + 1] in "'\""):
                    i = string_end(source, i)
                else:
                    balance += int(source[i] == '{') - int(source[i] == '}')
                    i += 1
        else:
            i += 1
    return i + len(delimiter)


def comment_end(source, start):
    balance, i = 1, start + 2
    while balance:
        if i >= len(source):
            raise ValueError('unterminated Dart comment')
        if source.startswith('/*', i):
            balance += 1
            i += 2
        elif source.startswith('*/', i):
            balance -= 1
            i += 2
        else:
            i += 1
    return i


def dart_tokens(source):
    i = 0
    while i < len(source):
        start = i
        if source[i].isspace():
            i += 1
            continue
        if source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end + 1
            continue
        if source.startswith('/*', i):
            i = comment_end(source, i)
            continue
        raw = source[i] == 'r' and i + 1 < len(source) and source[i + 1] in "'\""
        if source[i] in "'\"" or raw:
            i = string_end(source, start)
            yield 'string', source[start:i], start
            continue
        word = re.match(r'[a-zA-Z_$][a-zA-Z_0-9$]*', source[i:])
        i += word.end() if word else 1
        yield 'word' if word else 'punct', source[start:i], start


def dart_calls(source, aliases):
    stream = list(dart_tokens(source))
    for i in range(len(stream) - 3):
        if (stream[i][0] != 'word' or stream[i][1] not in aliases
                or stream[i + 1][1] != '.' or stream[i + 2][0] != 'word'
                or stream[i + 3][1] != '('):
            continue
        balance = 1
        j = i + 4
        fields = set()
        while balance:
            if j >= len(stream):
                raise ValueError('unterminated Dart call')
            kind, value, _ = stream[j]
            if (kind == 'word' and balance == 1 and j + 1 < len(stream)
                    and stream[j + 1][1] == ':' and (j == i + 4 or stream[j - 1][1] == ',')):
                fields.add(value)
            if kind == 'punct':
                balance += int(value in '([{') - int(value in ')]}')
            j += 1
        yield stream[i + 2][1], fields, source.count('\n', 0, stream[i][2]) + 1


def rust_structs(source):
    stream = list(production_tokens(source))
    depth = 0
    for i in range(len(stream) - 3):
        _, value, _, _ = stream[i]
        if depth == 0 and [t[1] for t in stream[i:i + 2]] == ['pub', 'struct']:
            name = stream[i + 2][1]
            if stream[i + 3][1] == '{':
                j, balance, start = i + 4, 1, i + 4
                fields = []
                while balance:
                    kind, word, _, _ = stream[j]
                    if kind == 'punct':
                        if word == ',' and balance == 1:
                            fields.append(stream[start:j])
                            start = j + 1
                        balance += int(word in '(<[{') - int(word in ')>]}')
                    if balance == 0:
                        fields.append(stream[start:j])
                    j += 1
                allowed, required = set(), set()
                for field in fields:
                    for n in range(len(field) - 2):
                        if [t[1] for t in field[n:n + 1]] == ['pub'] and field[n + 2][1] == ':':
                            label = camel(field[n + 1][1])
                            kind = ''.join(t[1] for t in field[n + 3:])
                            allowed.add(label)
                            if not kind.startswith('Option<'):
                                required.add(label)
                            break
                if allowed:
                    yield name, (allowed, required)
        if stream[i][0] == 'punct':
            depth += int(value == '{') - int(value == '}')


def dto_audit(source, structs):
    imports = re.findall(r"import\s+['\"](?:[^'\"]*/)?src/rust/[^'\"]+\.dart['\"](.*?);", source, re.DOTALL)
    aliases = {m[1] for clause in imports if (m := re.search(r'\bas\s+(\w+)', clause))}
    unaliased = any(not re.search(r'\bas\s+', clause) for clause in imports)
    stream = list(dart_tokens(source))
    for i in range(len(stream) - 1):
        if stream[i][0] != 'word' or stream[i][1] not in structs or stream[i + 1][1] != '(':
            continue
        if i >= 2 and stream[i - 1][1] == '.':
            if stream[i - 2][1] not in aliases:
                continue
        elif not unaliased:
            continue
        balance, fields, j = 1, set(), i + 2
        while balance:
            kind, value, _ = stream[j]
            if (kind == 'word' and balance == 1 and stream[j + 1][1] == ':'
                    and (j == i + 2 or stream[j - 1][1] == ',')):
                fields.add(value)
            if kind == 'punct':
                balance += int(value in '([{') - int(value in ')]}')
            j += 1
        name = stream[i][1]
        allowed, required = structs[name]
        unknown, missing = fields - allowed, required - fields
        if unknown or missing:
            yield source.count('\n', 0, stream[i][2]) + 1, name, f'unknown={sorted(unknown)} missing={sorted(missing)}'


def audit(source, signatures):
    # Restrict to actual api.dart imports; do not guess another Rust module's
    # namespace or confuse data-class constructors with top-level functions.
    aliases = set(re.findall(r"import\s+['\"](?:[^'\"]*/)?src/rust/api\.dart['\"]\s+as\s+(\w+)\s*;", source))
    for name, fields, line in dart_calls(source, aliases):
        # Uppercase names are generated DTO constructors, not API calls.
        if name[:1].isupper():
            continue
        if name not in signatures:
            yield line, name, 'no public Rust function'
            continue
        allowed, required = signatures[name]
        unknown, missing = fields - allowed, required - fields
        if unknown or missing:
            yield line, name, f'unknown={sorted(unknown)} missing={sorted(missing)}'


def main():
    signatures = rust_signatures((ROOT / 'crates/frb-bridge/src/api.rs').read_text())
    structs, ambiguous = {}, set()
    for path in (ROOT / 'crates/frb-bridge/src').rglob('*.rs'):
        if path.name.startswith('frb_generated'):
            continue
        for name, fields in rust_structs(path.read_text()):
            if name in structs and structs[name] != fields:
                ambiguous.add(name)
            structs[name] = fields
    for name in ambiguous:
        structs.pop(name, None)
    count = failures = 0
    for folder in ('lib', 'test', 'integration_test'):
        for path in sorted((ROOT / 'ui_flutter' / folder).rglob('*.dart')):
            if 'src/rust' in path.as_posix():
                continue
            source = path.read_text()
            for line, name, message in [*audit(source, signatures), *dto_audit(source, structs)]:
                print(f'{path.relative_to(ROOT)}:{line}: {name}: {message}')
                failures += 1
            count += 1
    print(f'Source-only API audit: {len(signatures)} Rust functions, {len(structs)} unique bridge DTOs, {count} Dart files, {failures} findings. No builds/tests run.')
    return int(failures != 0)


if __name__ == '__main__':
    sys.exit(main())
