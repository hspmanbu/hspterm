import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/workbench/file_properties.dart';

class Gateway implements FilePropertiesGateway {
  Gateway({this.pages = const [], this.accountOptions, this.gateBeforeIndex});
  @override
  bool current = true;
  final calls = <(int?, int?, int?, bool)>[];
  final List<rust.DirectorySizePage> pages;
  final rust.RemoteAccountOptions? accountOptions;
  // When set, the step with this index waits for [gate] first so tests can
  // observe the progressive totals between pages.
  final int? gateBeforeIndex;
  Completer<void>? gate = Completer<void>();
  int beginCount = 0, stopCount = 0, stepIndex = 0;
  @override
  Future<rust.RemoteProperties> load(bool includeSize) async {
    return const rust.RemoteProperties(
      path: '/folder',
      size: 0,
      files: 0,
      directories: 1,
      permissions: 493,
      uid: 1000,
      gid: 1000,
      sizeComplete: false,
    );
  }

  @override
  Future<void> save({
    int? permissions,
    int? uid,
    int? gid,
    required bool recursive,
  }) async {
    calls.add((permissions, uid, gid, recursive));
  }

  @override
  Future<rust.RemoteAccountOptions?> accounts() async => accountOptions;

  @override
  Future<String> sizeBegin() async {
    beginCount++;
    return 'ticket-$beginCount';
  }

  @override
  Future<rust.DirectorySizePage> sizeStep(String ticket) async {
    if (gateBeforeIndex == stepIndex) {
      await gate!.future;
    }
    stepIndex++;
    if (pages.isEmpty) {
      throw StateError('synthetic denied subtree');
    }
    return pages.removeAt(0);
  }

  @override
  Future<void> sizeStop(String ticket) async {
    stopCount++;
  }
}

DemoFile folder() => DemoFile('/folder', 'folder', folder: true, kind: '文件夹');

Future<void> pumpDialog(
  WidgetTester tester,
  FilePropertiesGateway gateway,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FilePropertiesDialog(gateway: gateway, file: folder()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('folder size grows page by page and completes with item counts', (
    tester,
  ) async {
    final gateway = Gateway(
      pages: [
        const rust.DirectorySizePage(
          size: 4096,
          files: 2,
          directories: 1,
          complete: false,
        ),
        const rust.DirectorySizePage(
          size: 9216,
          files: 5,
          directories: 2,
          complete: true,
        ),
      ],
      gateBeforeIndex: 1,
    );
    await pumpDialog(tester, gateway);
    await tester.pump(const Duration(milliseconds: 100));
    // First page visible while the second is still in flight.
    expect(find.textContaining('4096 B'), findsOneWidget);
    expect(find.textContaining('统计中'), findsOneWidget);
    gateway.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('9216 B'), findsOneWidget);
    expect(find.textContaining('统计中'), findsNothing);
    expect(find.textContaining('5 个文件 · 2 个目录'), findsOneWidget);
    expect(gateway.stopCount, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('stop button halts the walk and keeps the last completed page', (
    tester,
  ) async {
    final gateway = Gateway(
      pages: [
        const rust.DirectorySizePage(
          size: 1024,
          files: 1,
          directories: 1,
          complete: false,
        ),
        const rust.DirectorySizePage(
          size: 4096,
          files: 9,
          directories: 9,
          complete: false,
        ),
      ],
      gateBeforeIndex: 1,
    );
    await pumpDialog(tester, gateway);
    await tester.pump(const Duration(milliseconds: 100));
    expect(gateway.beginCount, 1);
    expect(find.textContaining('1024 B'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stop-size-calc')));
    gateway.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('统计中'), findsNothing);
    expect(find.textContaining('未计算'), findsNothing);
    expect(gateway.stopCount, greaterThanOrEqualTo(1));
    // The gated second page must not surface after the explicit stop.
    expect(find.textContaining('4096 B'), findsNothing);
    expect(find.textContaining('9 个文件'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'failed size walk keeps editable metadata and untouched ownership',
    (tester) async {
      final gateway = Gateway();
      await pumpDialog(tester, gateway);
      await tester.pumpAndSettle();
      expect(find.textContaining('内容大小统计未完成'), findsOneWidget);
      // 0755 baseline: owner keeps rwx, group and other lose write.
      bool cell(String key) => tester
          .widget<Checkbox>(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Checkbox),
            ),
          )
          .value!;
      expect(cell('permission-owner-write'), isTrue);
      expect(cell('permission-group-write'), isFalse);
      await tester.tap(find.text('保存属性'));
      await tester.pumpAndSettle();
      expect(gateway.calls.single, (null, null, null, false));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('permission grid edits send the changed octal value only', (
    tester,
  ) async {
    final gateway = Gateway();
    await pumpDialog(tester, gateway);
    await tester.pumpAndSettle();
    expect(find.text('当前权限：0755'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('permission-owner-exec')),
    );
    await tester.tap(find.byKey(const ValueKey('permission-owner-exec')));
    await tester.pump();
    expect(find.text('当前权限：0655'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('permission-owner-write')),
    );
    await tester.tap(find.byKey(const ValueKey('permission-owner-write')));
    await tester.pump();
    expect(find.text('当前权限：0455'), findsOneWidget);
    await tester.tap(find.text('保存属性'));
    await tester.pumpAndSettle();
    expect(gateway.calls.single, (301, null, null, false));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'owner dropdowns list remote accounts and submit changed ownership',
    (tester) async {
      final gateway = Gateway(
        accountOptions: const rust.RemoteAccountOptions(
          users: [
            rust.RemoteIdName(id: 0, name: 'root'),
            rust.RemoteIdName(id: 1000, name: 'ubuntu'),
          ],
          groups: [
            rust.RemoteIdName(id: 0, name: 'root'),
            rust.RemoteIdName(id: 1000, name: 'ubuntu'),
          ],
        ),
      );
      await pumpDialog(tester, gateway);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('file-owner-dropdown')),
      );
      await tester.tap(find.byKey(const ValueKey('file-owner-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('root (0)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存属性'));
      await tester.pumpAndSettle();
      // uid 1000 -> 0 changed; gid stays 1000 so it is omitted.
      expect(gateway.calls.single, (null, 0, null, false));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'properties layout remains scrollable in a small window with large text',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: FilePropertiesDialog(gateway: Gateway(), file: folder()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('关闭'), findsOneWidget);
    },
  );
}
