import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/platform/explorer_drop.dart';

/// Protocol adapter fixture only. Does not implement OLE or read local files.
class ExplorerNativeFixture {
  static const channel = MethodChannel('hspterm/explorer_drop');
  Map<Object?, Object?>? bound;
  final acknowledgements = <int>[];
  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'bind') {
        bound = Map<Object?, Object?>.from(call.arguments as Map);
      }
      if (call.method == 'clear') bound = null;
      if (call.method == 'ackMove') {
        acknowledgements.add((call.arguments as Map)['sequence'] as int);
      }
      return null;
    });
  }

  Map<Object?, Object?> event(
    String kind, {
    int drag = 1,
    int? sequence,
    List<Object?>? paths,
    Map<Object?, Object?>? source,
    Offset? physical,
  }) {
    final current = source ?? bound!;
    final rect = (current['rect'] as List).cast<double>();
    return {
      'kind': kind,
      'owner': current['owner'],
      'zone': current['zone'],
      'drag': drag,
      'x': physical?.dx ?? (rect[0] + rect[2]) / 2,
      'y': physical?.dy ?? (rect[1] + rect[3]) / 2,
      'sequence': ?sequence,
      'paths': ?paths,
    };
  }

  Future<void> send(WidgetTester tester, Map<Object?, Object?> data) async {
    final done = Completer<void>();
    tester.binding.channelBuffers.push(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('event', data)),
      (reply) {
        try {
          if (reply != null) const StandardMethodCodec().decodeEnvelope(reply);
          done.complete();
        } catch (error, stack) {
          done.completeError(error, stack);
        }
      },
    );
    await tester.pump();
    await done.future;
  }
}

void windowsTest(String name, WidgetTesterCallback body) {
  testWidgets(name, (tester) async {
    final original = debugDefaultTargetPlatformOverride;
    try {
      await body(tester);
    } finally {
      // Retire this view and drain channel work inside its own fake zone before
      // restoring the platform and before Flutter verifies global invariants.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      debugDefaultTargetPlatformOverride = original;
    }
  });
}

void main() {
  test('Explorer names preserve Unicode and quoting characters but reject roots and unsafe names', () {
    expect(explorerFileName(r'C:\local\中文 é $ name.txt'), '中文 é \$ name.txt');
    expect(explorerFileName(r'\\server\share\folder'), 'folder');
    for (final path in [
      'C:\\',
      'C:\\..',
      'C:\\file:stream',
      'C:\\bad\u0000name',
      'relative.txt',
      r'\\?\C:\device-file',
    ]) {
      expect(() => explorerFileName(path), throwsFormatException);
    }
  });

  windowsTest(
    'physical coordinates, coalesced-move ACK and single-use drop route immutable paths',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final native = ExplorerNativeFixture()..install(tester);
      final drops = <List<String>>[], hover = <Offset?>[], errors = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 200,
                child: ExplorerFileDropRegion(
                  owner: 'session:1',
                  view: 'directory-one',
                  enabled: true,
                  onDrop: (paths, _) async => drops.add(paths),
                  onHover: hover.add,
                  onFailure: errors.add,
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await native.send(tester, native.event('hover', sequence: 1));
      expect(hover.last, tester.getCenter(find.byType(ExplorerFileDropRegion)));
      final event = native.event(
        'drop',
        paths: [r'C:\local\one', r'C:\local\folder'],
      );
      await native.send(tester, event);
      await native.send(tester, event);
      await native.send(tester, native.event('hover', sequence: 2));
      expect(drops, hasLength(1));
      expect(() => drops.single.add('mutated'), throwsUnsupportedError);
      expect(native.acknowledgements, [1, 2]);
      expect(hover.last, isNull);
      expect(errors, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(native.bound, isNull);
    },
  );

  windowsTest(
    'directory and owner revisions reject late events while still acknowledging the native stream',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final native = ExplorerNativeFixture()..install(tester);
      final drops = <String>[];
      Widget page(String owner, String view) => MaterialApp(
        home: Scaffold(
          body: ExplorerFileDropRegion(
            owner: owner,
            view: view,
            enabled: true,
            onHover: (_) {},
            onFailure: (_) {},
            onDrop: (_, _) async => drops.add(owner),
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpWidget(page('A:1', 'dir-one'));
      await tester.pump();
      final first = Map<Object?, Object?>.from(native.bound!);
      await tester.pumpWidget(page('A:1', 'dir-two'));
      await tester.pump();
      await native.send(
        tester,
        native.event('hover', source: first, sequence: 3),
      );
      await native.send(
        tester,
        native.event('drop', source: first, paths: [r'C:\old']),
      );
      expect(drops, isEmpty);
      final second = Map<Object?, Object?>.from(native.bound!);
      await tester.pumpWidget(page('B:1', 'dir-two'));
      await tester.pump();
      await native.send(
        tester,
        native.event('drop', source: second, paths: [r'C:\wrong-session']),
      );
      await native.send(
        tester,
        native.event('drop', drag: 2, paths: [r'C:\current']),
      );
      expect(drops, ['B:1']);
      expect(native.acknowledgements, [3]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  windowsTest(
    'scroll invalidates geometry tokens and a modal route disables the underlying drop surface',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final native = ExplorerNativeFixture()..install(tester);
      var drops = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => unawaited(
                      showDialog<void>(
                        context: context,
                        builder: (_) =>
                            const AlertDialog(title: Text('Confirmation')),
                      ),
                    ),
                    child: const Text('Dialog'),
                  ),
                  Expanded(
                    child: ExplorerFileDropRegion(
                      owner: 'A:1',
                      view: 'directory',
                      enabled: true,
                      onDrop: (_, _) async {
                        drops++;
                      },
                      onHover: (_) {},
                      onFailure: (_) {},
                      child: ListView(
                        children: List.generate(
                          40,
                          (i) => SizedBox(height: 40, child: Text('row $i')),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final first = Map<Object?, Object?>.from(native.bound!);
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(native.bound!['zone'], isNot(first['zone']));
      await native.send(
        tester,
        native.event('drop', source: first, paths: [r'C:\old-position']),
      );
      expect(drops, 0);
      final beforeDialog = Map<Object?, Object?>.from(native.bound!);
      await tester.tap(find.text('Dialog'));
      await tester.pumpAndSettle();
      expect(native.bound, isNull);
      await native.send(
        tester,
        native.event(
          'drop',
          source: beforeDialog,
          paths: [r'C:\behind-dialog'],
        ),
      );
      expect(drops, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  windowsTest(
    'invalid path payloads and points outside the visible region do not reach upload',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final native = ExplorerNativeFixture()..install(tester);
      var drops = 0;
      final errors = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExplorerFileDropRegion(
              owner: 'A:1',
              view: 'directory',
              enabled: true,
              onDrop: (_, _) async {
                drops++;
              },
              onHover: (_) {},
              onFailure: errors.add,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();
      await native.send(
        tester,
        native.event('drop', paths: ['C:\\bad\u0000name']),
      );
      await native.send(tester, native.event('drop', drag: 2, paths: [123]));
      await native.send(
        tester,
        native.event(
          'drop',
          drag: 3,
          paths: [r'C:\outside'],
          physical: const Offset(-100, -100),
        ),
      );
      expect(drops, 0);
      expect(errors, hasLength(3));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  windowsTest(
    'disabled or non-Windows surfaces never publish an eligible native region',
    (tester) async {
      final native = ExplorerNativeFixture()..install(tester);
      Widget page(bool enabled) => MaterialApp(
        home: ExplorerFileDropRegion(
          owner: 'A:1',
          view: 'directory',
          enabled: enabled,
          onDrop: (_, _) async {},
          onHover: (_) {},
          onFailure: (_) {},
          child: const SizedBox.expand(),
        ),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpWidget(page(false));
      await tester.pump();
      expect(native.bound, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await tester.pumpWidget(page(true));
      await tester.pump();
      expect(native.bound, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
