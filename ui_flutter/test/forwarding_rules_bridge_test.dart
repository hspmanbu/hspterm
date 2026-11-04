import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/forwardings.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

RuleConfig rule({
  String id = '',
  String kind = 'local',
  String bind = '127.0.0.1',
  int port = 0,
  String? target = 'target.invalid',
  int? targetPort = 443,
}) => RuleConfig(
  id: id,
  name: 'private-forward-label-bridge',
  kind: kind,
  bindAddress: bind,
  bindPort: port,
  targetAddress: target,
  targetPort: targetPort,
  enabled: true,
  restoreOnReconnect: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test(
    'real FRB encrypted forwarding config is independent of listeners, credentials and host drafts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hspterm-forward-rules-',
      );
      final endpoint = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var connections = 0;
      final requests = endpoint.listen((socket) {
        connections++;
        socket.destroy();
      });
      final model = LiveWorkbenchModel();
      final path = '${directory.path}/rules.vault';
      const master = 'synthetic-forward-config-master';
      try {
        await rust.unlockVault(path: path, password: master);
        await model.load();
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'Config only',
            '127.0.0.1',
            '未分组',
            port: endpoint.port,
            user: 'synthetic-user',
            auth: '密码',
          ),
          secret: 'synthetic-password-only',
        );
        expect(await rust.forwardingRules(hostId: host.id), isEmpty);
        final values = await rust.saveForwardingRules(
          hostId: host.id,
          rules: [
            rule(),
            rule(kind: 'remote', bind: '::1'),
            rule(kind: 'dynamic', target: null, targetPort: null),
          ],
        );
        expect(values, hasLength(3));
        expect(values.map((v) => v.id).toSet(), hasLength(3));
        expect(values.every((v) => v.id.startsWith('forward-')), isTrue);
        expect(await rust.forwardingRules(hostId: host.id), values);
        final preserved = values.first.id;
        for (final invalid in [
          rule(kind: 'unrecognized'),
          rule(bind: 'localhost'),
          rule(port: 65536),
          rule(targetPort: 65536),
          rule(targetPort: 0),
          rule(target: 'bad\r\n.invalid'),
          rule(target: null),
          rule(kind: 'dynamic'),
          rule(id: 'forward-not-a-stable-id'),
        ]) {
          await expectLater(
            rust.saveForwardingRules(hostId: host.id, rules: [invalid]),
            throwsA(anything),
          );
          expect(await rust.forwardingRules(hostId: host.id), values);
        }
        await expectLater(
          rust.saveForwardingRules(
            hostId: host.id,
            rules: [values.first, values.first],
          ),
          throwsA(anything),
        );
        await expectLater(
          rust.saveForwardingRules(
            hostId: host.id,
            rules: List.generate(33, (_) => rule()),
          ),
          throwsA(anything),
        );
        expect(
          (await rust.forwardingRules(hostId: host.id)).first.id,
          preserved,
        );
        await model.persistDraft(host);
        await model.discardDraft(host.id);
        expect(await rust.forwardingRules(hostId: host.id), values);
        final copy = await rust.copyHostToDraft(id: host.id);
        await expectLater(
          rust.forwardingRules(hostId: copy.id),
          throwsA(anything),
          reason: 'a copied draft is not a saved host',
        );
        await rust.unlockVault(path: path, password: master);
        expect((await rust.hostDrafts()).single.id, copy.id);
        final savedCopy = await rust.saveHost(host: copy);
        final copied = await rust.forwardingRules(hostId: savedCopy.id);
        expect(
          copied
              .map((v) => v.id)
              .toSet()
              .intersection(values.map((v) => v.id).toSet()),
          isEmpty,
        );
        expect(
          copied.map((v) => v.kind).toList(),
          values.map((v) => v.kind).toList(),
        );
        await model.load();
        final original = model.hosts.singleWhere((h) => h.id == host.id);
        original.name = 'Renamed saved host';
        await model.persistHost(original);
        expect(
          await rust.forwardingRules(hostId: host.id),
          values,
          reason:
              'ordinary host edits must not erase independent forwarding rules',
        );
        await rust.deleteHosts(ids: [host.id]);
        expect(await rust.forwardingRules(hostId: savedCopy.id), copied);
        await expectLater(
          rust.forwardingRules(hostId: host.id),
          throwsA(anything),
        );
        await expectLater(
          rust.saveForwardingRules(hostId: host.id, rules: values),
          throwsA(anything),
        );
        await rust.saveForwardingRules(hostId: savedCopy.id, rules: []);
        expect(await rust.forwardingRules(hostId: savedCopy.id), isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          connections,
          0,
          reason: 'configuration operations must not probe or connect to the saved SSH endpoint',
        );
        expect(model.sessions, isEmpty);
        final bytes = await File(path).readAsBytes();
        final onDisk = latin1.decode(bytes);
        expect(onDisk, isNot(contains('private-forward-label-bridge')));
        expect(onDisk, isNot(contains('synthetic-password-only')));
      } finally {
        await model.shutdown();
        await requests.cancel();
        await endpoint.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
