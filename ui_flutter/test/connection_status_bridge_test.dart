import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';

class _ObservedBackend extends NativeTerminalBackend {
  bool hidden = false;
  final hiddenSamples = <int>[];
  @override
  Stream<rust.BridgeEvent> watch(int id) => super.watch(id).map((event) {
    if (hidden && event.kind == 'latency') hiddenSamples.add(event.generation);
    return event;
  });
  @override
  Future<void> visible(int id, bool value) async {
    await super.visible(id, value);
    hidden = !value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('original SSH heartbeat RTT reaches hidden controller without frame pulls, clears on disconnect and does not probe when disabled', () async {
    final ssh = await LocalSshd.start();
    final backend = _ObservedBackend();
    final model = LiveWorkbenchModel(backendFactory: () => backend);
    try {
      await rust.createConfigurationVault(
        path: '${ssh.directory.path}/rtt.vault',
        password: 'synthetic-rtt-master',
      );
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'RTT fixture',
          '127.0.0.1',
          '未分组',
          user: ssh.username,
          port: ssh.port,
          auth: '私钥',
          openSftp: false,
          useNetworkDefaults: false,
          keepaliveSeconds: 1,
          keepaliveResponseSeconds: 1,
          keepaliveFailures: 3,
        ),
        secret: ssh.privateKey,
        passphrase: 'test-only-passphrase',
      );
      model.openHost(host);
      final c = (model.focus! as LiveTerminalSession).controller;
      await waitFor(() => c.connected || c.phase == 'Failed', 'RTT SSH');
      expect(c.connected, true, reason: c.error);
      final id = c.id!, generation = c.generation;
      await c.setVisible(true);
      await waitFor(() => c.metadata != null, 'RTT initial dimensions');
      await c.setVisible(false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final before = await rust.terminalMetrics(id: id);
      final count = backend.hiddenSamples.length;
      await waitFor(
        () =>
            backend.hiddenSamples.length > count &&
            c.transportInfo.value.rttMicros != null,
        'passive heartbeat RTT',
      );
      expect(c.id, id);
      expect(c.generation, generation);
      expect(c.connected, true);
      expect(c.transportInfo.value.rttMicros, greaterThanOrEqualTo(0));
      expect(
        (await rust.terminalMetrics(id: id)).framePulls,
        before.framePulls,
      );
      expect(c.transportInfo.value.columns, c.metadata!.columns);
      await rust.disconnectTerminal(id: id);
      await waitFor(() => c.phase == 'Disconnected', 'RTT disconnect');
      expect(c.transportInfo.value.rttMicros, isNull);
      await model.persistHost(host.snapshot()..keepaliveSeconds = 0);
      await c.reconnect();
      await waitFor(
        () => c.connected || c.phase == 'Failed',
        'RTT manual reconnect',
      );
      expect(c.connected, true, reason: c.error);
      expect(c.generation, isNot(generation));
      expect(c.transportInfo.value.rttMicros, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      expect(c.transportInfo.value.rttMicros, isNull);
      expect(backend.hiddenSamples.where((g) => g == c.generation), isEmpty);
    } finally {
      await model.shutdown();
      model.dispose();
      await ssh.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
