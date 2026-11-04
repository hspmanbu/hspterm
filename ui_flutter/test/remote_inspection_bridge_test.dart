import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/remote_inspection.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('real hidden SSH requires original-generation inspection consent and rejects arbitrary process signals without PTY frames', () async {
    final ssh = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      await rust.createConfigurationVault(
        path: '${ssh.directory.path}/inspection.vault',
        password: 'synthetic-inspection-master',
      );
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Inspection fixture',
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
      final session = model.focus! as LiveTerminalSession;
      final c = session.controller;
      await waitFor(
        () => c.connected || c.phase == 'Failed',
        'inspection fixture SSH',
      );
      expect(c.connected, true, reason: c.error);
      final id = c.id!, generation = c.generation, frames = c.frameCount;
      await expectLater(
        rust.sampleRemoteResources(id: id, generation: generation),
        throwsA(anything),
      );
      await rust.configureRemoteInspection(
        id: id,
        generation: generation,
        metrics: true,
        processes: false,
      );
      final sample = RemoteResourceSample.parse(
        await rust.sampleRemoteResources(id: id, generation: generation),
      );
      expect(sample.memoryTotal, greaterThan(0));
      await expectLater(
        rust.listRemoteProcesses(id: id, generation: generation),
        throwsA(anything),
      );
      await rust.configureRemoteInspection(
        id: id,
        generation: generation,
        metrics: true,
        processes: true,
      );
      final list = RemoteProcessList.parse(
        await rust.listRemoteProcesses(id: id, generation: generation),
      );
      expect(list.processes.length, lessThanOrEqualTo(512));
      await expectLater(
        rust.terminateRemoteProcess(
          id: id,
          generation: generation,
          revision: list.revision,
          pid: 1,
          confirmed: true,
        ),
        throwsA(anything),
      );
      await expectLater(
        rust.terminateRemoteProcess(
          id: id,
          generation: generation,
          revision: list.revision,
          pid: 123,
          confirmed: false,
        ),
        throwsA(anything),
      );
      await expectLater(
        rust.sampleRemoteResources(id: id, generation: generation + 1),
        throwsA(anything),
      );
      await rust.configureRemoteInspection(
        id: id,
        generation: generation,
        metrics: false,
        processes: false,
      );
      await expectLater(
        rust.sampleRemoteResources(id: id, generation: generation),
        throwsA(anything),
      );
      expect(c.frameCount, frames);
      expect(c.connected, true);
      expect(c.generation, generation);
    } finally {
      await model.shutdown();
      model.dispose();
      await ssh.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
