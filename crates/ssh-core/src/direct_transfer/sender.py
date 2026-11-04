# Appended to the fixed probe helpers. Only public endpoint/path metadata enters
# argv. File bytes go directly between these two servers, never via Flutter/FRB.
import shlex


def transfer(request):
    if set(request) != {'endpoint', 'source', 'staged', 'bytes', 'receiver', 'nonce', 'attempt', 'previous'}:
        return 'unconfirmed'
    endpoint = request['endpoint']
    source, staged, size = request['source'], request['staged'], request['bytes']
    if (not isinstance(source, str) or not source.startswith('/') or '\0' in source
            or len(source) > 16384 or not isinstance(staged, str) or len(staged) > 16384
            or not staged.startswith('/') or '\0' in staged or type(size) is not int or size < 0):
        return 'unconfirmed'
    if os.path.realpath(os.path.dirname(source)) != os.path.dirname(source):
        return 'unconfirmed'
    socket = os.environ.get('SSH_AUTH_SOCK', '')
    if not socket or not stat.S_ISSOCK(os.stat(socket).st_mode):
        return 'unconfirmed'
    ssh = shutil.which('ssh', path=os.defpath)
    rsync = shutil.which('rsync', path=os.defpath)
    python = shutil.which('python3', path=os.defpath)
    if not ssh or not rsync or not python:
        return 'unconfirmed'
    environment = {'PATH': os.defpath, 'LC_ALL': 'C', 'SSH_AUTH_SOCK': socket,
                   'SSH_ASKPASS_REQUIRE': 'never'}
    # Reuse all pinned SSH options; rsync supplies the single fixed host alias
    # and generated receiver command instead of the probe's final two arguments.
    ssh_argv = ssh_arguments(endpoint, ssh, python)[:-3]
    ssh_argv.extend(['-o', 'Hostname=' + endpoint['address']])
    bridge = ('import base64,json,os,sys;'
              'a=json.loads(base64.b64decode(sys.argv[1]));'
              'os.execve(a[0],a+sys.argv[2:],dict(os.environ))')
    encoded_ssh = base64.b64encode(json.dumps(ssh_argv).encode()).decode()
    rsh = ' '.join(shlex.quote(a) for a in [python, '-I', '-S', '-c', bridge, encoded_ssh])
    receiver_request = base64.b64encode(json.dumps({'staged': staged, 'bytes': size, 'nonce': request['nonce'],
                                                  'attempt': request['attempt'], 'previous': request['previous']}).encode()).decode()
    receiver = ' '.join(shlex.quote(a) for a in ['/usr/bin/python3', '-I', '-S', '-c', request['receiver'], receiver_request])
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    process = None
    try:
        attrs = os.fstat(fd)
        if not stat.S_ISREG(attrs.st_mode) or attrs.st_size != size:
            return 'unconfirmed'
        # rsync follows only this owned /proc FD link, not an arbitrary source
        # pathname replaced between metadata and body reads.
        os.set_inheritable(fd, True)
        argv = [rsync, '--protect-args', '--inplace', '--ignore-times', '--copy-links', '--timeout=30',
                '--no-perms', '--no-owner', '--no-group', '--no-times',
                '--rsh=' + rsh, '--rsync-path=' + receiver,
                '--', '/proc/self/fd/' + str(fd), 'hspterm-direct-target:/proc/self/fd/3/' + os.path.basename(staged)]
        process = subprocess.Popen(argv, pass_fds=(fd,), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   env=environment, start_new_session=True, close_fds=True)
        def stop_group(signum, frame):
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                finally:
                    process.wait()
            raise SystemExit(1)
        previous = {sig: signal.signal(sig, stop_group) for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
        try:
            # rsync's own 30-second I/O-idle timeout and SSH liveness checks bound
            # stalled peers. A healthy large file has no arbitrary one-hour cap.
            result = process.wait()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        return 'copied' if result == 0 else 'unconfirmed'
    finally:
        # Only an unreaped child is ours to signal; a recycled numeric PID is not.
        if process is not None and process.returncode is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            finally:
                process.wait()
        os.close(fd)


def main():
    status = 'unconfirmed'
    try:
        if len(sys.argv) == 2 and len(sys.argv[1]) <= 100000:
            status = transfer(json.loads(base64.b64decode(sys.argv[1], validate=True)))
    except (OSError, ValueError, TypeError, KeyError):
        pass
    print(json.dumps({'version': 1, 'status': status}, separators=(',', ':')))


if __name__ == '__main__':
    main()
