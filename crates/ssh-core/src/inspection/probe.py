# Application-owned fixed SSH exec body; never installed on the server.
# Python isolated mode, no subprocesses, command lines, environment or user files.
import json
import os
import signal
import sys
import time


def read(path, limit=65536):
    with open(path, 'rb') as stream:
        value = stream.read(limit + 1)
    if len(value) > limit:
        raise ValueError('capacity')
    return value


def boot():
    return read('/proc/sys/kernel/random/boot_id', 64).decode('ascii').strip()


def process(pid):
    row = read('/proc/%d/stat' % pid, 4096)
    a, b = row.index(b'('), row.rindex(b')')
    fields = row[b + 2:].split()
    # /proc stat fields 3, 14/15, 22 and 24; comm may include spaces or ')'.
    name = row[a + 1:b].decode('utf-8', 'replace')
    name = ''.join(c for c in name if c.isprintable() and not 0x202a <= ord(c) <= 0x202e and not 0x2066 <= ord(c) <= 0x2069)[:64]
    return dict(pid=pid, name=name, state=fields[0].decode('ascii'),
                start=int(fields[19]), ticks=int(fields[11]) + int(fields[12]),
                rss=max(0, int(fields[21])) * os.sysconf('SC_PAGE_SIZE'),
                uid=os.stat('/proc/%d' % pid).st_uid)



def network():
    # Measure the default egress, not every stacked bridge/veth/tunnel. Summing
    # /proc/net/dev counts the same packet at several virtual interfaces.
    def unavailable():
        return '', 0, 0, time.monotonic_ns() // 1000000

    devices = {}
    try:
        for line in read('/proc/net/dev').splitlines()[2:]:
            device, values = line.rsplit(b':', 1)
            fields = values.split()
            if device.strip() != b'lo' and len(fields) >= 9:
                devices[device.strip()] = fields
    except (OSError, ValueError):
        return unavailable()

    candidates = []
    try:
        for line in read('/proc/net/route').splitlines()[1:]:
            fields = line.split()
            if (len(fields) >= 8 and fields[0] in devices and fields[1] == b'00000000'
                    and fields[7] == b'00000000' and int(fields[3], 16) & 1
                    and not int(fields[3], 16) & 0x200):
                candidates.append((int(fields[6]), fields[0]))
    except (OSError, ValueError):
        candidates.clear()
    # Prefer IPv4 when present; otherwise use the lowest-metric IPv6 default.
    # One stable scope also avoids counting a tunneled IPv6 path plus its wire.
    if not candidates:
        try:
            for line in read('/proc/net/ipv6_route').splitlines():
                fields = line.split()
                if (len(fields) == 10 and fields[9] in devices and fields[0] == b'0' * 32
                        and fields[1] == b'00' and int(fields[8], 16) & 1
                        and not int(fields[8], 16) & 0x200):
                    candidates.append((int(fields[5], 16), fields[9]))
        except (OSError, ValueError):
            return unavailable()
    if not candidates:
        # No trustworthy interface: an empty identity yields unavailable rates.
        return unavailable()
    best = min(metric for metric, _ in candidates)
    names = sorted({name for metric, name in candidates if metric == best})
    identities, rx, tx = [], 0, 0
    for name in names:
        # ifindex detects a removed/recreated interface even with the same name.
        try:
            text = name.decode('ascii')
            if not text or len(text) > 15 or any(c not in
                    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-'
                    for c in text):
                return unavailable()
            index = int(read('/sys/class/net/%s/ifindex' % text, 32))
            received, sent = int(devices[name][0]), int(devices[name][8])
            if index <= 0 or received < 0 or sent < 0:
                return unavailable()
        except (OSError, ValueError):
            return unavailable()
        identities.append('%s:%d' % (text, index))
        rx += received
        tx += sent
    return ','.join(identities), rx, tx, time.monotonic_ns() // 1000000


def run():
    action = sys.argv[1]
    identity = boot()
    if action == 'sample':
        with open('/proc/stat', 'rb') as stream:
            line = stream.readline(4097)
        if len(line) > 4096 or not line.startswith(b'cpu '):
            raise ValueError('cpu')
        cpu = [int(n) for n in line.split()[1:9]]
        mem = {}
        for line in read('/proc/meminfo').splitlines():
            key, value = line.split(b':', 1)
            if key in (b'MemTotal', b'MemAvailable'):
                mem[key] = int(value.split()[0]) * 1024
        net, rx, tx, millis = network()
        disk = os.statvfs('/')
        return dict(version=1, boot=identity, millis=millis, network=net,
                    cpu_total=sum(cpu), cpu_idle=cpu[3] + cpu[4], cpu_iowait=cpu[4],
                    memory_total=mem[b'MemTotal'], memory_available=mem[b'MemAvailable'],
                    disk_total=disk.f_blocks * disk.f_frsize,
                    disk_available=disk.f_bavail * disk.f_frsize,
                    rx=rx, tx=tx)
    if action == 'processes':
        result = []
        scanned = 0
        truncated = False
        skipped = 0
        # Stream scandir rather than materializing an unbounded process list.
        with os.scandir('/proc') as entries:
            for entry in entries:
                if not entry.name.isascii() or not entry.name.isdecimal():
                    continue
                scanned += 1
                if scanned > 4096 or len(result) == 512:
                    truncated = True
                    break
                pid = int(entry.name)
                if pid == os.getpid():
                    continue
                try:
                    result.append(process(pid))
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    skipped += 1
        result.sort(key=lambda row: row['pid'])
        return dict(version=1, boot=identity, processes=result, truncated=truncated, skipped=skipped,
                    can_signal=hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'))
    if action == 'terminate':
        pid, started, expected_boot = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
        if pid <= 1 or pid == os.getpid() or expected_boot != identity:
            raise ValueError('identity')
        if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            raise ValueError('pidfd unavailable')
        # Open first, verify current process creation identity, then signal this
        # exact descriptor. PID reuse between verification and signal is harmless.
        descriptor = os.pidfd_open(pid, 0)
        try:
            if process(pid)['start'] != started:
                raise ValueError('identity')
            signal.pidfd_send_signal(descriptor, signal.SIGTERM, None, 0)
        finally:
            os.close(descriptor)
        return dict(version=1, sent=True)
    raise ValueError('action')


try:
    print(json.dumps(run(), ensure_ascii=True, separators=(',', ':')))
except Exception:
    # No tracebacks, process names or raw platform error payloads over SSH.
    sys.exit(65)
