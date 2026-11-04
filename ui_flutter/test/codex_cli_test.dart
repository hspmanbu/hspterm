import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

/// Stop only processes whose executable belongs to this disposable account.
/// Codex's pid-update-loop can outlive `daemon stop`; never inspect user env/auth.
Future<void> stopIsolatedCodex(String home) async {
  if (!await Directory('$home/codex').exists()) return;
  final stop = await Process.run(
    '/usr/bin/codex',
    ['app-server', 'daemon', 'stop'],
    environment: {
      'PATH': '/usr/bin:/bin',
      'HOME': home,
      'CODEX_HOME': '$home/codex',
      'XDG_RUNTIME_DIR': '$home/runtime',
      'XDG_DATA_HOME': '$home/data',
      'XDG_CONFIG_HOME': '$home/config',
      'XDG_CACHE_HOME': '$home/cache',
      'TMPDIR': '$home/tmp',
    },
    includeParentEnvironment: false,
  );
  Future<List<int>> ownedProcesses() async {
    final owned = <int>[];
    await for (final entry in Directory('/proc').list()) {
      final id = int.tryParse(entry.path.split('/').last);
      if (id == null) continue;
      try {
        final executable = await Link('${entry.path}/exe').target();
        if (!executable.startsWith('$home/codex/packages/app-server-daemon/')) {
          continue;
        }
        final args = (await File(
          '${entry.path}/cmdline',
        ).readAsString()).split('\u0000');
        if (args.length >= 4 &&
            args[1] == 'app-server' &&
            args[2] == 'daemon') {
          owned.add(id);
        }
      } on FileSystemException {
        // A process may exit while /proc is being enumerated.
      }
    }
    return owned;
  }

  for (var attempt = 0; attempt < 30; attempt++) {
    final remaining = await ownedProcesses();
    if (remaining.isEmpty) {
      if (stop.exitCode != 0) {
        throw StateError(
          'Isolated Codex daemon stop failed (${stop.exitCode})',
        );
      }
      return;
    }
    for (final id in remaining) {
      Process.killPid(
        id,
        attempt < 20 ? ProcessSignal.sigterm : ProcessSignal.sigkill,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('Isolated Codex auxiliary process did not exit');
}

/// Runs the real installed Codex TUI with an isolated HOME and a loopback-only
/// synthetic Responses provider. No real login/keyring/account or model task.
Future<void> exerciseCodex({
  Future<void> Function(TerminalController)? attach,
  Future<void> Function()? capture,
  Future<void> Function(String, int)? physicalKey,
}) async {
  await initializeRust();
  final server = await LocalSshd.start();
  final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final controller = TerminalController(const NativeTerminalBackend());
  final received = <String>[];
  var responses = 0, requests = 0;
  Object? providerError;
  final subscription = provider.listen((request) async {
    if (request.method != 'POST') {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"data":[]}');
      await request.response.close();
      return;
    }
    try {
      final decoded = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final input = decoded['input'];
      var userText = '';
      if (input is List) {
        final user = input
            .whereType<Map>()
            .where((item) => item['role'] == 'user')
            .lastOrNull;
        if (user != null && user['content'] is List) {
          userText = ((user['content'] as List)
              .whereType<Map>()
              .where((part) => part['type'] == 'input_text')
              .map((part) => part['text'])
              .join());
        }
      }
      // Codex may issue an independent, shortened title-generation request.
      // Count/assert full interactive turns independently of that background call.
      final title = userText.startsWith(
        'Generate a concise, single-line task title',
      );
      if (!title) received.add(userText);
      final number = title ? 0 : ++responses;
      requests++;
      final id = 'hspterm_response_$requests',
          message = 'hspterm_message_$requests';
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        'text/event-stream; charset=utf-8',
      );
      Future<void> emit(Map<String, Object?> event) async {
        request.response.write(
          'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n',
        );
        await request.response.flush();
      }

      await emit({
        'type': 'response.created',
        'response': {'id': id},
      });
      await emit({
        'type': 'response.output_item.added',
        'output_index': 0,
        'item': {
          'type': 'message',
          'role': 'assistant',
          'id': message,
          'content': [],
        },
      });
      final text = StringBuffer();
      for (var i = 0; i < (title ? 1 : 100); i++) {
        final delta = title
            ? 'Synthetic test title'
            : 'fixture $i 中文 é terminal-only rendering\n';
        text.write(delta);
        await emit({
          'type': 'response.output_text.delta',
          'item_id': message,
          'output_index': 0,
          'content_index': 0,
          'delta': delta,
        });
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }
      final done = title ? '' : 'CODEX_RESPONSE_DONE_$number';
      text.write(done);
      await emit({
        'type': 'response.output_text.delta',
        'item_id': message,
        'output_index': 0,
        'content_index': 0,
        'delta': done,
      });
      await emit({
        'type': 'response.output_item.done',
        'output_index': 0,
        'item': {
          'type': 'message',
          'role': 'assistant',
          'id': message,
          'content': [
            {'type': 'output_text', 'text': text.toString()},
          ],
        },
      });
      await emit({
        'type': 'response.completed',
        'response': {
          'id': id,
          'usage': {'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0},
        },
      });
      await request.response.close();
    } catch (error) {
      providerError = error;
      // Once streaming starts headers are immutable; retain the first fixture
      // failure for the test instead of hiding it behind a second HTTP error.
      try {
        await request.response.close();
      } catch (closeError) {
        providerError ??= closeError;
      }
    }
  });
  try {
    await rust.unlockVault(
      path: '${server.directory.path}/codex-test.vault',
      password: 'test-only-codex-vault',
    );
    final profile = await rust.saveProfile(
      profile: rust.Profile(
        id: '',
        name: 'isolated Codex fixture',
        address: '127.0.0.1',
        port: server.port,
        username: server.username,
        privateKey: true,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
    controller.confirmHostKey = (_) async => true;
    await controller.start();
    if (attach != null) await attach(controller);
    await controller.connect(profile.id);
    await waitFor(() => controller.connected, 'Codex SSH connect');
    Future<void> key(String key, {int modifiers = 0, String? text}) =>
        physicalKey != null
        ? physicalKey(key, modifiers)
        : controller.key(
            rust.KeyboardInput(
              key: key,
              text: text,
              modifiers: modifiers,
              kind: 0,
            ),
          );
    Future<void> enter(String value) async {
      await controller.text(value);
      await key('Enter');
    }

    final workspace = Directory('${server.directory.path}/workspace');
    await workspace.create();
    for (final noAlt in [true, false]) {
      final home = Directory(
        '${server.directory.path}/account-${noAlt ? 0 : 1}',
      );
      await home.create();
      final codex = Directory('${home.path}/codex');
      await codex.create();
      await File('${codex.path}/config.toml')
          .writeAsString('''model = "hspterm-fixture"
model_provider = "hspterm_test"
check_for_update_on_startup = false
cli_auth_credentials_store = "file"
[analytics]
enabled = false
[feedback]
enabled = false
[model_providers.hspterm_test]
name = "HSPTerm loopback fixture"
base_url = "http://127.0.0.1:${provider.port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
[projects."${workspace.path}"]
trust_level = "trusted"
''');
      for (final directory in ['runtime', 'tmp', 'data', 'config', 'cache']) {
        await Directory('${home.path}/$directory').create();
      }
      final command =
          "env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME='${home.path}' CODEX_HOME='${codex.path}' XDG_RUNTIME_DIR='${home.path}/runtime' XDG_DATA_HOME='${home.path}/data' XDG_CONFIG_HOME='${home.path}/config' XDG_CACHE_HOME='${home.path}/cache' TMPDIR='${home.path}/tmp' TERM=xterm-256color LANG=C.UTF-8 /usr/bin/codex -C '${workspace.path}' --sandbox read-only --ask-for-approval never ${noAlt ? '--no-alt-screen' : ''}";
      await enter(command);
      try {
        await waitFor(
          () =>
              screen(controller).contains('hspterm-fixture') &&
              !screen(controller).contains('Error loading configuration'),
          'real Codex startup',
          timeout: const Duration(seconds: 30),
        );
      } catch (_) {
        throw StateError(
          'Isolated Codex startup failed: ${screen(controller)}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      for (final name in ['ArrowUp', 'ArrowDown', 'Tab', 'Escape', 'Enter']) {
        await key(name);
      }
      await controller.text('hspterm_codex_probe 中文');
      await key('ArrowLeft');
      await key('ArrowRight');
      await key('a', modifiers: 4);
      await key('e', modifiers: 4);
      await key('b', modifiers: 2);
      await key('f', modifiers: 2);
      await key('Enter', modifiers: 1);
      await controller.text('shift newline');
      // Codex batches rapid raw text as paste; wait for its input burst detector
      // before an explicit submit, as a person does after typing/pasting.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final expected = responses + 1;
      await key('Enter');
      try {
        await waitFor(
          () => screen(controller).contains('CODEX_RESPONSE_DONE_$expected'),
          'real Codex streamed response',
          timeout: const Duration(seconds: 40),
        );
      } catch (_) {
        throw StateError(
          'Codex fixture interaction failed: ${screen(controller)}; fixtureRequests=${received.length}; providerError=$providerError',
        );
      }
      expect(received.last, contains('hspterm_codex_probe 中文'));
      expect(received.last, contains('shift newline'));
      final paste =
          'hspterm_multiline_中文\n${'long-input '.padRight(80, 'x') * 30}';
      final preview = await controller.paste(paste, false);
      expect(preview.needsConfirmation, true);
      final before = responses;
      await controller.paste(paste, true);
      await controller.backend.resize(controller.id!, 87, 28, 9, 21);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await key('Enter');
      await waitFor(
        () =>
            responses > before &&
            screen(controller).contains('CODEX_RESPONSE_DONE_${before + 1}'),
        'Codex multiline paste and resize',
        timeout: const Duration(seconds: 40),
      );
      expect(received.last, contains('hspterm_multiline_中文'));
      expect(received.last, contains('x' * 40));
      expect(received.last.length, greaterThan(2000));
      expect(providerError, isNull);
      if (capture != null) await capture();
      for (var i = 0; i < 3; i++) {
        await key('c', modifiers: 4);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await enter("printf '%s%s\\n' CODEX_ EXIT");
      await waitFor(
        () => screen(controller).contains('CODEX_EXIT'),
        'real Codex exit',
      );
    }
  } finally {
    await controller.shutdown();
    controller.dispose();
    // Codex 0.163 may keep a managed app-server daemon after the TUI exits.
    // Stop only these two disposable accounts, never the user's real daemon.
    for (final n in [0, 1]) {
      final home = '${server.directory.path}/account-$n';
      await stopIsolatedCodex(home);
    }
    await provider.close(force: true);
    await subscription.cancel();
    await server.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real Codex TUI over SSH with isolated loopback synthetic provider',
    exerciseCodex,
    timeout: const Timeout(Duration(minutes: 4)),
    skip: !Platform.isLinux || !File('/usr/bin/codex').existsSync()
        ? 'Linux installed Codex CLI required'
        : false,
  );
}
