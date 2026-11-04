import '../prototype/model.dart';
import 'directory_reader.dart';

/// Session-local metadata only. The active, complete directory is never
/// truncated to fit the budget; older snapshots yield to it in LRU order.
class DirectoryCache {
  DirectoryCache(
    this.files, {
    this.maxDirectories = 16,
    this.maxEstimatedBytes = 64 * 1024 * 1024,
  }) : assert(maxDirectories > 0),
       assert(maxEstimatedBytes > 0);

  final Map<String, List<DemoFile>> files;
  final int maxDirectories, maxEstimatedBytes;
  final _weights = <String, int>{};
  int get estimatedBytes => _estimatedBytes;
  int _estimatedBytes = 0;

  void store(LoadedDirectory directory) {
    remove(directory.path);
    files[directory.path] = directory.files;
    _weights[directory.path] = directory.estimatedBytes;
    _estimatedBytes += directory.estimatedBytes;
    while (files.length > 1 &&
        (files.length > maxDirectories ||
            _estimatedBytes > maxEstimatedBytes)) {
      remove(files.keys.first);
    }
  }

  void remove(String path) {
    files.remove(path);
    _estimatedBytes -= _weights.remove(path) ?? 0;
  }

  void clear() {
    files.clear();
    _weights.clear();
    _estimatedBytes = 0;
  }
}
