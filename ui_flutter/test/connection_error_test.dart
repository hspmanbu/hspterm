import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';

import 'support/fake_backend.dart';

class _DelayedConnect extends FakeBackend {
  final reply = Completer<void>();
  @override
  Future<void> connect(int id, String profileId) => reply.future;
}

void main() {
  for (final eventFirst in [true, false]) {
    test(
      'cancellation message is stable across status/FFI completion, eventFirst=$eventFirst',
      () async {
        final backend = _DelayedConnect();
        final controller = TerminalController(backend);
        await controller.start();
        final connecting = controller.connect('synthetic-host');
        Future<void> status() async {
          backend.events.add(
            const rust.BridgeEvent(
              kind: 'status',
              generation: 1,
              requestId: 0,
              text: 'Failed',
              detail: '连接已取消',
            ),
          );
          await Future<void>.delayed(Duration.zero);
        }

        Future<void> reply() async {
          backend.reply.completeError(AnyhowException('连接已取消'));
          await connecting;
        }

        if (eventFirst) {
          await status();
          expect(controller.error, '连接已取消');
          await reply();
        } else {
          await reply();
          expect(controller.error, '连接已取消');
          await status();
        }
        expect(controller.phase, 'Failed');
        expect(controller.error, '连接已取消');
        await controller.shutdown();
        controller.dispose();
      },
    );
  }
}
