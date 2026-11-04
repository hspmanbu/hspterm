import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/controller.dart';

// Pump stream delivery in the widget clock and cancellation completions in
// the real event queue, then assert retirement rather than abandoning cleanup.
Future<void> drainAsync(WidgetTester tester, Future<void> work) async {
  var completed = false;
  Object? failure;
  unawaited(
    work.then(
      (_) {
        completed = true;
      },
      onError: (Object error) {
        failure = error;
      },
    ),
  );
  for (var n = 0; n < 10 && !completed && failure == null; n++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(failure, isNull);
  expect(completed, true);
}

Future<void> closeTerminal(
  WidgetTester tester,
  TerminalController value,
) async {
  await drainAsync(tester, value.shutdown());
  expect(value.shutdownComplete, true);
  value.dispose();
  await tester.pump();
}
