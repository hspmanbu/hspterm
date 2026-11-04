import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/model.dart';

import 'support/fake_backend.dart';

LiveTerminalSession session(
  String name,
  int native,
  int generation, {
  String host = 'host-fixture',
}) {
  final value = LiveTerminalSession(
    name,
    DemoHost(host, name, 'example.invalid', 'Default'),
    FakeBackend(),
  );
  value.controller
    ..id = native
    ..generation = generation
    ..phase = 'Connected';
  return value;
}

void main() {
  test(
    'original generation keeps its identity even when another tab has focus',
    () async {
      final first = session('Original', 1, 4), second = session('Other', 2, 1);
      expect(
        chooseTransferConnection(
          [first, second],
          focus: second,
          hostId: first.host.id,
          preferredId: 1,
          preferredGeneration: 4,
        ),
        same(first),
      );
      await first.controller.shutdown();
      await second.controller.shutdown();
      first.controller.dispose();
      second.controller.dispose();
    },
  );
  test('a reconnected former tab does not displace the explicitly focused recovery connection', () async {
    final first = session('Changed generation', 1, 5),
        second = session('Recovery', 2, 1);
    expect(
      chooseTransferConnection(
        [first, second],
        focus: second,
        hostId: first.host.id,
        preferredId: 1,
        preferredGeneration: 4,
      ),
      same(second),
    );
    await first.controller.shutdown();
    await second.controller.shutdown();
    first.controller.dispose();
    second.controller.dispose();
  });
  test('missing old runtime generation prefers focus while closing or unrelated hosts are excluded', () async {
    final first = session('Original', 1, 5),
        second = session('Recovery', 2, 1),
        other = session('Foreign', 3, 1, host: 'other-host');
    expect(
      chooseTransferConnection(
        [first, second, other],
        focus: second,
        hostId: first.host.id,
        preferredId: 1,
        preferredGeneration: null,
      ),
      same(second),
    );
    await second.controller.shutdown();
    expect(
      chooseTransferConnection(
        [second, other],
        focus: other,
        hostId: first.host.id,
        preferredId: 1,
        preferredGeneration: 4,
      ),
      isNull,
    );
    await first.controller.shutdown();
    await other.controller.shutdown();
    for (final item in [first, second, other]) {
      item.controller.dispose();
    }
  });
}
