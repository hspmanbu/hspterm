# Fixed task-authentication broker. Only an unguessable capability arrives on
# encrypted exec stdin. Helpers contain no password, private key or capability.
import atexit
import os
import selectors
import socket as _socket
import stat
import struct
import sys
import tempfile
import threading

_AUTH = None
_AUTH_READ = False
_HELPER = r'''import os,socket,struct,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(8)
s.connect(os.environ['HSPTERM_DIRECT_AUTH_SOCKET']);s.sendall(b'P')
def read(n):
 b=bytearray()
 while len(b)<n:
  x=s.recv(n-len(b))
  if not x: raise OSError('authentication unavailable')
  b.extend(x)
 return bytes(b)
n=struct.unpack('!I',read(4))[0]
if not 5<=n<=65541: sys.exit(1)
r=read(n);s.close()
if r[0]!=6 or struct.unpack('!I',r[1:5])[0]!=len(r)-5 or any(c in r[5:] for c in (0,10,13)): sys.exit(1)
sys.stdout.buffer.write(r[5:]+b'\n');sys.stdout.buffer.flush()
'''


def _read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        part = stream.recv(count - len(result))
        if not part:
            raise OSError('authentication unavailable')
        result.extend(part)
    return bytes(result)


def _frame(stream):
    n = struct.unpack('!I', _read_exact(stream, 4))[0]
    if not 1 <= n <= 262144:
        raise ValueError('authentication frame')
    return _read_exact(stream, n)


class _TaskAuthentication:
    def __init__(self, mode, capability, original, python):
        self.mode, self.capability, self.original = mode, capability, original
        self._stop = threading.Event()
        self._slots = threading.BoundedSemaphore(4)
        self._lock = threading.Lock()
        self._connections = set()
        self._directory = tempfile.TemporaryDirectory(prefix='.hspterm-direct-auth-')
        self.path = os.path.join(self._directory.name, 'agent')
        self.helper = os.path.join(self._directory.name, 'askpass')
        self.server = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
        try:
            # Directory is created 0700; neither socket nor helper is shared.
            self.server.bind(self.path)
            os.chmod(self.path, 0o600)
            self.server.listen(4)
            self.server.settimeout(.25)
            fd = os.open(self.helper, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o700)
            with os.fdopen(fd, 'wb') as out:
                out.write(('#!' + python + '\n' + _HELPER).encode())
            self.thread = threading.Thread(target=self._accept, daemon=True)
            self.thread.start()
        except BaseException:
            self.server.close()
            self._directory.cleanup()
            raise

    def _accept(self):
        while not self._stop.is_set():
            try:
                local, _ = self.server.accept()
            except _socket.timeout:
                continue
            except OSError:
                break
            if not self._slots.acquire(blocking=False):
                local.close()
                continue
            threading.Thread(target=self._serve, args=(local,), daemon=True).start()

    def _serve(self, local):
        remote = None
        try:
            local.settimeout(8)
            with self._lock:
                if self._stop.is_set():
                    return
                self._connections.add(local)
            if self.mode == 1 and _read_exact(local, 1) != b'P':
                return
            remote = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
            remote.settimeout(8)
            remote.connect(self.original)
            with self._lock:
                if self._stop.is_set():
                    return
                self._connections.add(remote)
            name = b'hspterm-direct-auth-v1'
            request = b'\x1b' + struct.pack('!I', len(name)) + name + struct.pack('!I', 32) + self.capability
            remote.sendall(struct.pack('!I', len(request)) + request)
            response = _frame(remote)
            if self.mode == 1:
                if response[:1] != b'\x06':
                    return
                local.sendall(struct.pack('!I', len(response)) + response)
            elif response == b'\x06':
                with selectors.DefaultSelector() as events:
                    events.register(local, selectors.EVENT_READ, remote)
                    events.register(remote, selectors.EVENT_READ, local)
                    while not self._stop.is_set():
                        ready = events.select(8)
                        if not ready:
                            break
                        for key, _ in ready:
                            data = key.fileobj.recv(65536)
                            if not data:
                                return
                            key.data.sendall(data)
        except (OSError, ValueError, KeyError):
            # No authentication payload or subprocess stderr reaches diagnostics.
            pass
        finally:
            with self._lock:
                self._connections.discard(local)
                if remote is not None:
                    self._connections.discard(remote)
            local.close()
            if remote is not None:
                remote.close()
            self._slots.release()

    def close(self):
        self._stop.set()
        self.server.close()
        with self._lock:
            for stream in self._connections:
                try:
                    stream.shutdown(_socket.SHUT_RDWR)
                except OSError:
                    pass
                stream.close()
        self.thread.join(timeout=1)
        self.capability = b''
        self._directory.cleanup()


def authentication_environment(original, python):
    global _AUTH, _AUTH_READ
    if not _AUTH_READ:
        _AUTH_READ = True
        packet = sys.stdin.buffer.read(42)
        if packet:
            if len(packet) != 41 or packet[:8] != b'HSPAUTH\x01' or packet[8] not in (1, 2):
                raise ValueError('authentication capability')
            if not stat.S_ISSOCK(os.stat(original).st_mode):
                raise ValueError('application socket unavailable')
            _AUTH = _TaskAuthentication(packet[8], packet[9:], original, python)
            atexit.register(_AUTH.close)
    environment = {'PATH': os.defpath, 'LC_ALL': 'C', 'SSH_AUTH_SOCK': original, 'SSH_ASKPASS_REQUIRE': 'never'}
    if _AUTH is not None:
        if _AUTH.mode == 1:
            environment.update(SSH_ASKPASS=_AUTH.helper, SSH_ASKPASS_REQUIRE='force', DISPLAY='hspterm:0',
                               HSPTERM_DIRECT_AUTH_SOCKET=_AUTH.path, SSH_AUTH_SOCK='')
        else:
            environment['SSH_AUTH_SOCK'] = _AUTH.path
    return environment


def authentication_password():
    return _AUTH is not None and _AUTH.mode == 1
