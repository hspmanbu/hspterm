import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';

import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('old-vault host confirmation cannot trust a reopened or different vault; accepted SSH stays connected', () async {
    final server = await LocalSshd.start();
    final id = await rust.createTerminal(
      columns: 80,
      rows: 24,
      historyLines: 100,
    );
    final prompts = <rust.BridgeEvent>[];
    final done = Completer<void>();
    final events = rust.watchEvents(id: id).listen((event) {
      if (event.kind == 'hostKey') prompts.add(event);
    }, onDone: done.complete);
    Future<rust.BridgeEvent> nextPrompt(int index) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (prompts.length <= index) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('synthetic host confirmation');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return prompts[index];
    }

    Future<rust.Profile> save() => rust.saveProfile(
      profile: rust.Profile(
        id: '',
        name: 'Original identity fixture',
        address: '127.0.0.1',
        port: server.port,
        username: server.username,
        privateKey: true,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
    try {
      final first = '${server.directory.path}/first.vault',
          second = '${server.directory.path}/second.vault';
      const password = 'synthetic-identity-master';
      await rust.unlockVault(path: first, password: password);
      final original = await save();
      final connecting = rust.connectTerminal(id: id, profileId: original.id);
      final failure = expectLater(connecting, throwsA(anything));
      final old = await nextPrompt(0);
      await rust.unlockVault(path: second, password: password);
      await failure.timeout(const Duration(seconds: 5));
      await expectLater(
        rust.answerHostKey(id: id, requestId: old.requestId, accept: true),
        throwsA(anything),
      );
      final other = await save();
      final retry = rust.connectTerminal(id: id, profileId: other.id);
      final prompt = await nextPrompt(1);
      expect(prompt.text, old.text);
      // A failed unlock must leave the current confirmation and trust source intact.
      await expectLater(
        rust.unlockVault(path: second, password: 'wrong-synthetic-master'),
        throwsA(anything),
      );
      await rust.answerHostKey(
        id: id,
        requestId: prompt.requestId,
        accept: true,
      );
      await retry;
      await rust.unlockVault(path: first, password: password);
      // Previously accepted SSH is not forced closed by replacing the Vault.
      await rust.sendText(id: id, text: "printf 'identity_still_alive'");
      await rust.disconnectTerminal(id: id);
      final again = rust.connectTerminal(id: id, profileId: original.id);
      final pending = expectLater(again, throwsA(anything));
      final samePathOld = await nextPrompt(2);
      await rust.unlockVault(path: first, password: password);
      await pending.timeout(const Duration(seconds: 5));
      await expectLater(
        rust.answerHostKey(
          id: id,
          requestId: samePathOld.requestId,
          accept: true,
        ),
        throwsA(anything),
      );
    } finally {
      await rust.destroyTerminal(id: id);
      await done.future.timeout(const Duration(seconds: 5));
      await events.cancel();
      await server.close();
    }
  });
}
