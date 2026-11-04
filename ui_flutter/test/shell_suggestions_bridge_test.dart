import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show screen, waitFor;
import 'support/local_sshd.dart';

void main() {
  test('real saved-host history, single-use candidate and literal paths stay source-bound', () async {
    await initializeRust();
    final server = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    final c = TerminalController(const NativeTerminalBackend());
    try {
      await File('${server.directory.path}/.bashrc')
          .writeAsString("PS1='hsp-bridge> '; PROMPT_COMMAND=()\n");
      await rust.unlockVault(
        path: '${server.directory.path}/suggestions.vault',
        password: 'synthetic-suggestions-master',
      );
      await model.load();
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Synthetic opted-in Bash',
          '127.0.0.1',
          (await rust.hostGroups()).first.name,
          user: server.username,
          port: server.port,
          auth: '私钥',
          openSftp: false,
          shellIntegration: true,
        ),
        secret: server.privateKey,
        passphrase: 'test-only-passphrase',
      );
      c.confirmHostKey = (_) async => true;
      await c.start();
      await c.connect(host.id); // Await actual Native target/scope binding too.
      await waitFor(
        () =>
            screen(c).contains('hsp-bridge> ') && c.shellInputChanges.value > 0,
        'private initial Readline prompt',
      );
      Future<void> enter(String text) async {
        await c.text(text);
        await c.key(rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0));
      }

      bool promptVisible() {
        final frame = c.metadata;
        if (frame == null ||
            frame.cursorRow < 0 ||
            frame.cursorRow >= c.rows.length) {
          return false;
        }
        return c.rows[frame.cursorRow]
                .where((cell) => cell.flags & 64 == 0)
                .map((cell) => cell.text)
                .join()
                .trimRight() ==
            'hsp-bridge>';
      }

      Future<rust.TerminalSuggestions> candidates(String stage) async {
        rust.TerminalSuggestions? value;
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(end)) {
          value = await rust.terminalSuggestions(
            id: c.id!,
            generation: c.generation,
          );
          if (value != null) return value;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        throw StateError(
          'synthetic candidate was not qualified: $stage, phase=${c.phase}, inputEvents=${c.shellInputChanges.value}',
        );
      }

      const command = "printf 'HSP_HISTORY_%s\\n' READY";
      await enter(command);
      await waitFor(
        () =>
            screen(c)
                .split('\n')
                .any((line) => line.trim() == 'HSP_HISTORY_READY'),
        'actual output, not input echo',
      );
      // Repository statistics are metadata; never print candidate contents.
      final end = DateTime.now().add(const Duration(seconds: 20));
      while ((await rust.commandHistoryControls()).total == 0) {
        if (DateTime.now().isAfter(end)) {
          throw StateError('actor-owned history was not committed');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await waitFor(promptVisible, 'fresh fixture prompt after output');
      await c.text('printf');
      final proposal = await candidates('first prefix');
      expect(proposal.choices, contains(command));
      final choice = proposal.choices.indexOf(command);
      expect(
        await rust.chooseTerminalSuggestion(
          id: c.id!,
          generation: c.generation,
          ticket: 'stale',
          index: choice,
          execute: true,
        ),
        'Unavailable',
      );
      expect(
        await rust.chooseTerminalSuggestion(
          id: c.id!,
          generation: c.generation,
          ticket: proposal.ticket,
          index: choice,
          execute: false,
        ),
        'Applied',
      );
      expect(
        await rust.chooseTerminalSuggestion(
          id: c.id!,
          generation: c.generation,
          ticket: proposal.ticket,
          index: choice,
          execute: true,
        ),
        'Unavailable',
      );
      expect(
        await rust.insertTerminalPaths(
          id: c.id!,
          generation: c.generation,
          paths: ['/tmp'],
          enterDirectory: true,
        ),
        'Unavailable',
        reason: 'explicit cd cannot erase an existing command',
      );
      final before = c.shellInputChanges.value;
      final beforeFrame = c.metadata!.contentRevision;
      await c.key(rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0));
      await waitFor(
        // A submission receipt also increments shellInputChanges. Wait for the
        // next rendered fixture prompt, not merely that earlier acceptance.
        () =>
            c.shellInputChanges.value > before &&
            c.metadata!.contentRevision > beforeFrame &&
            promptVisible(),
        'next actual Readline prompt after submission receipt',
      );
      await c.text('printf');
      final stale = await candidates('prefix after controlled fill and Enter');
      final controls = await rust.commandHistoryControls();
      await rust.clearCommandHistory(
        vaultScope: controls.vaultScope,
        revision: controls.revision,
        hostId: host.id,
      );
      expect(
        await rust.terminalSuggestions(id: c.id!, generation: c.generation),
        isNull,
      );
      expect(
        await rust.chooseTerminalSuggestion(
          id: c.id!,
          generation: c.generation,
          ticket: stale.ticket,
          index: 0,
          execute: true,
        ),
        'Unavailable',
      );
      expect(
        await rust.insertTerminalPaths(
          id: c.id!,
          generation: c.generation + 1,
          paths: ['/tmp'],
          enterDirectory: false,
        ),
        'Unavailable',
      );
      // Literal shell syntax must remain one path and is never executed by insert.
      const path = "/tmp/中文 a'\$;x";
      expect(
        await rust.insertTerminalPaths(
          id: c.id!,
          generation: c.generation,
          paths: [path],
          enterDirectory: false,
        ),
        'Applied',
      );
      expect(c.connected, true);
    } finally {
      await c.shutdown();
      c.dispose();
      await model.shutdown();
      model.dispose();
      await server.close();
    }
  }, skip: !Platform.isLinux);
}
