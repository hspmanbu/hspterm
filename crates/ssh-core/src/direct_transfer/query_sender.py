# Appended to fixed probe helpers; only a bounded authenticated receipt returns.
import selectors
import time


def query(request):
    process = None
    selector = selectors.DefaultSelector()
    try:
        endpoint = request['endpoint']
        ssh = shutil.which('ssh', path=os.defpath)
        python = shutil.which('python3', path=os.defpath)
        socket = os.environ.get('SSH_AUTH_SOCK', '')
        if not ssh or not python or not socket or not stat.S_ISSOCK(os.stat(socket).st_mode):
            raise ValueError('unavailable')
        environment = authentication_environment(socket, python)
        metadata = base64.b64encode(json.dumps({key: request[key] for key in ('staged', 'bytes', 'nonce')}).encode()).decode()
        argv = ssh_arguments(endpoint, ssh, python)
        argv[-1] = '/usr/bin/python3 -I -S -c ' + shlex.quote(request['inspect']) + ' ' + shlex.quote(metadata)
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   env=environment, start_new_session=True, close_fds=True)
        selector.register(process.stdout, selectors.EVENT_READ)
        until = time.monotonic() + 7
        output = bytearray()
        while True:
            remaining = until - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise TimeoutError('unavailable')
            data = os.read(process.stdout.fileno(), 4097 - len(output))
            if not data:
                break
            output.extend(data)
            if len(output) > 4096:
                raise ValueError('unavailable')
        if process.wait(timeout=max(0.001, until - time.monotonic())) != 0:
            raise ValueError('unavailable')
        return bytes(output)
    finally:
        selector.close()
        if process is not None:
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                finally:
                    process.wait()
            if process.stdout is not None:
                process.stdout.close()


if __name__ == '__main__':
    output = b'{"version":1,"status":"unavailable","attempt":null,"bytes":0}'
    try:
        if len(sys.argv) == 2 and len(sys.argv[1]) <= 100000:
            output = query(json.loads(base64.b64decode(sys.argv[1], validate=True)))
    except (OSError, ValueError, TypeError, KeyError, TimeoutError, subprocess.TimeoutExpired):
        pass
    sys.stdout.buffer.write(output)
