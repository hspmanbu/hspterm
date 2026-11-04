import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('relative path metadata is original-session bound, revision checked and performs no SFTP or input injection', () async {
    final ssh = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      await rust.createConfigurationVault(
        path: '${ssh.directory.path}/relative.vault',
        password: 'synthetic-relative-master',
      );
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Relative fixture',
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
      model.openHost(host);
      final a = model.sessions[0] as LiveTerminalSession,
          b = model.sessions[1] as LiveTerminalSession;
      await waitFor(
        () => a.controller.connected && b.controller.connected,
        'relative SSH roots',
      );
      final c = a.controller, id = c.id!, generation = c.generation;
      await c.setVisible(true);
      await c.text(
        "unset PROMPT_COMMAND; PS1=''; printf '\\033]7;%s\\007' 'file://127.0.0.1/relative%20base'; printf '%s%s\\n' REL_ READY",
      );
      await c.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(() => screen(c).contains('REL_READY'), 'relative OSC7');
      await c.setVisible(false);
      final paths = [
        "/relative base/中文 '\$name",
        '/relative base/-rf',
        '/relative base/%41',
      ];
      final value = await model.relativeRemotePaths(a, paths);
      expect(value.paths, ["./中文 '\$name", './-rf', './%41']);
      final before = await rust.terminalMetrics(id: id);
      await rust.terminalRelativePaths(
        id: id,
        generation: generation,
        expectedDirectoryRevision: value.directoryRevision,
        paths: paths,
      );
      expect(
        (await rust.terminalMetrics(id: id)).framePulls,
        before.framePulls,
      );
      expect(a.sftpEnabled, false);
      expect(b.sftpEnabled, false);
      expect(model.transferTasks, isEmpty);
      await b.controller.text(
        "unset PROMPT_COMMAND; PS1=''; printf '\\033]7;%s\\007' 'file://different.invalid/not-current-root'",
      );
      await b.controller.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => b.controller.reportedDirectory == '/not-current-root',
        'foreign original-root OSC7',
      );
      await expectLater(
        rust.terminalRelativePaths(
          id: b.controller.id!,
          generation: b.controller.generation,
          paths: paths,
        ),
        throwsA(anything),
      );
      await c.text("printf '\\033]7;%s\\007' 'file://127.0.0.1/other'");
      await c.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => c.reportedDirectory == '/other',
        'changed OSC7 context',
      );
      await expectLater(
        rust.terminalRelativePaths(
          id: id,
          generation: generation,
          expectedDirectoryRevision: value.directoryRevision,
          paths: ['/other/file'],
        ),
        throwsA(anything),
      );
      await rust.disconnectTerminal(id: id);
      await waitFor(() => c.phase == 'Disconnected', 'relative disconnect');
      await expectLater(
        rust.terminalRelativePaths(
          id: id,
          generation: generation,
          paths: ['/other/file'],
        ),
        throwsA(anything),
      );
      expect(b.controller.connected, true);
    } finally {
      await model.shutdown();
      model.dispose();
      await ssh.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
