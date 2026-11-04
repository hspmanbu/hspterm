import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/windows_unlock.dart';

class UnlockTestGateway implements WindowsUnlockGateway {
  WindowsUnlockSource current = WindowsUnlockSource(
    scope: 'synthetic-scope',
    token: 'a' * 64,
  );
  bool enabled = false, supports = true;
  Object? verifyError, availableError;
  int reads = 0, protects = 0, removes = 0;
  Uint8List? received;
  @override
  bool get supported => supports;
  @override
  Future<WindowsUnlockSource> source() async {
    reads++;
    return current;
  }

  @override
  Future<bool> available(String token) async {
    if (availableError != null) throw availableError!;
    return enabled;
  }

  @override
  Future<void> verify(WindowsUnlockSource original, String password) async {
    if (verifyError != null) throw verifyError!;
    if (original.scope != current.scope || original.token != current.token) {
      throw StateError('synthetic stale source');
    }
  }

  @override
  Future<void> protect(String token, Uint8List password) async {
    protects++;
    received = password;
    enabled = true;
  }

  @override
  Future<void> remove(String token) async {
    removes++;
    enabled = false;
  }
}

Future<void> mount(WidgetTester tester, UnlockTestGateway gateway) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WindowsUnlockSettingsPanel(
            gateway: gateway,
            run: (action) => action(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> enable(WidgetTester tester) async {
  await tester.ensureVisible(
    find.byKey(const ValueKey('windows-unlock-enable')),
  );
  await tester.tap(find.byKey(const ValueKey('windows-unlock-enable')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('windows-unlock-master')),
    '合成 Windows 主密码',
  );
  await tester.tap(find.byKey(const ValueKey('windows-unlock-consent')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'explicit verified enable wipes the owned UTF8 buffer; cancellation does not save',
    (tester) async {
      final gateway = UnlockTestGateway();
      await mount(tester, gateway);
      expect(gateway.protects, 0);
      await tester.tap(find.byKey(const ValueKey('windows-unlock-enable')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(gateway.protects, 0);
      await enable(tester);
      expect(gateway.protects, 1);
      expect(gateway.received, isNotEmpty);
      expect(gateway.received!.every((b) => b == 0), true);
      expect(
        find.byKey(const ValueKey('windows-unlock-status')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'failed authentication and foreign source cannot create a protected cache',
    (tester) async {
      final gateway = UnlockTestGateway()
        ..verifyError = StateError('synthetic authentication failure');
      await mount(tester, gateway);
      await enable(tester);
      expect(gateway.protects, 0);
      expect(
        find.byKey(const ValueKey('windows-unlock-error')),
        findsOneWidget,
      );
      gateway.verifyError = null;
      gateway.current = WindowsUnlockSource(
        scope: 'synthetic-foreign',
        token: 'b' * 64,
      );
      await enable(tester);
      expect(gateway.protects, 0);
      expect(gateway.received, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'unknown cache state is not defaulted to disabled; explicit cleanup remains possible',
    (tester) async {
      final gateway = UnlockTestGateway()
        ..availableError = StateError('synthetic damaged cache');
      await mount(tester, gateway);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('windows-unlock-enable')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('windows-unlock-disable')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(gateway.removes, 0);
      await tester.tap(find.byKey(const ValueKey('windows-unlock-disable')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('windows-unlock-confirm-remove')),
      );
      await tester.pumpAndSettle();
      expect(gateway.removes, 1);
      expect(gateway.enabled, false);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('windows-unlock-enable')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'non-Windows settings never request a Windows cache or native credential operation',
    (tester) async {
      final gateway = UnlockTestGateway()..supports = false;
      await mount(tester, gateway);
      expect(gateway.reads, 0);
      expect(gateway.protects, 0);
      expect(find.byKey(const ValueKey('windows-unlock-enable')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'exit waits for an admitted platform settings write and rejects new writes',
    () async {
      final model = LiveWorkbenchModel();
      final saving = Completer<void>();
      final write = model.runLocalSettings(() => saving.future);
      var closed = false;
      final closing = model.shutdown().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      await expectLater(model.runLocalSettings(() async {}), throwsStateError);
      saving.complete();
      await write;
      await closing;
      expect(closed, true);
      model.dispose();
    },
  );
  test('a null platform availability response is an unknown state, not a writable default', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowsUnlockChannel, (_) async => null);
    try {
      await expectLater(
        const NativeWindowsUnlockGateway().available('a' * 64),
        throwsStateError,
      );
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowsUnlockChannel, null);
    }
  });
}
