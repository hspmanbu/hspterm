import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/tmux.dart' as tmx;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/tmux_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  for (final remember in [false, true]) {
    test(
      'ordinary Shell reconnect keeps its per-terminal choice only when enabled ($remember)',
      () async {
        final f = await TmuxFixture.start();
        var choices = 0;
        f.model.requestTmuxChoice = (_, _) async {
          choices++;
          return tmx.TmuxSelection(
            kind: 1,
            restoreOnReconnect: remember,
            readonly: false,
            takeoverConfirmed: false,
            lockSize: false,
          );
        };
        try {
          f.model.openHost(f.host);
          final c = (f.model.focus! as LiveTerminalSession).controller;
          await waitFor(() => c.connected, 'ordinary Shell connects');
          await c.setVisible(true);
          await c.text("printf '%s%s\\n' ORDINARY_ SHELL_READY");
          await c.key(
            const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
          );
          await waitFor(
            () => screen(c).contains('ORDINARY_SHELL_READY'),
            'ordinary Shell output',
          );
          expect(
            await rust.terminalTmuxRestoreEnabled(
              id: c.id!,
              generation: c.generation,
            ),
            remember,
          );
          final id = c.id, previous = c.generation;
          await rust.disconnectTerminal(id: id!);
          await waitFor(
            () => c.phase == 'Disconnected',
            'ordinary Shell disconnects',
          );
          await c.reconnect();
          await waitFor(
            () => c.connected && c.generation > previous,
            'ordinary Shell reconnects',
          );
          expect(choices, remember ? 1 : 2);
          expect(c.id, id);
          expect(c.tmuxReadonly, null);
          expect(
            (await rust.listHosts()).single.tmuxEnabled,
            true,
            reason: 'the saved host preference is unchanged',
          );
          if (remember) {
            await rust.forgetTerminalTmuxRestore(
              id: id,
              generation: c.generation,
            );
            await rust.disconnectTerminal(id: id);
            await waitFor(
              () => c.phase == 'Disconnected',
              'forget Shell restore disconnects',
            );
            await c.reconnect();
            await waitFor(() => c.connected, 'forget Shell restore reconnects');
            expect(choices, 2);
          }
        } finally {
          await f.close();
        }
      },
      skip: !Platform.isLinux,
    );
  }
  test(
    'layout changed during tmux choice reaches unlocked PTY after connect',
    () async {
      final f = await TmuxFixture.start();
      final ready = Completer<tmx.TmuxPrompt>();
      final answer = Completer<tmx.TmuxSelection?>();
      f.model.requestTmuxChoice = (_, p) {
        ready.complete(p);
        return answer.future;
      };
      try {
        f.model.openHost(f.host);
        final c = (f.model.focus! as LiveTerminalSession).controller;
        final prompt = await ready.future.timeout(const Duration(seconds: 15));
        await c.setVisible(true);
        c.resize(132, 36, 9, 20);
        await waitFor(
          () => c.metadata?.columns == 132,
          'local resize while choosing',
        );
        expect(c.phase, 'Connecting');
        answer.complete(
          tmx.TmuxSelection(
            kind: 3,
            sessionId: prompt.sessions
                .singleWhere((s) => s.name == 'fixture')
                .id,
            readonly: false,
            takeoverConfirmed: true,
            lockSize: false,
          ),
        );
        await waitFor(
          () => c.connected,
          'unlocked tmux choice',
          timeout: const Duration(seconds: 10),
        );
        await waitFor(
          () => c.metadata?.columns == 132 && c.metadata?.rows == 36,
          'latest layout restored after choosing',
          timeout: const Duration(seconds: 3),
        );
        // window_height excludes the one-row tmux status line; the client's
        // actual PTY height above remains 36.
        expect(
          await f.command([
            'display-message',
            '-p',
            '-t',
            'fixture:',
            '#{window_width}x#{window_height}',
          ]),
          '132x35',
        );
      } finally {
        if (!answer.isCompleted) answer.complete(null);
        await f.close();
      }
    },
    skip: !Platform.isLinux,
  );
  test('real saved tmux option, locked PTY, SFTP and explicit reconnect keep the original SSH/session context', () async {
    final f = await TmuxFixture.start();
    var choices = 0;
    tmx.TmuxPrompt? old;
    f.model.requestTmuxChoice = (source, p) async {
      choices++;
      old ??= p;
      final s = p.sessions.singleWhere((s) => s.name == 'fixture');
      return tmx.TmuxSelection(
        kind: 3,
        sessionId: s.id,
        readonly: false,
        takeoverConfirmed: true,
        lockSize: true,
      );
    };
    try {
      expect((await rust.listHosts()).single.tmuxEnabled, true);
      f.model.openHost(f.host);
      final source = f.model.focus! as LiveTerminalSession,
          c = source.controller;
      await waitFor(
        () => c.connected || c.phase == 'Failed',
        'Native tmux connect',
      );
      expect(c.connected, true, reason: c.error);
      await c.setVisible(true);
      await waitFor(
        () => c.metadata?.sizeLocked == true && c.tmuxReadonly == false,
        'actual tmux lock and mode',
      );
      expect(source.statusLabel, contains('tmux控制'));
      final before = await f.command([
        'display-message',
        '-p',
        '-t',
        'fixture:',
        '#{window_width}x#{window_height}',
      ]);
      await c.backend.resize(c.id!, 120, 40, 9, 20);
      expect(
        await f.command([
          'display-message',
          '-p',
          '-t',
          'fixture:',
          '#{window_width}x#{window_height}',
        ]),
        before,
      );
      await c.backend.lockSize(c.id!, false);
      await c.backend.resize(c.id!, 120, 40, 9, 20);
      await waitFor(
        () => c.metadata?.columns == 120,
        'explicit unlock PTY dimensions',
      );
      expect(
        await f.command([
          'display-message',
          '-p',
          '-t',
          'fixture:',
          '#{window_width}',
        ]),
        '120',
      );
      await c.text(r"printf '%s%s 中é\n' TMUX_ UTF8");
      await c.key(
        const rust.KeyboardInput(key: 'Enter', kind: 0, modifiers: 0),
      );
      await waitFor(
        () => screen(c).contains('TMUX_UTF8 中é'),
        'real tmux Unicode/combining output',
      );
      await f.model.loadDirectory(source, '.');
      expect(source.sftpEnabled, true);
      final id = c.id!, generation = c.generation;
      await rust.disconnectTerminal(id: id);
      await waitFor(() => !c.connected, 'tmux explicit disconnect');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(choices, 1);
      await c.reconnect();
      await waitFor(
        () => c.connected && c.generation != generation,
        'explicit tmux reconnect',
      );
      expect(choices, 2);
      expect(c.id, id);
      expect(f.model.sessions.single, source);
      await expectLater(
        rust.answerTerminalTmux(
          id: id,
          generation: old!.generation,
          requestId: old!.requestId,
          selection: const tmx.TmuxSelection(
            kind: 1,
            readonly: false,
            takeoverConfirmed: false,
            lockSize: false,
          ),
        ),
        throwsA(anything),
      );
      expect(c.connected, true);
    } finally {
      await f.close();
    }
  }, skip: !Platform.isLinux);
  test('reopening Vault cancels an original pending tmux selection and a late answer cannot start a new PTY', () async {
    final f = await TmuxFixture.start();
    final answer = Completer<tmx.TmuxSelection?>();
    tmx.TmuxPrompt? pending;
    f.model.requestTmuxChoice = (_, p) {
      pending = p;
      return answer.future;
    };
    try {
      f.model.openHost(f.host);
      final c = (f.model.focus! as LiveTerminalSession).controller;
      await waitFor(() => pending != null, 'pending Native tmux consent');
      final id = c.id!, generation = pending!.generation;
      await rust.unlockVault(
        path: '${f.ssh.directory.path}/tmux.vault',
        password: 'synthetic-native-tmux-master',
      );
      await waitFor(
        () => c.phase == 'Failed' || c.phase == 'Disconnected',
        'Vault scope cancels pending tmux',
      );
      final error = c.error;
      answer.complete(
        tmx.TmuxSelection(
          kind: 3,
          sessionId: pending!.sessions.first.id,
          readonly: false,
          takeoverConfirmed: true,
          lockSize: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.connected, false);
      expect(c.generation, generation);
      expect(c.error, error);
      await expectLater(
        rust.terminalTmuxPrompt(id: id, requestId: pending!.requestId),
        throwsA(anything),
      );
      expect(
        await f.command([
          'list-clients',
          '-t',
          'fixture',
          '-F',
          '#{client_tty}',
        ]),
        isEmpty,
      );
    } finally {
      if (!answer.isCompleted) answer.complete(null);
      await f.close();
    }
  }, skip: !Platform.isLinux);
}
