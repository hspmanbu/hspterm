import '../prototype/model.dart';
import 'directory_reader.dart';

/// Workbench-wide budget for reusable directory metadata. Each session's
/// current complete listing is pinned; the bound is deliberately soft when
/// those required listings alone exceed it. No session/connection is closed.
class DirectoryCacheBudget {
  DirectoryCacheBudget({this.maxEstimatedBytes = 64 * 1024 * 1024})
    : assert(maxEstimatedBytes > 0);

  final int maxEstimatedBytes;
  final _entries = <(DirectoryCache, String), int>{};
  int _estimatedBytes = 0;
  int get estimatedBytes => _estimatedBytes;
  int get directories => _entries.length;

  void _remove(DirectoryCache cache, String path) {
    _estimatedBytes -= _entries.remove((cache, path)) ?? 0;
  }

  void _touch(DirectoryCache cache, String path, int weight) {
    _remove(cache, path);
    _entries[(cache, path)] = weight;
    _estimatedBytes += weight;
    while (_estimatedBytes > maxEstimatedBytes) {
      final candidate = _entries.keys
          .where((key) => key.$1._currentPath != key.$2)
          .firstOrNull;
      if (candidate == null) break;
      candidate.$1.remove(candidate.$2);
    }
  }
}

/// Session-local metadata only. The active, complete directory is never
/// truncated to fit the budget; older snapshots yield to it in LRU order.
class DirectoryCache {
  DirectoryCache(
    this.files, {
    this.maxDirectories = 16,
    this.maxEstimatedBytes = 64 * 1024 * 1024,
    this.sharedBudget,
  }) : assert(maxDirectories > 0),
       assert(maxEstimatedBytes > 0);

  final Map<String, List<DemoFile>> files;
  final int maxDirectories, maxEstimatedBytes;
  final DirectoryCacheBudget? sharedBudget;
  String? _currentPath;
  final _weights = <String, int>{};
  int get estimatedBytes => _estimatedBytes;
  int _estimatedBytes = 0;

  void store(LoadedDirectory directory) {
    remove(directory.path);
    files[directory.path] = directory.files;
    _currentPath = directory.path;
    _weights[directory.path] = directory.estimatedBytes;
    _estimatedBytes += directory.estimatedBytes;
    while (files.length > 1 &&
        (files.length > maxDirectories ||
            _estimatedBytes > maxEstimatedBytes)) {
      remove(files.keys.first);
    }
    sharedBudget?._touch(this, directory.path, directory.estimatedBytes);
  }

  /// Cache-hit navigation changes which listing is protected and touches the
  /// actual LRU, without copying file rows or making a network request.
  bool activate(String path) {
    final rows = files.remove(path);
    if (rows == null) return false;
    files[path] = rows;
    _currentPath = path;
    sharedBudget?._touch(this, path, _weights[path] ?? 0);
    return true;
  }

  void remove(String path) {
    sharedBudget?._remove(this, path);
    if (_currentPath == path) _currentPath = null;
    files.remove(path);
    _estimatedBytes -= _weights.remove(path) ?? 0;
  }

  void clear() {
    for (final path in _weights.keys) {
      sharedBudget?._remove(this, path);
    }
    _currentPath = null;
    files.clear();
    _weights.clear();
    _estimatedBytes = 0;
  }
}
