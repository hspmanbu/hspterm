import '../prototype/model.dart';
import '../src/rust/api.dart' as rust;
import 'file_size.dart';

typedef OpenDirectory = Future<String> Function({
  required int id,
  required int generation,
  required int request,
  required String path,
});
typedef ReadDirectoryPage = Future<rust.RemoteDirectoryPage> Function({
  required int id,
  required int generation,
  required int request,
  required int limit,
});
typedef CloseDirectory = Future<void> Function({
  required int id,
  required int generation,
  required int request,
});

class LoadedDirectory {
  LoadedDirectory(this.path, this.files, this.estimatedBytes);
  final String path;
  final List<DemoFile> files;

  /// Conservative cache weight, not a measurement of Dart heap or process RSS.
  /// Count string storage without assuming Latin-1 compression or deduplication.
  final int estimatedBytes;
}

/// Bounded bridge batches, converted as they arrive. Publish only a complete,
/// successfully closed listing; superseded requests cannot replace the cache.
class PagedDirectoryReader {
  const PagedDirectoryReader({
    this.open = rust.sftpOpenDirectory,
    this.page = rust.sftpDirectoryPage,
    this.close = rust.sftpCloseDirectory,
  });
  final OpenDirectory open;
  final ReadDirectoryPage page;
  final CloseDirectory close;

  Future<LoadedDirectory?> read({
    required int id,
    required int generation,
    required int request,
    required String path,
    required bool Function() isCurrent,
  }) async {
    Object? problem;
    StackTrace? trace;
    LoadedDirectory? result;
    try {
      final canonical = await open(
        id: id,
        generation: generation,
        request: request,
        path: path,
      );
      final files = <DemoFile>[];
      var weight = 256 + 2 * canonical.length;
      var done = false;
      while (!done && isCurrent()) {
        final batch = await page(
          id: id,
          generation: generation,
          request: request,
          limit: 256,
        );
        if (!isCurrent()) break;
        for (final f in batch.files) {
          final file = DemoFile(
            f.path,
            f.name,
            folder: f.directory,
            symlink: f.symlink,
            byteSize: f.size,
            modifiedEpoch: f.modified,
            size: f.directory ? '—' : remoteFileSize(f.size),
            kind: f.symlink
                ? '符号链接'
                : f.directory
                ? '文件夹'
                : '文件',
            modified: f.modified == null
                ? '—'
                : DateTime.fromMillisecondsSinceEpoch(f.modified! * 1000)
                      .toLocal()
                      .toString()
                      .substring(0, 16),
          );
          files.add(file);
          weight +=
              256 +
              2 *
                  (file.id.length +
                      file.name.length +
                      file.size.length +
                      file.kind.length +
                      file.modified.length);
        }
        done = batch.done;
      }
      if (done && isCurrent()) {
        result = LoadedDirectory(canonical, files, weight);
      }
    } catch (error, stack) {
      problem = error;
      trace = stack;
    }
    try {
      // Always scope cleanup to the original request/generation. An old finally
      // block must never close a newer directory reader on the same terminal.
      await close(id: id, generation: generation, request: request);
    } catch (error, stack) {
      Error.throwWithStackTrace(
        problem == null ? error : StateError('$problem；释放目录游标也失败：$error'),
        stack,
      );
    }
    if (!isCurrent()) return null;
    if (problem != null) Error.throwWithStackTrace(problem, trace!);
    return result;
  }
}
