import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';

class SubmissionModel extends WorkbenchModel {
  final accepted = <(TerminalSession, String, String, bool, int?)>[];
  final gate = Completer<void>();
  @override
  Future<String> enqueueFileTransfer(
    TerminalSession source,
    String local,
    String remote,
    bool upload, {
    int? expectedGeneration,
  }) async {
    accepted.add((source, local, remote, upload, expectedGeneration));
    if (accepted.length == 1) await gate.future;
    return 'synthetic-${accepted.length}';
  }
}

void main() {
  test('batch freezes selection and destination independently of later focus and navigation', () async {
    final model = SubmissionModel()..demo();
    final source = model.focus!..disconnected = false;
    final requests = [
      const LocalTransferRequest('/local/a', '/original/a'),
      const LocalTransferRequest('/local/b', '/original/b'),
    ];
    final pending = model.submitFileTransfers(
      source,
      requests,
      generation: source.connectionGeneration,
      upload: true,
    );
    requests.clear();
    source.navigate('/later');
    model.selectTab(model.tabs.first.id);
    model.gate.complete();
    expect(await pending, ['synthetic-1', 'synthetic-2']);
    expect(model.accepted.map((r) => r.$3), ['/original/a', '/original/b']);
    expect(model.accepted.map((r) => r.$1), everyElement(same(source)));
    model.dispose();
  });
  test('reconnect stops remaining downloads and reports only confirmed acceptance without names', () async {
    final model = SubmissionModel()..demo();
    final source = model.focus!..disconnected = false;
    final pending = model.submitFileTransfers(
      source,
      const [
        LocalTransferRequest('/local/a', '/private/a'),
        LocalTransferRequest('/local/b', '/private/b'),
      ],
      generation: source.connectionGeneration,
      upload: false,
    );
    final check = expectLater(
      pending,
      throwsA(
        isA<LocalTransferSubmissionFailure>()
            .having((e) => e.accepted, 'confirmed', 1)
            .having(
              (e) => e.toString(),
              'redacted direction',
              allOf(contains('下载'), isNot(contains('/private'))),
            ),
      ),
    );
    source.connectionGeneration++;
    model.gate.complete();
    await check;
    expect(model.accepted, hasLength(1));
    model.dispose();
  });
  test('invalid batch member rejects the entire selection before any file is queued', () async {
    final model = SubmissionModel()..demo();
    final source = model.focus!..disconnected = false;
    await expectLater(
      model.submitFileTransfers(
        source,
        const [
          LocalTransferRequest('/valid', '/valid'),
          LocalTransferRequest('/second', 'relative'),
        ],
        generation: source.connectionGeneration,
        upload: true,
      ),
      throwsStateError,
    );
    expect(model.accepted, isEmpty);
    model.dispose();
  });
}
