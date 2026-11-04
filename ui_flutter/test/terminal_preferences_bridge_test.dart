import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/terminal_preferences.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('real SSH terminal defaults update without reconnect, remote override wins and history limit affects only new terminals', () async {
    final ssh = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      await rust.createConfigurationVault(
        path: '${ssh.directory.path}/preferences.vault',
        password: 'synthetic-preferences-master',
      );
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Preferences',
          '127.0.0.1',
          '未分组',
          user: ssh.username,
          port: ssh.port,
          auth: '私钥',
          openSftp: false,
        ),
        secret: ssh.privateKey,
        passphrase: 'test-only-passphrase',
      );
      model.openHost(host);
      final session = model.focus! as LiveTerminalSession;
      final c = session.controller;
      await waitFor(
        () => c.connected || c.phase == 'Failed',
        'preferences SSH',
      );
      expect(c.connected, true, reason: c.error);
      await c.setVisible(true);
      await model.loadDirectory(session, '.');
      final id = c.id, generation = c.generation, path = session.path;
      final original = TerminalPreferencesSnapshot.decode(
        await rust.loadTerminalPreferences(),
      );
      final value = TerminalPreferencesValue(
        historyLines: 3,
        shape: 'beam',
        blink: false,
        osc52: false,
        rightPaste: true,
        foreground: 0x24364a,
        background: 0xf6f8fb,
        cursor: 0x123456,
        ansi: TerminalPreferencesValue.light,
      );
      final saved = TerminalPreferencesSnapshot.decode(
        await rust.saveTerminalPreferences(proposal: original.proposal(value)),
      );
      expect(saved.value.toJson(), value.toJson());
      await waitFor(
        () => c.metadata?.background == 0xfff6f8fb,
        'preferences frame',
      );
      expect(c.metadata!.cursorShape, 2);
      expect(c.metadata!.cursorColor, 0xff123456);
      expect(c.osc52Enabled, false);
      expect(c.rightClickPaste, true);
      expect(c.id, id);
      expect(c.generation, generation);
      expect(session.path, path);
      expect(session.sftpEnabled, true);
      Future<void> command(String text) async {
        await c.text(text);
        await c.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
      }

      await command(r"printf '\033[4 q\033]11;#112233\007'");
      await waitFor(
        () =>
            c.metadata?.background == 0xff112233 &&
            c.metadata?.cursorShape == 1,
        'remote override',
      );
      final revised = TerminalPreferencesValue(
        historyLines: 3,
        shape: 'block',
        blink: true,
        osc52: false,
        rightPaste: true,
        foreground: 0x24364a,
        background: 0xabcdef,
        cursor: 0x123456,
        ansi: TerminalPreferencesValue.light,
      );
      await rust.saveTerminalPreferences(proposal: saved.proposal(revised));
      expect(c.connected, true);
      await command('printf "PREFERENCE_ACK\\n"');
      await waitFor(
        () => screen(c).contains('PREFERENCE_ACK'),
        'original shell',
      );
      expect(c.metadata!.background, 0xff112233);
      expect(c.metadata!.cursorShape, 1);
      await command(
        r'''printf '\033[0 q\033]111\007'; i=0; while [ $i -lt 80 ]; do printf 'OLD_HISTORY %s\n' "$i"; i=$((i+1)); done''',
      );
      await waitFor(
        () => screen(c).contains('OLD_HISTORY 79'),
        'old history retained',
      );
      expect(c.metadata!.historyLines, greaterThan(3));
      expect(c.metadata!.background, 0xffabcdef);
      await expectLater(
        rust.saveTerminalPreferences(proposal: original.proposal(value)),
        throwsA(anything),
      );
      model.openHost(host);
      final next = model.focus! as LiveTerminalSession;
      final n = next.controller;
      await waitFor(
        () => n.connected || n.phase == 'Failed',
        'new preferences SSH',
      );
      expect(n.connected, true, reason: n.error);
      await n.setVisible(true);
      await n.text(
        r'i=0; while [ $i -lt 80 ]; do printf "NEW_HISTORY %s\n" "$i"; i=$((i+1)); done',
      );
      await n.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(n).contains('NEW_HISTORY 79'),
        'new history limit',
      );
      expect(n.metadata!.historyLines, lessThanOrEqualTo(3));
      expect(c.id, id);
      expect(c.connected, true);
      expect(
        jsonDecode(
          await rust.loadTerminalPreferences(),
        )['value']['history_lines'],
        3,
      );
    } finally {
      await model.shutdown();
      model.dispose();
      await ssh.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
