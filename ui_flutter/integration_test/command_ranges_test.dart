import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/terminal/view.dart';

import '../test/command_ranges_bridge_test.dart' show exerciseCommandRanges;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK renders real OSC133 output and retains command operations through explicit lifecycle',
    (tester) async {
      await exerciseCommandRanges(
        attach: (c) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: TerminalView(controller: c)),
            ),
          );
          await tester.pump();
        },
        detach: () async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
