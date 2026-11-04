import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/forwardings.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test(
    'real draft FRB preserves incomplete fields across unlock, validates commit and rejects stale writers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hspterm-forwarding-draft-',
      );
      final model = LiveWorkbenchModel();
      try {
        final path = '${directory.path}/draft.vault';
        await rust.unlockVault(path: path, password: 'synthetic-master');
        await model.load();
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'Draft fixture',
            'fixture.invalid',
            '未分组',
            user: 'synthetic',
            auth: '密码',
            openSftp: false,
          ),
          secret: 'synthetic-password',
        );
        DraftFields fields(String port) => DraftFields(
          name: 'private incomplete name',
          kind: 'local',
          bindAddress: '127.0.0.1',
          bindPort: '0',
          targetAddress: 'target.invalid',
          targetPort: port,
          enabled: true,
          restoreOnReconnect: false,
        );
        final initial = await rust.forwardingRuleDraft(hostId: host.id);
        expect(initial.fields, isNull);
        final saved = await rust.saveForwardingRuleDraft(
          hostId: host.id,
          expectedRevision: initial.revision,
          fields: fields('incomplete'),
        );
        expect(await rust.forwardingRules(hostId: host.id), isEmpty);
        await expectLater(
          rust.commitForwardingRuleDraft(
            hostId: host.id,
            expectedRevision: saved.revision,
          ),
          throwsA(anything),
        );
        await rust.unlockVault(path: path, password: 'synthetic-master');
        expect(
          (await rust.forwardingRuleDraft(hostId: host.id)).fields!.targetPort,
          'incomplete',
        );
        await expectLater(
          rust.saveForwardingRuleDraft(
            hostId: host.id,
            expectedRevision: initial.revision,
            fields: null,
          ),
          throwsA(anything),
        );
        final valid = await rust.saveForwardingRuleDraft(
          hostId: host.id,
          expectedRevision: saved.revision,
          fields: fields('443'),
        );
        final rules = await rust.commitForwardingRuleDraft(
          hostId: host.id,
          expectedRevision: valid.revision,
        );
        expect(rules, hasLength(1));
        expect(rules.single.targetPort, 443);
        final retired = await rust.forwardingRuleDraft(hostId: host.id);
        expect(retired.fields, isNull);
        expect(retired.revision, greaterThan(valid.revision));
        await expectLater(
          rust.saveForwardingRuleDraft(
            hostId: host.id,
            expectedRevision: valid.revision,
            fields: fields('80'),
          ),
          throwsA(anything),
        );
        final bytes = await File(path).readAsBytes();
        expect(
          String.fromCharCodes(bytes),
          isNot(contains('private incomplete name')),
        );
        expect(
          String.fromCharCodes(bytes),
          isNot(contains('synthetic-password')),
        );
        await rust.deleteHosts(ids: [host.id]);
        await expectLater(
          rust.forwardingRuleDraft(hostId: host.id),
          throwsA(anything),
        );
      } finally {
        await model.shutdown();
        model.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
