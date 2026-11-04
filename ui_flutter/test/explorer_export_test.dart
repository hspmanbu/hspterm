import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/explorer_export.dart';

class RecordingSink implements EventSink {
  final chunks = <List<int>>[];
  final errors = <Object>[];
  bool closed = false;
  void Function()? onChunk;
  @override
  void add(Object? event) {
    chunks.add(List<int>.of(event as List<int>));
    onChunk?.call();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    errors.add(error);
  }

  @override
  void close() {
    if (closed) throw StateError('double close');
    closed = true;
  }
}

void main() {
  test(
    'native content requests use bounded FIFO before reserving source work',
    () async {
      final gate = ExplorerExportAdmission(parallel: 2);
      final started = <int>[],
          barriers = List.generate(6, (_) => Completer<void>());
      final work = [
        for (var i = 0; i < barriers.length; i++)
          gate.run(ExplorerExportCancellation(), () async {
            started.add(i);
            await barriers[i].future;
            return i;
          }),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1]);
      barriers[1].complete();
      await work[1];
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1, 2]);
      for (var i = 0; i < barriers.length; i++) {
        if (!barriers[i].isCompleted) barriers[i].complete();
      }
      expect(await Future.wait(work), [0, 1, 2, 3, 4, 5]);
      expect(started, [0, 1, 2, 3, 4, 5]);
    },
  );
  test('queued cancellation never starts a source, active cancellation retains its slot until actual completion', () async {
    final gate = ExplorerExportAdmission(parallel: 1);
    final actualEnd = Completer<void>();
    final activeCancel = ExplorerExportCancellation();
    var secondStarted = false, thirdStarted = false;
    final first = gate.run(activeCancel, () => actualEnd.future);
    final queuedCancel = ExplorerExportCancellation();
    final second = gate.run(queuedCancel, () async {
      secondStarted = true;
    });
    final rejected = expectLater(
      second,
      throwsA(isA<ExplorerExportCancelled>()),
    );
    final third = gate.run(ExplorerExportCancellation(), () async {
      thirdStarted = true;
    });
    await Future<void>.delayed(Duration.zero);
    queuedCancel.cancel();
    activeCancel.cancel();
    await rejected;
    await Future<void>.delayed(Duration.zero);
    expect(secondStarted, false);
    expect(thirdStarted, false);
    actualEnd.complete();
    await first;
    await third;
    expect(thirdStarted, true);
    expect(secondStarted, false);
  });
  test(
    'capacity rejection and failed workers do not strand an export permit',
    () async {
      final gate = ExplorerExportAdmission(parallel: 1, capacity: 1);
      final actualEnd = Completer<void>();
      final first = gate.run(
        ExplorerExportCancellation(),
        () => actualEnd.future,
      );
      await expectLater(
        gate.run(ExplorerExportCancellation(), () async {}),
        throwsStateError,
      );
      actualEnd.complete();
      await first;
      await expectLater(
        gate.run(ExplorerExportCancellation(), () async {
          throw StateError('fixture');
        }),
        throwsStateError,
      );
      expect(
        await gate.run(ExplorerExportCancellation(), () async => 'usable'),
        'usable',
      );
    },
  );
  test('cancelled streaming still reports failed cleanup and waits before admitting the next source', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hspterm-export-retire-',
    );
    try {
      final source = await File('${directory.path}/source')
          .writeAsBytes([1, 2, 3]);
      final gate = ExplorerExportAdmission(parallel: 1);
      final cancellation = ExplorerExportCancellation();
      final actualCleanup = Completer<void>();
      cancellation.attach(() => actualCleanup.future);
      final consumed = Completer<void>();
      final sink = RecordingSink()
        ..onChunk = () {
          cancellation.cancel();
          consumed.complete();
        };
      var released = false, nextStarted = false;
      final work = gate.run(
        cancellation,
        () => streamExplorerSnapshot(
          (_) async => ExplorerExportSnapshot(source.path, 3, () async {
            released = true;
          }),
          cancellation,
          (_) => sink,
        ),
      );
      final failure = expectLater(
        work,
        throwsA(
          predicate((e) => e is StateError && e is! ExplorerExportCancelled),
        ),
      );
      final next = gate.run(ExplorerExportCancellation(), () async {
        nextStarted = true;
      });
      await consumed.future;
      expect(nextStarted, false);
      expect(released, false);
      actualCleanup.completeError(
        StateError('fixture cleanup remains unconfirmed'),
      );
      await failure;
      await next;
      expect(released, true);
      expect(nextStarted, true);
      expect(
        sink.closed,
        false,
      ); // Only the native caller owns its EOF protocol.
      expect(await source.readAsBytes(), [1, 2, 3]);
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('Windows export names preserve Unicode and quoting, reject traversal, aliases and devices', () {
    for (final name in [
      '中文😀.bin',
      "a'b.txt",
      'report (1).json',
      'COM10.log',
    ]) {
      validateExplorerExportName(name);
    }
    for (final name in [
      '',
      '.',
      '..',
      '../file',
      'a\\file',
      'a:b',
      'file.',
      'file ',
      'nul.txt',
      'CON .txt',
      'LPT¹',
      'COM1',
      'CONIN\$',
      'CONOUT\$.log',
      'conın\$',
      'a\nfile',
      'x\x00',
      String.fromCharCode(0xd800),
      List.filled(128, '😀').join(),
    ]) {
      expect(
        () => validateExplorerExportName(name),
        throwsStateError,
        reason: name,
      );
    }
  });
  test('a complete snapshot is streamed in chunks, released before caller signals close', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hspterm-export-test-',
    );
    try {
      final bytes = List.generate(300000, (i) => i % 251);
      final file = await File('${directory.path}/source').writeAsBytes(bytes);
      var released = false;
      final sink = RecordingSink();
      await streamExplorerSnapshot(
        (_) async => ExplorerExportSnapshot(file.path, bytes.length, () async {
          expect(sink.closed, false);
          released = true;
        }),
        ExplorerExportCancellation(),
        (length) {
          expect(length, bytes.length);
          return sink;
        },
      );
      expect(sink.chunks.expand((c) => c).toList(), bytes);
      expect(sink.chunks.every((c) => c.length <= 65536), true);
      expect(sink.errors, isEmpty);
      expect(released, true);
      expect(sink.closed, false);
      sink.close();
      expect(await file.readAsBytes(), bytes);
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('cancellation awaits the actual source stop and does not signal successful EOF', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hspterm-export-cancel-',
    );
    try {
      final file = await File('${directory.path}/source')
          .writeAsBytes(List.filled(200000, 7));
      final cancel = ExplorerExportCancellation(), sink = RecordingSink();
      final stopped = Completer<void>();
      var released = false;
      sink.onChunk = cancel.cancel;
      cancel.attach(() => stopped.future);
      final work = streamExplorerSnapshot(
        (_) async => ExplorerExportSnapshot(file.path, 200000, () async {
          released = true;
        }),
        cancel,
        (_) => sink,
      );
      final failure = expectLater(work, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(released, false);
      expect(sink.closed, false);
      stopped.complete();
      await failure;
      expect(released, true);
      expect(sink.closed, false);
      expect(await file.length(), 200000);
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('an invalid snapshot is never published, and cleanup failure remains failure', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hspterm-export-invalid-',
    );
    try {
      final file = await File('${directory.path}/source').writeAsString('test');
      var created = false, released = false;
      await expectLater(
        streamExplorerSnapshot(
          (_) async => ExplorerExportSnapshot(file.path, 5, () async {
            released = true;
          }),
          ExplorerExportCancellation(),
          (_) {
            created = true;
            return RecordingSink();
          },
        ),
        throwsStateError,
      );
      expect(created, false);
      expect(released, true);
      final sink = RecordingSink();
      await expectLater(
        streamExplorerSnapshot(
          (_) async => ExplorerExportSnapshot(file.path, 4, () async {
            throw StateError('controlled cleanup failure');
          }),
          ExplorerExportCancellation(),
          (_) => sink,
        ),
        throwsStateError,
      );
      expect(sink.closed, false);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
