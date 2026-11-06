import json, os, stat, sys

# Fixed read-only directory-size walk for the properties dialog (like the
# server's own file manager): one local scandir walk, no shell, no writes.
# argv[1] is the absolute directory; output is one JSON line on stdout.

root = sys.argv[1]
if not root.startswith('/') or '\x00' in root or len(root) > 16384:
    print(json.dumps({'error': 'path'}))
    sys.exit(0)

size = 0
files = 0
dirs = 1
entries = 0
stack = [root]
depth = {root: 0}

while stack:
    path = stack.pop()
    try:
        with os.scandir(path) as it:
            for entry in it:
                entries += 1
                if entries > 1000000:
                    print(json.dumps({'error': 'capacity'}))
                    sys.exit(0)
                try:
                    info = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISLNK(info.st_mode):
                    continue
                if stat.S_ISDIR(info.st_mode):
                    dirs += 1
                    level = depth.get(path, 0) + 1
                    if level <= 128:
                        depth[entry.path] = level
                        stack.append(entry.path)
                else:
                    files += 1
                    try:
                        size += info.st_size
                    except OverflowError:
                        pass
    except OSError as error:
        print(json.dumps({'error': 'io', 'kind': error.errno}))
        sys.exit(0)

print(json.dumps({'size': size, 'files': files, 'dirs': dirs}))
