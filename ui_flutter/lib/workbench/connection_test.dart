import 'dart:async';

import '../src/rust/api.dart' as rust;
import '../terminal/backend.dart';
import '../terminal/controller.dart';

/// Owns a hidden, short-lived event stream for TOFU; never owns a visible tab.
/// Destroying it cancels native acquisition and waits for the FRB stream to end.
class HostConnectionTest {
  HostConnectionTest({
    required TerminalBackend backend,
    required this.hostId,
    required this.address,
    required this.port,
    required this.username,
    this.jumpHostId,
    required Future<bool> Function(rust.BridgeEvent) confirmHostKey,
    this.execute,
  }) : _terminal = TerminalController(backend) {
    _terminal.confirmHostKey = confirmHostKey;
  }
  final String hostId, address, username;
  final String? jumpHostId;
  final int port;
  final TerminalController _terminal;
  final Future<void> Function(int)? execute;
  final _stopped = Completer<void>();
  Future<void>? _run;
  bool _cancelled = false;
  bool get cancelled => _cancelled;

  Future<void> run() => _run ??= _perform();
  Future<void> _perform() async {
    try {
      if (_cancelled) throw StateError('连接测试已取消');
      await _terminal.setVisible(false);
      await _terminal.start();
      if (_cancelled) throw StateError('连接测试已取消');
      final id = _terminal.id;
      if (id == null) throw StateError('连接测试已结束');
      if (execute case final action?) {
        await action(id);
      } else {
        await rust.testHostConnection(
          id: id,
          hostId: hostId,
          expectedAddress: address,
          expectedPort: port,
          expectedUsername: username,
          expectedJumpHostId: jumpHostId,
        );
      }
      if (_cancelled) throw StateError('连接测试已取消');
    } finally {
      try {
        await _terminal.shutdown();
      } finally {
        _terminal.dispose();
        if (!_stopped.isCompleted) _stopped.complete();
      }
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    if (_run == null) return;
    await _terminal.shutdown();
    await _stopped.future;
  }
}
