# Appended after receipt.py. Only the existing one-use private staging inode
# may be changed. No final destination or source deletion is accepted here.
import base64
import shutil
import signal
import subprocess
import sys


def main():
    fd = parent_fd = process = None
    previous_handlers = {}
    try:
        if len(sys.argv) < 3 or sys.argv[2] != '--server' or '--sender' in sys.argv[2:] or '--daemon' in sys.argv[2:]:
            return 1
        request = json.loads(base64.b64decode(sys.argv[1], validate=True))
        if set(request) != {'staged', 'bytes', 'nonce', 'attempt', 'previous'}:
            return 1
        path, size = request['staged'], request['bytes']
        attempt, expected = request['attempt'], request['previous']
        if (not isinstance(path, str) or not path.startswith('/') or '\0' in path or len(path) > 16384
                or type(size) is not int or size < 0 or type(attempt) is not int or not 0 < attempt < 2 ** 64
                or expected is not None and (type(expected) is not int or not 0 < expected < attempt)
                or not os.path.basename(path).startswith('.hspterm-copy-') or not path.endswith('.part')
                or os.path.realpath(os.path.dirname(path)) != os.path.dirname(path)):
            return 1
        executable = shutil.which('rsync', path=os.defpath)
        if executable is None or not os.path.isdir('/proc/self/fd'):
            return 1
        nonce = base64.b64decode(request['nonce'], validate=True)
        if len(nonce) != 32:
            return 1
        parent_fd = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        if parent_fd != 3:
            os.dup2(parent_fd, 3)
            os.close(parent_fd)
            parent_fd = 3
        fd = os.open(os.path.basename(path), os.O_RDWR | os.O_NOFOLLOW, dir_fd=parent_fd)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        attrs = os.fstat(fd)
        if not stat.S_ISREG(attrs.st_mode) or stat.S_IMODE(attrs.st_mode) != 0o600:
            return 1
        record = read_record(fd)
        if expected is None:
            if record is not None or attrs.st_size != 32 or not hmac.compare_digest(os.read(fd, 33), nonce):
                return 1
            record = {'version': 1, 'tag': '', 'device': attrs.st_dev,
                      'inode': attrs.st_ino, 'size': size, 'attempt': attempt, 'pgid': 0, 'state': 'writing'}
            # Claim before truncating. Delayed original attempts cannot claim a
            # file that another attempt has already authenticated/claimed.
            write_record(fd, record, nonce, initial=True)
            os.ftruncate(fd, 0)
        else:
            if (not authenticate(record, attrs, size, nonce) or record['state'] != 'writing'
                    or record['attempt'] != expected or group_alive(record['pgid']) or attrs.st_size > size):
                return 1
            record.update(attempt=attempt, pgid=0)
            write_record(fd, record, nonce)
            # Keep all partial bytes as the rsync delta basis. Their length is
            # NOT a contiguous acknowledged prefix and is never appended blindly.
        original = (attrs.st_dev, attrs.st_ino)
        os.set_inheritable(parent_fd, True)
        process = subprocess.Popen([executable] + sys.argv[2:], pass_fds=(parent_fd,),
                                   env={'PATH': os.defpath, 'LC_ALL': 'C'}, close_fds=True,
                                   start_new_session=True)
        record['pgid'] = process.pid
        write_record(fd, record, nonce)

        def stop_group(signum, frame):
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                finally:
                    process.wait()
            raise SystemExit(1)
        previous_handlers = {sig: signal.signal(sig, stop_group) for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
        result = process.wait()
        attrs = os.fstat(fd)
        current = os.stat(os.path.basename(path), dir_fd=parent_fd, follow_symlinks=False)
        if (result != 0 or attrs.st_size != size or not authenticate(record, attrs, size, nonce)
                or (current.st_dev, current.st_ino) != original
                or not stat.S_ISREG(current.st_mode) or stat.S_IMODE(current.st_mode) != 0o600):
            return 1
        os.fsync(fd)
        record['state'] = 'complete'
        write_record(fd, record, nonce)
        return 0
    except (OSError, ValueError, TypeError, KeyError):
        return 1
    finally:
        # A live unreaped child PID cannot be reused here. Never kill a numeric
        # process group after its leader has already been reaped and recycled.
        if process is not None and process.returncode is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            finally:
                process.wait()
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
        if fd is not None:
            os.close(fd)
        if parent_fd is not None:
            os.close(parent_fd)


if __name__ == '__main__':
    sys.exit(main())
