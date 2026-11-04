import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/display.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

DisplayConfig config({
  bool enabled = true,
  bool force = false,
  List<DisplayRule>? rules,
}) => DisplayConfig(
  enabled: enabled,
  semantic: true,
  rainbow: true,
  sameWord: true,
  sameWordCaseSensitive: true,
  allowInAlternateScreen: false,
  rules:
      rules ??
      [
        DisplayRule(
          id: 'fixture-error',
          name: 'Error fixture',
          pattern: 'ERROR',
          regex: false,
          caseSensitive: true,
          enabled: true,
          forceColor: force,
          foreground: 0xff112233,
          background: null,
          underline: true,
        ),
      ],
);
void main() {
  setUpAll(initializeRust);
  test('actual SSH applies display rules without raw history changes, respects ANSI/TUI, refreshes on Save and suppresses hidden frames', () async {
    final server = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      final path = '${server.directory.path}/display.vault';
      const password = 'synthetic-display-master';
      await rust.unlockVault(path: path, password: password);
      await model.load();
      var global = await rust.terminalDisplaySettings();
      global = await rust.saveTerminalDisplaySettings(
        vaultScope: global.vaultScope,
        expectedRevision: global.revision,
        config: config(),
      );
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Display fixture',
          '127.0.0.1',
          '未分组',
          user: server.username,
          port: server.port,
          auth: '私钥',
          openSftp: false,
        ),
        secret: server.privateKey,
        passphrase: 'test-only-passphrase',
      );
      model.confirmHostKey = (_, _) async => true;
      model.openHost(host);
      final s = model.sessions.single as LiveTerminalSession, c = s.controller;
      await waitFor(() => c.connected, 'display fixture connects');
      await c.setVisible(true);
      final generation = c.generation;
      Future<void> command(String text) async {
        await c.text(text);
        await c.key(rust.KeyboardInput(key: 'Enter', kind: 0, modifiers: 0));
      }

      await command(
        "printf '\\033[2J\\033[H%s%s\\n\\033[31m%s%s\\033[0m\\n中文 é [x=(42)]\\n' ER ROR ER ROR",
      );
      List<List<rust.RenderCell>> errorRows() => c.rows
          .where((row) => row.map((cell) => cell.text).join().trim() == 'ERROR')
          .toList();
      await waitFor(
        () => errorRows().length >= 2,
        'actual ERROR response rows',
      );
      expect(errorRows().first.first.foreground, 0xff112233);
      expect(errorRows().last.first.foreground, isNot(0xff112233));
      expect(errorRows().first.first.flags & 8, 8);
      expect(c.metadata!.sameWordEnabled, true);
      c.select(const Point(0, 0), const Point(4, 0));
      expect(c.selectedText(), 'ERROR');
      final first = File('${server.directory.path}/before.txt'),
          second = File('${server.directory.path}/after.txt');
      await c.backend.exportHistory(c.id!, first.path);
      await expectLater(
        rust.saveTerminalDisplaySettings(
          vaultScope: global.vaultScope,
          expectedRevision: 0,
          config: config(enabled: false),
        ),
        throwsA(anything),
      );
      global = await rust.saveTerminalDisplaySettings(
        vaultScope: global.vaultScope,
        expectedRevision: global.revision,
        config: config(enabled: false),
      );
      await waitFor(
        () =>
            c.metadata?.sameWordEnabled == false &&
            errorRows().first.first.foreground != 0xff112233,
        'settings force a frame without SSH output',
      );
      expect(
        c.selectedText(),
        'ERROR',
        reason: 'display-only updates preserve the actual selection',
      );
      await c.backend.exportHistory(c.id!, second.path);
      expect(await first.readAsString(), await second.readAsString());
      expect(await first.readAsString(), contains('中文 é [x=(42)]'));
      var custom = await rust.terminalDisplaySettings(hostId: host.id);
      custom = await rust.saveTerminalDisplaySettings(
        hostId: host.id,
        vaultScope: custom.vaultScope,
        expectedRevision: custom.revision,
        config: config(force: true),
      );
      await waitFor(
        () => errorRows().last.first.foreground == 0xff112233,
        'explicit host color override',
      );
      final copied = await rust.copyHostToDraft(id: host.id);
      await rust.discardHostDraft(id: copied.id);
      // Local protocol fixture; this is not a claim of running an actual TUI here.
      await command("printf '\\033[?1049h\\033[2J\\033[H%s%s' ER ROR");
      await waitFor(
        () =>
            c.metadata?.alternateScreen == true && screen(c).contains('ERROR'),
        'alternate screen enters',
      );
      expect(c.rows.first.first.foreground, isNot(0xff112233));
      expect(c.metadata!.sameWordEnabled, false);
      await command("printf '\\033[?1049l'");
      await waitFor(
        () => c.metadata?.alternateScreen == false,
        'normal screen restored',
      );
      await c.setVisible(false);
      final frames = c.frameCount;
      custom = await rust.saveTerminalDisplaySettings(
        hostId: host.id,
        vaultScope: custom.vaultScope,
        expectedRevision: custom.revision,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(c.frameCount, frames);
      expect(c.generation, generation);
      expect(c.connected, true);
      await c.setVisible(true);
      await waitFor(
        () => c.metadata?.sameWordEnabled == false,
        'inherit global disabled after showing',
      );
      final matches = await rust.testDisplayRules(
        config: config(),
        sample: 'ERROR ERROR',
      );
      expect(matches.single.count, 2);
      final perLine = await rust.testDisplayRules(
        config: config(
          rules: [
            const DisplayRule(
              id: 'line-anchor',
              name: 'Line anchor',
              pattern: '^ERROR',
              regex: true,
              caseSensitive: true,
              enabled: true,
              forceColor: false,
              foreground: 0xff112233,
              underline: false,
            ),
          ],
        ),
        sample: 'ERROR\nERROR',
      );
      expect(perLine.single.count, 2);
      await expectLater(
        rust.importDisplayRules(source: '[{"unknown":true}]'),
        throwsA(anything),
      );
      final raw =
          '[{"id":"json-fixture","name":"JSON","pattern":"ok","regex":false,"case_sensitive":true,"enabled":true,"force_color":false,"style":{"foreground":4294901760,"background":null,"underline":false}}]';
      expect(
        (await rust.importDisplayRules(source: raw)).single.id,
        'json-fixture',
      );
      await rust.unlockVault(path: path, password: password);
      await expectLater(
        rust.saveTerminalDisplaySettings(
          vaultScope: global.vaultScope,
          expectedRevision: global.revision,
          config: config(),
        ),
        throwsA(anything),
      );
    } finally {
      await model.shutdown();
      model.dispose();
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
