/// Real SSH subsystem with synthetic memory content. Read CLOSE succeeds;
/// write CLOSE fails even after all WRITE/FSTAT responses were successful.
const editorCloseFailureSftp = r'''
import struct,sys
stdin=sys.stdin.buffer
stdout=sys.stdout.buffer
payload=bytearray(b'original controlled editor document')
def u32(n): return struct.pack('>I',n)
def string(data): return u32(len(data))+data
def attrs(): return u32(5)+struct.pack('>Q',len(payload))+u32(0o100600)
def read_exact(n):
    data=b''
    while len(data)<n:
        part=stdin.read(n-len(data))
        if not part: return None
        data+=part
    return data
def send(kind,data):
    packet=bytes([kind])+data
    stdout.write(u32(len(packet))+packet)
    stdout.flush()
def status(request,code=0): send(101,request+u32(code)+string(b'controlled editor status')+string(b''))
while True:
    length=read_exact(4)
    if length is None: break
    length=struct.unpack('>I',length)[0]
    if length>1024*1024: raise RuntimeError('oversized fixture packet')
    packet=read_exact(length)
    if packet is None: break
    kind=packet[0]
    if kind==1:
        send(2,u32(3))
        continue
    request=packet[1:5]
    body=packet[5:]
    if kind==16: send(104,request+u32(1)+string(b'/fixture.txt')+string(b'')+attrs())
    elif kind in (7,8,17): send(105,request+attrs())
    elif kind==3:
        size=struct.unpack('>I',body[:4])[0]
        flags=struct.unpack('>I',body[4+size:8+size])[0]
        if flags&2:
            payload.clear()
            send(102,request+string(b'write'))
        else: send(102,request+string(b'read'))
    elif kind in (5,6):
        size=struct.unpack('>I',body[:4])[0]
        pos=4+size
        offset=struct.unpack('>Q',body[pos:pos+8])[0]
        count=struct.unpack('>I',body[pos+8:pos+12])[0]
        if kind==5: send(103,request+string(payload[offset:offset+count]))
        else:
            data=body[pos+12:pos+12+count]
            if offset+count>len(payload): payload.extend(b'\0'*(offset+count-len(payload)))
            payload[offset:offset+count]=data
            status(request)
    elif kind==4:
        size=struct.unpack('>I',body[:4])[0]
        status(request,4 if body[4:4+size]==b'write' else 0)
    else: status(request,8)
''';
