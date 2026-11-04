import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/directory_reader.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';

class _Hold {
  final entered = Completer<void>(), release = Completer<void>();
}

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

void main() {
  test(
    'opt-in directory following is serial, session-bound and yields to explicit navigation',
    () async {
      await initializeRust();
      final server = await LocalSshd.start();
      _Hold? nextHold;
      final holds = <_Hold>[];
      final model = LiveWorkbenchModel(
        directoryReader: PagedDirectoryReader(
          page:
              ({
                required id,
                required generation,
                required request,
                required limit,
              }) async {
                final hold = nextHold;
                if (hold != null) {
                  nextHold = null;
                  hold.entered.complete();
                  await hold.release.future;
                }
                return rust.sftpDirectoryPage(
                  id: id,
                  generation: generation,
                  request: request,
                  limit: limit,
                );
              },
        ),
      );
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/follow.vault',
          password: 'synthetic follow master',
        );
        await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Follow fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        await model.load();
        expect(model.hosts.single.followOsc7, false);
        model.confirmHostKey = (_, _) async => true;
        model.openHost(model.hosts.single);
        model.openHost(model.hosts.single);
        final source = model.sessions[1] as LiveTerminalSession,
            other = model.sessions[0] as LiveTerminalSession;
        await waitFor(
          () =>
              source.sftpEnabled &&
              other.sftpEnabled &&
              !source.loadingDirectory &&
              !other.loadingDirectory,
          'initial explicit SSH/SFTP',
        );
        final original = source.path, otherOriginal = other.path;
        final id = source.controller.id,
            generation = source.controller.generation;
        final width = model.sidebarWidth, queueHeight = model.queueHeight;
        final alpha = await Directory('${server.directory.path}/alpha 中文')
            .create();
        final beta = await Directory('${server.directory.path}/beta').create();
        final gamma = await Directory('${server.directory.path}/gamma')
            .create();
        final delta = await Directory('${server.directory.path}/delta')
            .create();
        Future<void> report(
          String path, {
          String authority = '127.0.0.1',
        }) async {
          final uri = Uri(
            scheme: 'file',
            host: authority,
            path: path,
          ).toString();
          final before = source.controller.directoryReportVersion;
          await source.controller.text(
            "unset PROMPT_COMMAND; PS1=''; printf '\\033]7;%s\\007' ${_quote(uri)}",
          );
          await source.controller.key(
            rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
          );
          await waitFor(
            () =>
                source.controller.directoryReportVersion > before &&
                source.controller.reportedDirectory == path,
            'passive directory report',
          );
        }

        await report(alpha.path);
        expect(
          source.path,
          original,
          reason: 'default disabled never navigates',
        );
        await model.persistHost(
          model.hosts.single.snapshot()..followOsc7 = true,
        );
        expect((await rust.listHosts()).single.followOsc7, true);
        await waitFor(
          () => source.path == alpha.path && !source.loadingDirectory,
          'enabled follow',
        );
        model.toggleSidebar();
        expect(model.sidebar, false);
        await report(beta.path);
        expect(
          source.path,
          alpha.path,
          reason: 'hidden sidebar keeps the report without fetching a listing',
        );
        expect(
          model.sidebar,
          false,
          reason: 'a report never expands the sidebar',
        );
        model.toggleSidebar();
        await waitFor(
          () => source.path == beta.path && !source.loadingDirectory,
          'deferred visible follow',
        );
        await model.loadDirectory(source, original);
        await Future<void>.delayed(const Duration(milliseconds: 220));
        expect(
          source.path,
          original,
          reason: 'same report does not undo explicit navigation',
        );
        await report('/unrelated-authority', authority: 'different.invalid');
        await Future<void>.delayed(const Duration(milliseconds: 220));
        expect(source.path, original);
        expect(source.sftpError, isNull);
        final first = _Hold();
        holds.add(first);
        nextHold = first;
        await report(gamma.path);
        await first.entered.future.timeout(const Duration(seconds: 10));
        await model.loadDirectory(source, original);
        first.release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 220));
        expect(
          source.path,
          original,
          reason: 'late page from a cancelled follow cannot override user navigation',
        );
        final second = _Hold();
        holds.add(second);
        nextHold = second;
        await report(delta.path);
        await second.entered.future.timeout(const Duration(seconds: 10));
        await report(alpha.path);
        second.release.complete();
        await waitFor(
          () => source.path == alpha.path && !source.loadingDirectory,
          'latest report after old follow is drained',
        );
        model.selectTab(
          model.tabs.firstWhere((t) => t.sessionId == other.id).id,
        );
        await report(beta.path);
        expect(source.path, alpha.path);
        expect(
          other.path,
          otherOriginal,
          reason: 'hidden session A cannot steer focused B',
        );
        model.selectTab(
          model.tabs.firstWhere((t) => t.sessionId == source.id).id,
        );
        await waitFor(
          () => source.path == beta.path && !source.loadingDirectory,
          'return to source applies only its own latest report',
        );
        await model.persistHost(
          model.hosts.single.snapshot()..followOsc7 = false,
        );
        await report(gamma.path);
        await Future<void>.delayed(const Duration(milliseconds: 220));
        expect(source.path, beta.path);
        expect(source.controller.id, id);
        expect(source.controller.generation, generation);
        expect(model.sidebarWidth, width);
        expect(model.queueHeight, queueHeight);
        expect(await rust.listTransferTasks(), isEmpty);
      } finally {
        for (final hold in holds) {
          if (!hold.release.isCompleted) hold.release.complete();
        }
        await model.shutdown();
        model.dispose();
        await server.close();
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
