import 'dart:async';
import 'dart:io';

/// Isolated real OpenSSH server: ephemeral port, disposable identity and no PAM.
class LocalSshd {
  LocalSshd(
    this.directory,
    this.process,
    this.port,
    this.username,
    this.privateKey,
  );
  final Directory directory;
  final Process process;
  final int port;
  final String username, privateKey;
  static Future<LocalSshd> start({
    String? sftpFixture,
    bool agentForwarding = true,
    bool rsaKeys = false,
    String? tmuxDirectory,
  }) async {
    if (tmuxDirectory != null &&
        (!tmuxDirectory.startsWith('/') ||
            RegExp(r'[\s\x00-\x1f]').hasMatch(tmuxDirectory))) {
      throw StateError(
        'tmux test namespace must be an explicit safe absolute path',
      );
    }
    final dir = await Directory.systemTemp.createTemp('hspterm-flutter-sshd-');
    Process? server;
    try {
      Future<String> run(String command, List<String> args) async {
        final result = await Process.run(command, args);
        if (result.exitCode != 0) {
          throw StateError('$command failed: ${result.stderr}');
        }
        return result.stdout.toString().trim();
      }

      final username = await run('id', ['-un']);
      await run('ssh-keygen', [
        '-q',
        '-t',
        rsaKeys ? 'rsa' : 'ed25519',
        if (rsaKeys) ...['-b', '2048'],
        '-N',
        '',
        '-f',
        '${dir.path}/host',
      ]);
      await run('ssh-keygen', [
        '-q',
        '-t',
        rsaKeys ? 'rsa' : 'ed25519',
        if (rsaKeys) ...['-b', '2048'],
        '-N',
        'test-only-passphrase',
        '-f',
        '${dir.path}/client',
      ]);
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final config = File('${dir.path}/sshd_config');
      var subsystem = 'internal-sftp';
      if (sftpFixture != null) {
        final script = File('${dir.path}/sftp_fixture.py');
        await script.writeAsString(sftpFixture);
        subsystem = '/usr/bin/python3 ${script.path}';
      }
      await config.writeAsString('''Port $port
ListenAddress 127.0.0.1
HostKey ${dir.path}/host
${rsaKeys ? 'HostKeyAlgorithms rsa-sha2-512,rsa-sha2-256\nRekeyLimit 16K' : ''}
PidFile ${dir.path}/pid
AuthorizedKeysFile ${dir.path}/client.pub
StrictModes no
PubkeyAuthentication yes
AllowAgentForwarding ${agentForwarding ? "yes" : "no"}
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PrintLastLog no
PermitRootLogin yes
AllowUsers $username
LogLevel ERROR
SetEnv HOME=${dir.path} HISTFILE=/dev/null${tmuxDirectory == null ? '' : ' TMUX_TMPDIR=$tmuxDirectory'}
Subsystem sftp $subsystem
''');
      server = await Process.start('/usr/sbin/sshd', [
        '-D',
        '-e',
        '-f',
        config.path,
      ]);
      // Drain both pipes without retaining terminal or credential material.
      unawaited(server.stdout.drain<void>());
      unawaited(server.stderr.drain<void>());
      for (var i = 0; i < 100; i++) {
        try {
          final probe = await Socket.connect('127.0.0.1', port);
          probe.destroy();
          break;
        } on SocketException {
          if (i == 99) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      return LocalSshd(
        dir,
        server,
        port,
        username,
        await File('${dir.path}/client').readAsString(),
      );
    } catch (_) {
      server?.kill();
      await dir.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> close() async {
    process.kill();
    await process.exitCode;
    await directory.delete(recursive: true);
  }
}
