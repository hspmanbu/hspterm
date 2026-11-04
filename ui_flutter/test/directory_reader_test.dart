import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/workbench/directory_reader.dart';
import 'package:hspterm/workbench/file_size.dart';

rust.RemoteFile item(String name) => rust.RemoteFile(
  name: name,
  path: '/canonical/$name',
  directory: false,
  symlink: false,
  size: 2,
  modified: 1,
  permissions: 33152,
);
void main() {
  test('display units scale without changing metadata byte counts', () {
    expect(remoteFileSize(null), '—');
    expect(remoteFileSize(0), '0.00 KB');
    expect(remoteFileSize(512), '0.50 KB');
    expect(remoteFileSize(1024), '1.00 KB');
    expect(remoteFileSize(1024 * 1024), '1.00 MB');
    expect(remoteFileSize(1024 * 1024 * 1024), '1.00 GB');
  });
  test(
    'paged collection preserves metadata and waits for successful close',
    () async {
      var reads = 0, closes = 0;
      final closeGate = Completer<void>();
      final reader = PagedDirectoryReader(
        open: ({
          required id,
          required generation,
          required request,
          required path,
        }) async => '/canonical',
        page:
            ({
              required id,
              required generation,
              required request,
              required limit,
            }) async {
              expect(limit, 256);
              reads++;
              return rust.RemoteDirectoryPage(
                files: [item(reads == 1 ? '中文 é' : 'next')],
                done: reads == 2,
              );
            },
        close: ({required id, required generation, required request}) async {
          closes++;
          await closeGate.future;
        },
      );
      var published = false;
      final future = reader
          .read(
            id: 1,
            generation: 7,
            request: 9,
            path: '.',
            isCurrent: () => true,
          )
          .then((value) {
            published = true;
            return value;
          });
      await Future<void>.delayed(Duration.zero);
      expect(reads, 2);
      expect(closes, 1);
      expect(published, false);
      closeGate.complete();
      final result = (await future)!;
      expect(result.path, '/canonical');
      expect(result.files.map((f) => f.name), ['中文 é', 'next']);
      expect(result.files.first.byteSize, 2);
      expect(
        result.estimatedBytes,
        256 +
            2 * result.path.length +
            result.files.fold<int>(
              0,
              (sum, f) =>
                  sum +
                  256 +
                  2 *
                      (f.id.length +
                          f.name.length +
                          f.size.length +
                          f.kind.length +
                          f.modified.length),
            ),
        reason: 'weight includes complete names, paths and display strings',
      );
    },
  );
  test(
    'late page failure and cleanup failure never publish partial files',
    () async {
      for (final closeFails in [false, true]) {
        var reads = 0, closes = 0;
        final reader = PagedDirectoryReader(
          open: ({
            required id,
            required generation,
            required request,
            required path,
          }) async => '/canonical',
          page:
              ({
                required id,
                required generation,
                required request,
                required limit,
              }) async {
                if (++reads == 2) {
                  throw StateError('controlled late page failure');
                }
                return rust.RemoteDirectoryPage(
                  files: [item('partial')],
                  done: false,
                );
              },
          close: ({required id, required generation, required request}) async {
            closes++;
            if (closeFails) throw StateError('controlled close failure');
          },
        );
        await expectLater(
          reader.read(
            id: 1,
            generation: 7,
            request: 9,
            path: '.',
            isCurrent: () => true,
          ),
          throwsA(
            predicate(
              (e) =>
                  e.toString().contains('late page failure') &&
                  (!closeFails || e.toString().contains('close failure')),
            ),
          ),
        );
        expect(closes, 1);
      }
      final reader = PagedDirectoryReader(
        open: ({
          required id,
          required generation,
          required request,
          required path,
        }) async => '/canonical',
        page:
            ({
              required id,
              required generation,
              required request,
              required limit,
            }) async =>
                rust.RemoteDirectoryPage(files: [item('complete')], done: true),
        close: ({required id, required generation, required request}) async =>
            throw StateError('controlled close failure'),
      );
      await expectLater(
        reader.read(
          id: 1,
          generation: 7,
          request: 9,
          path: '.',
          isCurrent: () => true,
        ),
        throwsStateError,
      );
    },
  );
  test('superseded response returns no listing and cleanup retains its original identity', () async {
    var current = true;
    final page = Completer<rust.RemoteDirectoryPage>();
    final started = Completer<void>();
    final closed = <String>[];
    final reader = PagedDirectoryReader(
      open: ({
        required id,
        required generation,
        required request,
        required path,
      }) async => '/canonical',
      page:
          ({
            required id,
            required generation,
            required request,
            required limit,
          }) {
            started.complete();
            return page.future;
          },
      close: ({required id, required generation, required request}) async {
        closed.add('$id/$generation/$request');
      },
    );
    final future = reader.read(
      id: 1,
      generation: 7,
      request: 9,
      path: '.',
      isCurrent: () => current,
    );
    await started.future;
    current = false;
    page.complete(
      rust.RemoteDirectoryPage(files: [item('obsolete')], done: true),
    );
    expect(await future, isNull);
    expect(closed, ['1/7/9']);
  });
}
