import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';

import 'support/fake_backend.dart';

void main() {
  for (final kind in ['hostKey', 'jumpHostKey']) {
    test(
      '$kind callback failure explicitly rejects and reports without waiting forever',
      () async {
        final backend = FakeBackend();
        final controller = TerminalController(backend);
        controller.confirmHostKey = (_) async =>
            throw StateError('synthetic confirmation failure');
        await controller.start();
        backend.events.add(
          rust.BridgeEvent(kind: kind, generation: 1, requestId: 7),
        );
        await Future<void>.delayed(Duration.zero);
        expect(backend.hostKeyReplies, [(7, false)]);
        expect(controller.error, contains('synthetic confirmation failure'));
        await controller.shutdown();
        controller.dispose();
      },
    );
  }
}
