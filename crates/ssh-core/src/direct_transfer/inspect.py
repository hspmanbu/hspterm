# Appended after receipt.py. Read-only: no claim, truncation, process signals,
# checkpoint changes or writes. A missing/invalid receipt is never "complete".
import base64
import sys


def inspect(request):
    fd = None
    result = {'version': 1, 'status': 'unavailable', 'attempt': None, 'bytes': 0}
    try:
        if set(request) != {'staged', 'bytes', 'nonce'}:
            return result
        path, size = request['staged'], request['bytes']
        if (not isinstance(path, str) or not path.startswith('/') or '\0' in path or len(path) > 16384
                or type(size) is not int or size < 0 or os.path.realpath(os.path.dirname(path)) != os.path.dirname(path)):
            return result
        nonce = base64.b64decode(request['nonce'], validate=True)
        if len(nonce) != 32:
            return result
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            result['status'] = 'busy'
            return result
        attrs = os.fstat(fd)
        if not stat.S_ISREG(attrs.st_mode) or stat.S_IMODE(attrs.st_mode) != 0o600:
            return result
        record = read_record(fd)
        if record is None:
            if attrs.st_size == 32 and hmac.compare_digest(os.read(fd, 33), nonce):
                result['status'] = 'unclaimed'
            return result
        if not authenticate(record, attrs, size, nonce) or attrs.st_size > size:
            return result
        result['attempt'] = record['attempt']
        if group_alive(record['pgid']):
            result['status'] = 'busy'
        elif record['state'] == 'complete' and attrs.st_size == size:
            result.update(status='complete', bytes=size)
        elif record['state'] == 'writing':
            result.update(status='partial', bytes=attrs.st_size)
        return result
    except (OSError, ValueError, TypeError, KeyError):
        return result
    finally:
        if fd is not None:
            os.close(fd)


if __name__ == '__main__':
    result = {'version': 1, 'status': 'unavailable', 'attempt': None, 'bytes': 0}
    try:
        if len(sys.argv) == 2 and len(sys.argv[1]) <= 32768:
            result = inspect(json.loads(base64.b64decode(sys.argv[1], validate=True)))
    except (ValueError, TypeError):
        pass
    print(json.dumps(result, separators=(',', ':')))
