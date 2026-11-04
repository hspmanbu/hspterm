import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/sftp_view_settings.dart';

SftpViewSnapshot snapshot(SftpViewSettings settings, {String revision = 'a'}) =>
    SftpViewSnapshot({
      'vault_scope': 'synthetic-vault',
      'revision': revision * 64,
      'settings': settings.toJson(),
    });

class _Gateway implements SftpViewSettingsGateway {
  bool failRead = false, failSave = false;
  int saves = 0;
  Completer<SftpViewSnapshot>? ack;
  @override
  Future<SftpViewSnapshot> load() async {
    if (failRead) throw StateError('fixture read');
    return snapshot(const SftpViewSettings());
  }

  @override
  Future<SftpViewSnapshot> save(
    SftpViewSnapshot source,
    SftpViewSettings settings,
  ) async {
    saves++;
    if (failSave) throw StateError('fixture SQL');
    return ack?.future ?? snapshot(settings, revision: 'b');
  }
}

void main() {
  test(
    'only acknowledged defaults publish and failed save requires reload',
    () async {
      final gateway = _Gateway()..ack = Completer<SftpViewSnapshot>();
      final controller = SftpViewSettingsController(gateway: gateway);
      await controller.choose(const SftpViewSettings(compact: true));
      expect(gateway.saves, 0);
      await controller.load();
      final save = controller.choose(const SftpViewSettings(compact: true));
      expect(controller.confirmed!.settings.compact, false);
      expect(controller.available, false);
      gateway.ack!.complete(
        snapshot(const SftpViewSettings(compact: true), revision: 'b'),
      );
      await save;
      expect(controller.confirmed!.settings.compact, true);
      gateway.failSave = true;
      await controller.choose(const SftpViewSettings(showHidden: true));
      expect(controller.value, isNull);
      expect(controller.confirmed!.settings.compact, true);
      expect(controller.available, false);
      expect(controller.error, isNotNull);
      await controller.shutdown();
      controller.dispose();
    },
  );
  test(
    'shutdown drains actual save without abandoning its acknowledged result',
    () async {
      final gateway = _Gateway()..ack = Completer<SftpViewSnapshot>();
      final controller = SftpViewSettingsController(gateway: gateway);
      await controller.load();
      final save = controller.choose(const SftpViewSettings(showHidden: true));
      var finished = false;
      final closing = controller.shutdown().then((_) {
        finished = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, false);
      gateway.ack!.complete(
        snapshot(const SftpViewSettings(showHidden: true), revision: 'b'),
      );
      await save;
      await closing;
      expect(controller.confirmed!.settings.showHidden, true);
      expect(controller.available, false);
      controller.resumeAfterCancelledShutdown();
      expect(controller.available, true);
      controller.dispose();
    },
  );
  testWidgets(
    'read failure disables formal view controls instead of saving invented defaults',
    (tester) async {
      final gateway = _Gateway()..failRead = true;
      final controller = SftpViewSettingsController(gateway: gateway);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SftpViewSettingsPanel(controller: controller)),
        ),
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('sftp-default-show-hidden')),
            )
            .onChanged,
        isNull,
      );
      expect(gateway.saves, 0);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'browser defaults affect actual sort and visibility while local choices survive unrelated rebuilds',
    (tester) async {
      final model = WorkbenchModel();
      model.openHost(model.hosts.first);
      final source = model.focus!;
      source.directories[source.path] = [
        DemoFile('${source.path}/z-dir', 'z-dir', folder: true),
        DemoFile('${source.path}/a.txt', 'a.txt'),
        DemoFile('${source.path}/.hidden', '.hidden'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: model,
              builder: (_, _) => FilesPanel(model: model, pane: source),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('z-dir')).dy,
        lessThan(tester.getTopLeft(find.text('a.txt')).dy),
      );
      expect(find.text('.hidden'), findsNothing);
      model.settings['目录优先'] = false;
      model.settings['显示隐藏文件'] = true;
      model.changed();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('z-dir')).dy,
        greaterThan(tester.getTopLeft(find.text('a.txt')).dy),
      );
      expect(find.text('.hidden'), findsOneWidget);
      await tester.tap(find.byTooltip('文件视图选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示隐藏文件'));
      await tester.pumpAndSettle();
      expect(find.text('.hidden'), findsNothing);
      model.changed();
      await tester.pumpAndSettle();
      expect(find.text('.hidden'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
