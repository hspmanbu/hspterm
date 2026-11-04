/// Test-only OpenSSH SFTP proxy. Performs the real server operation, then drops
/// only its successful RENAME response. No payloads or credentials are logged.
const lostRenameReplySftp = r'''
import os,select,struct,subprocess,threading
server=subprocess.Popen(['/usr/lib/openssh/sftp-server'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
pending=set()
gate=threading.Lock()
def exact(fd,n):
    result=bytearray()
    while len(result)<n:
        part=os.read(fd,n-len(result))
        if not part:
            if result: raise RuntimeError('truncated fixture packet')
            return None
        result.extend(part)
    return bytes(result)
def frame(fd):
    header=exact(fd,4)
    if header is None: return None
    length=struct.unpack('>I',header)[0]
    if length<1 or length>1024*1024: raise RuntimeError('fixture packet capacity')
    body=exact(fd,length)
    if body is None: raise RuntimeError('missing fixture payload')
    return header+body
def write(fd,data):
    while data:
        count=os.write(fd,data)
        if count<=0: raise RuntimeError('fixture pipe closed')
        data=data[count:]
def requests():
    try:
        while True:
            packet=frame(0)
            if packet is None:
                server.stdin.close()
                return
            if packet[4]==18:
                with gate: pending.add(packet[5:9])
            if packet[4]==7 and os.path.exists(__file__+'.hold-inspection'):
                fd=os.open(__file__+'.inspection-gate',os.O_RDONLY|os.O_NONBLOCK)
                try:
                    marker=os.open(__file__+'.inspection-started',os.O_WRONLY|os.O_CREAT,0o600)
                    os.close(marker)
                    ready,_,_=select.select([fd],[],[],15)
                    if not ready or not os.read(fd,1): raise RuntimeError('inspection gate timeout')
                finally: os.close(fd)
            write(server.stdin.fileno(),packet)
    except (BrokenPipeError,OSError):
        return
    finally:
        server.stdin.close()
threading.Thread(target=requests,daemon=True).start()
try:
    while True:
        packet=frame(server.stdout.fileno())
        if packet is None: break
        with gate:
            rename=packet[4]==101 and packet[5:9] in pending
            if rename: pending.remove(packet[5:9])
        if rename and struct.unpack('>I',packet[9:13])[0]==0:
            marker=os.open(__file__+'.rename-count',os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
            try: write(marker,b'1\n')
            finally: os.close(marker)
            break
        write(1,packet)
finally:
    server.terminate()
    try: server.wait(timeout=2)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()
''';
