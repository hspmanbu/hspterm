import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Disposable loopback relay with synthetic authentication and no external DNS.
class LocalProxy {
  LocalProxy(this.process, this.port, this.trafficHold);
  final Process process;
  final int port;
  final File trafficHold;
  Future<void> holdTraffic() => trafficHold.writeAsString('hold').then((_) {});
  Future<void> resumeTraffic() async {
    if (await trafficHold.exists()) await trafficHold.delete();
  }

  static Future<LocalProxy> start(
    Directory directory,
    int targetPort, {
    required bool socks5,
  }) async {
    final file = File(
      '${directory.path}/proxy-${socks5 ? 'socks' : 'http'}.py',
    );
    await file.writeAsString(_script);
    final process = await Process.start('/usr/bin/python3', [
      '-u',
      file.path,
      '$targetPort',
      socks5 ? 'socks' : 'http',
      '${file.path}.hold',
    ]);
    unawaited(process.stderr.drain<void>());
    try {
      final port = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      return LocalProxy(process, int.parse(port), File('${file.path}.hold'));
    } catch (_) {
      process.kill();
      await process.exitCode;
      rethrow;
    }
  }

  Future<void> close() async {
    process.kill();
    await process.exitCode;
  }
}

const _script = r'''
import base64, os, select, socket, socketserver, sys, time
port, kind = int(sys.argv[1]), sys.argv[2]
hold = sys.argv[3]
def exact(stream, n):
    data = b''
    while len(data) < n:
        part = stream.recv(n-len(data))
        if not part: raise EOFError()
        data += part
    return data
class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(10)
        try:
            if kind == 'http':
                header = b''
                while not header.endswith(b'\r\n\r\n'):
                    header += exact(client, 1)
                    if len(header) > 8192: return
                expected = ('CONNECT ssh-via-proxy.invalid:%d HTTP/1.1\r\nHost: ssh-via-proxy.invalid:%d\r\n' % (port, port)).encode()
                auth = b'Proxy-Authorization: Basic ' + base64.b64encode(b'fixture-user:fixture-password') + b'\r\n\r\n'
                if header != expected + auth:
                    client.sendall(b'HTTP/1.1 407 Denied\r\n\r\n')
                    return
                client.sendall(b'HTTP/1.1 200 OK\r\n\r\n')
            else:
                if exact(client, 3) != b'\x05\x01\x02': return
                client.sendall(b'\x05\x02')
                if exact(client, 1) != b'\x01': return
                user = exact(client, exact(client, 1)[0])
                password = exact(client, exact(client, 1)[0])
                if user != b'fixture-user' or password != b'fixture-password':
                    client.sendall(b'\x01\x01')
                    return
                client.sendall(b'\x01\x00')
                if exact(client, 4) != b'\x05\x01\x00\x03': return
                if exact(client, exact(client, 1)[0]) != b'ssh-via-proxy.invalid': return
                if int.from_bytes(exact(client, 2), 'big') != port: return
                client.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
            with socket.create_connection(('127.0.0.1', port), timeout=10) as remote:
                client.settimeout(None)
                remote.settimeout(None)
                while True:
                    if os.path.exists(hold):
                        time.sleep(.02)
                        continue
                    readable, _, _ = select.select([client, remote], [], [], 10)
                    if os.path.exists(hold): continue
                    for source in readable:
                        data = source.recv(65536)
                        if not data: return
                        (remote if source is client else client).sendall(data)
        except (OSError, EOFError):
            pass
class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
with Server(('127.0.0.1', 0), Relay) as server:
    print(server.server_address[1], flush=True)
    server.serve_forever()
''';
