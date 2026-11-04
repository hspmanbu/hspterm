import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/links.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/terminal_links.dart';
import 'package:hspterm/src/rust/api.dart' as rust;

import '../test/native_bridge_test.dart' show waitFor;
import '../test/forwarding_runtime_bridge_test.dart' show echo;
import '../test/support/local_sshd.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK confirmation alone creates ephemeral original-session forwarding and browser failure cleans only that listener',
    (tester) async {
      await initializeRust();
      final ssh = await LocalSshd.start();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>{};
      var acceptedSockets = 0;
      final accepting = server.listen((socket) {
        acceptedSockets++;
        sockets.add(socket);
        socket.listen(
          socket.add,
          onDone: () {
            sockets.remove(socket);
            socket.destroy();
          },
          onError: (Object _) {
            sockets.remove(socket);
            socket.destroy();
          },
        );
      });
      final model = LiveWorkbenchModel();
      try {
        await rust.unlockVault(
          path: '${ssh.directory.path}/link.vault',
          password: 'synthetic-link-master',
        );
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'Link fixture',
            '127.0.0.1',
            '未分组',
            port: ssh.port,
            user: ssh.username,
            auth: '私钥',
            openSftp: false,
          ),
          secret: ssh.privateKey,
          passphrase: 'test-only-passphrase',
        );
        model.openHost(host);
        final source = model.focus! as LiveTerminalSession;
        await waitFor(
          () => source.controller.connected || source.controller.error != null,
          'link SSH',
        );
        expect(
          source.controller.connected,
          true,
          reason: source.controller.error,
        );
        final id = source.controller.id!,
            generation = source.controller.generation;
        await source.controller.setVisible(true);
        final target = 'http://127.0.0.1:${server.port}/path?q=one#two';
        await source.controller.text(
          "PS1=''; printf '\\033[2J\\033[3J\\033[H\\033]8;;$target\\033\\\\original-session link\\033]8;;\\033\\\\\\r\\n'",
        );
        await source.controller.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => source.controller.hyperlinks
              .expand((r) => r)
              .any((s) => s.uri == target),
          'real OSC8 link target',
        );
        var link = TerminalLink.atGrid(
          source.controller.rows,
          0,
          0,
          hyperlinks: source.controller.hyperlinks,
        )!;
        expect(link.text, target);
        await source.controller.setVisible(false);
        var launchSuccess = true;
        final opened = <Uri>[];
        Future<void>? pending;
        Object? failure;
        await tester.pumpWidget(
          MaterialApp(
            theme: Desk.theme(false),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    failure = null;
                    pending = openTerminalLink(
                      context,
                      model,
                      source,
                      link,
                      launcher: (uri) async {
                        opened.add(uri);
                        return launchSuccess;
                      },
                    );
                    unawaited(
                      pending!.catchError((Object error) {
                        failure = error;
                      }),
                    );
                  },
                  child: const Text('打开测试链接'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开测试链接'));
        await tester.pumpAndSettle();
        expect(find.text('通过原 SSH 临时转发？'), findsOneWidget);
        expect(await rust.terminalForwardings(id: id), isEmpty);
        expect(acceptedSockets, 0);
        expect(opened, isEmpty);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await pending;
        expect(await rust.terminalForwardings(id: id), isEmpty);
        await tester.tap(find.text('打开测试链接'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('转发并打开'));
        await tester.pumpAndSettle();
        await pending;
        expect(failure, isNull);
        expect(opened, hasLength(1));
        final first = (await rust.terminalForwardings(id: id)).single;
        expect(first.generation, generation);
        expect(first.phase, 'listening');
        expect(opened.single.host, '127.0.0.1');
        expect(opened.single.port, first.bindPort);
        expect(opened.single.path, '/path');
        expect(opened.single.query, 'q=one');
        expect(opened.single.fragment, 'two');
        expect(
          acceptedSockets,
          0,
          reason: 'confirmation binds but does not probe',
        );
        await echo(first, server.port);
        expect(await rust.forwardingRules(hostId: host.id), isEmpty);
        launchSuccess = false;
        await tester.tap(find.text('打开测试链接'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('转发并打开'));
        await tester.pumpAndSettle();
        await expectLater(pending!, throwsA(anything));
        expect(failure, isNotNull);
        expect(source.controller.connected, true);
        final runtimes = await rust.terminalForwardings(id: id);
        expect(
          runtimes.where((r) => r.phase == 'listening').map((r) => r.token),
          [first.token],
        );
        expect(runtimes.where((r) => r.phase == 'stopped'), hasLength(1));
        await echo(first, server.port);
        await tester.tap(find.text('打开测试链接'));
        await tester.pumpAndSettle();
        await rust.disconnectTerminal(id: id);
        await tester.pumpAndSettle();
        final before = opened.length;
        await tester.tap(find.text('转发并打开'));
        await tester.pumpAndSettle();
        await pending;
        expect(opened, hasLength(before));
        expect(await rust.terminalForwardings(id: id), isEmpty);
        launchSuccess = true;
        link = TerminalLink.parse('https://example.invalid/retained-history')!;
        await tester.tap(find.text('打开测试链接'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        await pending;
        expect(
          opened.last.toString(),
          'https://example.invalid/retained-history',
        );
        expect(
          source.controller.connected,
          false,
          reason: 'ordinary browser action must not reconnect SSH',
        );
        expect(source.controller.id, id);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        for (final socket in sockets.toList()) {
          socket.destroy();
        }
        await accepting.cancel();
        await server.close();
        await ssh.close();
      }
    },
  );
}
