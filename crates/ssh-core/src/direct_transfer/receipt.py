# Fixed Linux receiver receipt helpers. The xattr is atomic, bounded, and stores
# a keyed receipt tag, never the capability or authentication material.
import errno
import fcntl
import hashlib
import hmac
import json
import os
import stat

ATTRIBUTE = 'user.hspterm.direct.v1'


def group_alive(group):
    if type(group) is not int or not 0 < group < 2 ** 31:
        return True
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def read_record(fd):
    try:
        raw = os.getxattr(fd, ATTRIBUTE)
    except OSError as error:
        if error.errno == errno.ENODATA:
            return None
        raise
    if len(raw) > 2048:
        raise ValueError('invalid receipt')
    record = json.loads(raw)
    if (not isinstance(record, dict) or set(record) != {'version', 'tag', 'device', 'inode', 'size', 'attempt', 'pgid', 'state'}
            or type(record['version']) is not int or record['version'] != 1 or record['state'] not in ('writing', 'complete')
            or not isinstance(record['tag'], str) or len(record['tag']) != 64
            or any(type(record[key]) is not int or record[key] < 0 for key in ('device', 'inode', 'size', 'attempt', 'pgid'))
            or not 0 < record['attempt'] < 2 ** 64 or not 0 <= record['pgid'] < 2 ** 31):
        raise ValueError('invalid receipt')
    return record


def authenticate(record, attrs, size, nonce):
    return (record is not None and stat.S_ISREG(attrs.st_mode)
            and stat.S_IMODE(attrs.st_mode) == 0o600
            and record['device'] == attrs.st_dev and record['inode'] == attrs.st_ino
            and record['size'] == size
            and hmac.compare_digest(record['tag'], record_tag(record, nonce)))


def record_tag(record, nonce):
    fields = {key: value for key, value in record.items() if key != 'tag'}
    data = b'HSPTerm/direct/receipt/v1\0' + json.dumps(fields, sort_keys=True, separators=(',', ':')).encode()
    return hmac.new(nonce, data, hashlib.sha256).hexdigest()


def write_record(fd, record, nonce, initial=False):
    record['tag'] = record_tag(record, nonce)
    raw = json.dumps(record, separators=(',', ':')).encode()
    if len(raw) > 2048:
        raise ValueError('invalid receipt')
    os.setxattr(fd, ATTRIBUTE, raw, flags=os.XATTR_CREATE if initial else os.XATTR_REPLACE)
    os.fsync(fd)
