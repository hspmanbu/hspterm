/// Test-only real SSH subsystem. All payloads are synthetic; CLOSE deliberately
/// fails so a fully read preview must never be published as successful.
const closeFailureSftp = r'''
import struct,sys
stdin=sys.stdin.buffer
stdout=sys.stdout.buffer
payload=b'controlled preview close fixture'
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
    if kind==16:
        send(104,request+u32(1)+string(b'/fixture.txt')+string(b'')+attrs())
    elif kind in (7,8,17):
        send(105,request+attrs())
    elif kind==3:
        send(102,request+string(b'fixture'))
    elif kind==5:
        handle_length=struct.unpack('>I',body[:4])[0]
        pos=4+handle_length
        offset=struct.unpack('>Q',body[pos:pos+8])[0]
        count=struct.unpack('>I',body[pos+8:pos+12])[0]
        send(103,request+string(payload[offset:offset+count]))
    else:
        send(101,request+u32(4 if kind==4 else 8)+string(b'controlled CLOSE failure')+string(b''))
''';
