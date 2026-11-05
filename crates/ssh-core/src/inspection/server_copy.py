# Fixed same-server copy. Arguments are JSON hex, not shell source. File bytes
# remain on the server. Exclusive destination creation; no symlink traversal.
import json, os, stat, sys
request = json.loads(bytes.fromhex(sys.argv[1]))
src, dst, marker, nonce = (request[k] for k in ('source', 'destination', 'marker', 'nonce'))
assert all(isinstance(p, str) and p.startswith('/') and '\0' not in p and len(p.encode()) <= 16384 for p in (src, dst, marker))
assert len(nonce) == 64 and all(c in '0123456789abcdef' for c in nonce)
with open(marker, 'rb') as f:
    assert f.read(33) == bytes.fromhex(nonce), 'SFTP/SSH namespace proof failed'
expected = request['metadata']
actual = os.lstat(src)
for field, current in [('size', actual.st_size), ('mtime', int(actual.st_mtime)), ('permissions', actual.st_mode), ('uid', actual.st_uid), ('gid', actual.st_gid)]:
    if expected.get(field) is not None:
        assert expected[field] == current, 'source metadata/namespace changed'
source_root = os.path.realpath(src)
target_root = os.path.realpath(os.path.dirname(dst))
assert src != dst and target_root != source_root and not target_root.startswith(source_root.rstrip('/') + '/')
count = 0
def copy(parent, name, output_parent, output_name, depth):
    global count
    count += 1
    assert count <= 1000000 and depth <= 128
    attrs = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if stat.S_ISLNK(attrs.st_mode):
        os.symlink(os.readlink(name, dir_fd=parent), output_name, dir_fd=output_parent)
    elif stat.S_ISDIR(attrs.st_mode):
        source = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        target = None
        try:
            os.mkdir(output_name, 0o777, dir_fd=output_parent)
            target = os.open(output_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=output_parent)
            with os.scandir(source) as entries:
                for entry in entries:
                    copy(source, entry.name, target, entry.name, depth + 1)
        finally:
            os.close(source)
            if target is not None: os.close(target)
    else:
        assert stat.S_ISREG(attrs.st_mode), 'special files are not copied'
        source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        target = None
        try:
            assert stat.S_ISREG(os.fstat(source).st_mode)
            target = os.open(output_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666, dir_fd=output_parent)
            while True:
                block = os.read(source, 65536)
                if not block: break
                offset = 0
                while offset < len(block):
                    written = os.write(target, block[offset:])
                    assert written > 0
                    offset += written
            os.fsync(target)
        finally:
            os.close(source)
            if target is not None: os.close(target)
source = os.open(os.path.dirname(src), os.O_RDONLY | os.O_DIRECTORY)
target = os.open(os.path.dirname(dst), os.O_RDONLY | os.O_DIRECTORY)
try:
    copy(source, os.path.basename(src), target, os.path.basename(dst), 0)
finally:
    os.close(source); os.close(target)
print('\nHSPTERM_SERVER_COPY_V1_' + nonce + '\n', end='')
