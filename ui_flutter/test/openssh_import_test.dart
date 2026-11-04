import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/openssh_import.dart';
import 'package:hspterm/workbench/openssh_import.dart';

class ImportFixture implements OpenSshImportGateway {
  bool failGroups = false, failSave = false;
  int previews = 0, saves = 0;
  String? savedSource;
  List<String>? savedAliases;
  Completer<void>? pending;
  @override
  Future<List<rust.HostGroupConfig>> groups() async {
    if (failGroups) throw StateError('synthetic group error');
    return [const rust.HostGroupConfig(id: 'group-default', name: '未分组')];
  }

  @override
  Future<OpenSshImportPreview> preview(String source, String username) async {
    previews++;
    return OpenSshImportPreview(
      vaultScope: 'original-vault',
      warnings: const ['Include未读取，必须核对'],
      hosts: [
        for (final (alias, blocked, duplicate) in [
          ('alpha', false, false),
          ('unsafe', true, false),
          ('existing', false, true),
        ])
          OpenSshImportHost(
            alias: alias,
            address: '$alias.invalid',
            port: 22,
            username: username,
            privateKey: true,
            timeoutSeconds: 30,
            keepaliveSeconds: 30,
            keepaliveFailures: 3,
            jumpAlias: null,
            warnings: const [],
            blocked: blocked,
            nameExists: duplicate,
          ),
      ],
    );
  }

  @override
  Future<List<rust.HostConfig>> save({
    required String source,
    required String username,
    required List<String> aliases,
    required bool acknowledge,
    required String group,
    required String scope,
  }) async {
    saves++;
    savedSource = source;
    savedAliases = aliases;
    if (pending != null) await pending!.future;
    if (failSave) throw StateError('synthetic save error; nothing overwritten');
    return [];
  }
}

Future<void> open(
  WidgetTester tester,
  ImportFixture fixture, {
  Future<XFile?> Function()? file,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) =>
                  OpenSshImportDialog(gateway: fixture, chooseFile: file),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> preview(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('ssh-import-user')),
    'fixture',
  );
  await tester.enterText(
    find.byKey(const ValueKey('ssh-import-source')),
    'Host alpha\n User fixture',
  );
  await tester.tap(find.byKey(const ValueKey('ssh-import-preview')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'explicit source/selection/warning acknowledgement and failure never close or duplicate a save',
    (tester) async {
      final fixture = ImportFixture()..failSave = true;
      await open(tester, fixture);
      await preview(tester);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('ssh-import-host-unsafe')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('ssh-import-host-existing')),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('ssh-import-select-all')));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('ssh-import-save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('ssh-import-ack')));
      await tester.tap(find.byKey(const ValueKey('ssh-import-ack')));
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(fixture.saves, 1);
      expect(fixture.savedAliases, ['alpha']);
      expect(fixture.savedSource, 'Host alpha\n User fixture');
      expect(find.textContaining('synthetic save error'), findsOneWidget);
      fixture.failSave = false;
      fixture.pending = Completer<void>();
      await tester.tap(save);
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('ssh-import-cancel')))
            .onPressed,
        isNull,
      );
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      fixture.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(OpenSshImportDialog), findsNothing);
      expect(fixture.saves, 2);
    },
  );
  testWidgets(
    'source edits require a fresh preview and reset selection/ack; small window has no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(720, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = ImportFixture();
      await open(tester, fixture);
      await preview(tester);
      await tester.tap(find.byKey(const ValueKey('ssh-import-host-alpha')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ssh-import-back')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ssh-import-source')),
        'Host changed',
      );
      await tester.tap(find.byKey(const ValueKey('ssh-import-preview')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('ssh-import-host-alpha')),
            )
            .value,
        false,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('ssh-import-save')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('ssh-import-cancel')));
      await tester.pumpAndSettle();
      expect(fixture.saves, 0);
      expect(fixture.previews, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'group read failure disables preview; explicit file input refuses malformed UTF8 without parsing',
    (tester) async {
      final fixture = ImportFixture()..failGroups = true;
      await open(tester, fixture);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('ssh-import-preview')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('ssh-import-cancel')));
      await tester.pumpAndSettle();
      fixture.failGroups = false;
      await open(
        tester,
        fixture,
        file: () async => XFile.fromData(
          Uint8List.fromList([255, 254, 0]),
          name: 'synthetic.conf',
          length: 3,
        ),
      );
      // File-stream deadlines use the real event loop, outside widget FakeAsync.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('ssh-import-file')));
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('需要不超过1MiB的UTF-8文本'), findsOneWidget);
      expect(fixture.previews, 0);
      expect(fixture.saves, 0);
    },
  );
}
