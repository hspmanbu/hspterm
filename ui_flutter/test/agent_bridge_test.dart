import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/agents.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

String shell(String value) => "'${value.replaceAll("'", "'\\''")}'";
Future<DemoHost> save(
  LiveWorkbenchModel model,
  LocalSshd server,
  String name, {
  bool agent = false,
}) => model.persistHost(
  DemoHost(
    model.nextId(),
    name,
    '127.0.0.1',
    '未分组',
    user: server.username,
    port: server.port,
    auth: '私钥',
    openSftp: false,
    agentForwarding: agent,
  ),
  secret: server.privateKey,
  passphrase: 'test-only-passphrase',
);
Future<void> command(TerminalController c, String text) async {
  await c.text(text);
  await c.key(rust.KeyboardInput(key: 'Enter', kind: 0, modifiers: 0));
}

Future<TerminalController> connected(
  LiveWorkbenchModel model,
  DemoHost host,
) async {
  model.confirmHostKey = (_, _) async => true;
  model.openHost(host);
  final c = (model.sessions.single as LiveTerminalSession).controller;
  await waitFor(() => c.connected, 'Agent fixture connects');
  await c.setVisible(true);
  await waitFor(
    () => screen(c).contains(RegExp(r'[$#]')),
    'initial shell prompt',
  );
  return c;
}

Future<void> reconnect(TerminalController c) async {
  final old = c.generation;
  await rust.disconnectTerminal(id: c.id!);
  await waitFor(() => !c.connected, 'original SSH disconnected');
  await c.reconnect();
  await waitFor(
    () => c.connected && c.generation > old,
    'explicit new SSH root',
  );
}

Future<AgentView> state(TerminalController c) =>
    rust.terminalAgentState(id: c.id!, generation: c.generation);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('real Native consent binds keys, original session and Vault; hidden push, revoke, reconnect and source deletion are safe', () async {
    final first = await LocalSshd.start(), second = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      final path = '${first.directory.path}/agent.vault';
      const password = 'synthetic-agent-master';
      await rust.unlockVault(path: path, password: password);
      await model.load();
      final host = await save(
        model,
        first,
        'Agent target fixture',
        agent: true,
      );
      final keyHost = await save(model, second, 'Selected app key fixture');
      expect(
        (await rust.listHosts())
            .singleWhere((h) => h.id == host.id)
            .agentForwarding,
        true,
      );
      final c = await connected(model, host);
      expect((await state(c)).phase, 'Ready');
      final id = c.id!, generation = c.generation;
      final keys = await rust.agentKeyOptions();
      expect(keys.map((k) => k.hostId), contains(keyHost.id));
      expect(
        keys.every((k) => k.fingerprint == null),
        true,
        reason: 'listing metadata never decrypts every private key',
      );
      await expectLater(
        rust.approveAgentAuthorisation(
          id: id,
          generation: generation,
          ticket: 'unreviewed',
        ),
        throwsA(anything),
      );
      Future<AgentPreview> prepare() => rust.prepareAgentAuthorisation(
        id: id,
        generation: c.generation,
        hostIds: [keyHost.id],
        seconds: 60,
      );
      final old = await prepare(), latest = await prepare();
      expect(latest.keys.single.fingerprint, startsWith('SHA256:'));
      expect(latest.target, contains('127.0.0.1:${first.port}'));
      expect(latest.hostKey, startsWith('SHA256:'));
      await expectLater(
        rust.approveAgentAuthorisation(
          id: id,
          generation: generation,
          ticket: old.ticket,
        ),
        throwsA(anything),
      );
      await rust.cancelAgentAuthorisation(id: id, ticket: latest.ticket);
      await expectLater(
        rust.approveAgentAuthorisation(
          id: id,
          generation: generation,
          ticket: latest.ticket,
        ),
        throwsA(anything),
      );
      expect((await state(c)).phase, 'Ready');
      await c.setVisible(false);
      final frames = c.frameCount, changes = c.agentChanges.value;
      final preview = await prepare();
      final granted = await rust.approveAgentAuthorisation(
        id: id,
        generation: generation,
        ticket: preview.ticket,
      );
      expect(granted.phase, 'Active');
      expect(granted.keyCount, 1);
      await waitFor(
        () => c.agentChanges.value > changes,
        'original Agent state pushes while hidden',
      );
      expect(c.frameCount, frames);
      // Alias hosts with the same private key cannot turn a preview into a
      // duplicate grant, or revoke the already-authorized different key.
      final copied = await rust.copyHostToDraft(id: host.id);
      final savedCopy = await rust.saveHost(host: copied);
      await expectLater(
        rust.prepareAgentAuthorisation(
          id: id,
          generation: generation,
          hostIds: [host.id, savedCopy.id],
          seconds: 60,
        ),
        throwsA(anything),
      );
      expect((await state(c)).phase, 'Active');
      await expectLater(
        rust.prepareAgentAuthorisation(
          id: id,
          generation: generation,
          hostIds: List.filled(17, keyHost.id),
          seconds: 60,
        ),
        throwsA(anything),
      );
      expect((await state(c)).phase, 'Active');
      await rust.deleteHosts(ids: [savedCopy.id]);
      await expectLater(
        rust.approveAgentAuthorisation(
          id: id,
          generation: generation,
          ticket: preview.ticket,
        ),
        throwsA(anything),
      );
      await c.setVisible(true);
      final selectedPublic = shell('${second.directory.path}/client.pub');
      final unselectedPublic = shell('${first.directory.path}/client.pub');
      await command(
        c,
        "ssh-add -T $selectedPublic && printf '%s%s\\n' APP_AGENT_ VERIFIED; ssh-add -T $unselectedPublic >/dev/null 2>&1; test \$? -ne 0 && printf '%s%s\\n' UNSELECTED_ DENIED",
      );
      await waitFor(
        () =>
            screen(c).contains('APP_AGENT_VERIFIED') &&
            screen(c).contains('UNSELECTED_DENIED'),
        'real remote sign/verify accepts only selected key',
      );
      await rust.revokeTerminalAgent(id: id, generation: generation);
      expect((await state(c)).phase, 'Revoked');
      expect(c.connected, true);
      expect(c.generation, generation);
      final staleConnection = await prepare();
      await reconnect(c);
      expect((await state(c)).phase, 'Ready');
      await expectLater(
        rust.approveAgentAuthorisation(
          id: id,
          generation: generation,
          ticket: staleConnection.ticket,
        ),
        throwsA(anything),
      );
      final again = await prepare();
      await rust.approveAgentAuthorisation(
        id: id,
        generation: c.generation,
        ticket: again.ticket,
      );
      await rust.unlockVault(path: path, password: password);
      expect((await state(c)).phase, 'Revoked');
      expect(c.connected, true);
      await expectLater(prepare(), throwsA(anything));
      await reconnect(c);
      final beforeCredentialEdit = await prepare();
      await model.persistHost(
        keyHost.snapshot(),
        secret: first.privateKey,
        passphrase: 'test-only-passphrase',
      );
      await expectLater(
        rust.approveAgentAuthorisation(
          id: id,
          generation: c.generation,
          ticket: beforeCredentialEdit.ticket,
        ),
        throwsA(anything),
      );
      final edited = await prepare();
      expect(
        edited.keys.single.fingerprint,
        isNot(preview.keys.single.fingerprint),
      );
      await rust.approveAgentAuthorisation(
        id: id,
        generation: c.generation,
        ticket: edited.ticket,
      );
      await rust.deleteHosts(ids: [keyHost.id]);
      expect((await state(c)).phase, 'Revoked');
      expect(c.connected, true);
      expect(
        (await rust.agentKeyOptions()).any((k) => k.hostId == keyHost.id),
        false,
      );
    } finally {
      await model.shutdown();
      model.dispose();
      await second.close();
      await first.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('Native default-off cannot be promoted by revoke; saved opt-in applies only on explicit reconnect and server denial preserves shell', () async {
    final server = await LocalSshd.start(agentForwarding: false);
    final model = LiveWorkbenchModel();
    try {
      await rust.unlockVault(
        path: '${server.directory.path}/disabled.vault',
        password: 'synthetic-agent-master',
      );
      await model.load();
      final host = await save(model, server, 'Disabled Agent fixture');
      final c = await connected(model, host);
      expect((await state(c)).phase, 'NotRequested');
      await rust.revokeTerminalAgent(id: c.id!, generation: c.generation);
      expect((await state(c)).phase, 'NotRequested');
      await expectLater(
        rust.prepareAgentAuthorisation(
          id: c.id!,
          generation: c.generation,
          hostIds: [host.id],
          seconds: 60,
        ),
        throwsA(anything),
      );
      await model.persistHost(host.snapshot()..agentForwarding = true);
      expect((await state(c)).phase, 'NotRequested');
      await reconnect(c);
      expect((await state(c)).phase, 'Denied');
      await command(c, "printf '%s%s\\n' AGENT_DENIED_ SHELL_OK");
      await waitFor(
        () => screen(c).contains('AGENT_DENIED_SHELL_OK'),
        'denied Agent does not break ordinary shell',
      );
    } finally {
      await model.shutdown();
      model.dispose();
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
