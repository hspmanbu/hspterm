import 'dart:async';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust;

abstract interface class FileSearchBackend {
  Future<String> open(
    int id,
    int generation,
    int request,
    String path,
    String query,
    bool caseSensitive,
  );
  Future<rust.RemoteFileSearchPage> page(int id, int generation, int request);
  Future<void> close(int id, int generation, int request);
}

class NativeFileSearchBackend implements FileSearchBackend {
  const NativeFileSearchBackend();
  @override
  Future<String> open(
    int id,
    int generation,
    int request,
    String path,
    String query,
    bool caseSensitive,
  ) => rust.sftpOpenFileSearch(
    id: id,
    generation: generation,
    request: request,
    path: path,
    query: query,
    caseSensitive: caseSensitive,
  );
  @override
  Future<rust.RemoteFileSearchPage> page(int id, int generation, int request) =>
      rust.sftpFileSearchPage(
        id: id,
        generation: generation,
        request: request,
        limit: 256,
      );
  @override
  Future<void> close(int id, int generation, int request) => rust
      .sftpCloseFileSearch(id: id, generation: generation, request: request);
}

/// Owns one captured SSH identity, never reconnects or follows tab focus.
class FileSearchController extends ChangeNotifier {
  FileSearchController({
    required this.id,
    required this.generation,
    required this.path,
    required this.isCurrent,
    this.backend = const NativeFileSearchBackend(),
  }) : root = path;
  final int id, generation;
  final String path;
  final bool Function() isCurrent;
  final FileSearchBackend backend;
  static int _nextRequest = 0;
  static const maxResults = 10000;
  final results = <rust.RemoteFile>[];
  String root;
  String? error;
  Object? _cleanupError;
  int scanned = 0, directories = 0;
  bool running = false,
      done = false,
      _cancelled = false,
      _disposed = false,
      _closing = false;
  int? _request;
  Future<void>? _work;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start(String query, {bool caseSensitive = false}) {
    if (_closing || _disposed) return Future.value();
    if (_work != null) return _work!;
    if (query.isEmpty) {
      error = '请输入需要查找的文件名片段';
      _emit();
      return Future.value();
    }
    if (_nextRequest == 0x7fffffffffffffff) {
      error = '搜索序号达到上限，请重新启动应用';
      _emit();
      return Future.value();
    }
    final request = ++_nextRequest;
    _request = request;
    _cancelled = false;
    running = true;
    done = false;
    error = null;
    _cleanupError = null;
    scanned = 0;
    directories = 0;
    results.clear();
    _emit();
    return _work = _run(
      request,
      query,
      caseSensitive,
    ).whenComplete(() => _work = null);
  }

  void _checkSource() {
    if (!isCurrent()) throw StateError('原SSH会话已断开、关闭或改变；结果未用于其他会话');
  }

  Future<void> _run(int request, String query, bool caseSensitive) async {
    var attempted = false;
    try {
      if (_cancelled || _closing) return;
      _checkSource();
      attempted = true;
      final canonical = await backend.open(
        id,
        generation,
        request,
        path,
        query,
        caseSensitive,
      );
      if (_cancelled || _closing) return;
      _checkSource();
      root = canonical;
      while (!_cancelled && !_closing) {
        final page = await backend.page(id, generation, request);
        if (_cancelled || _closing) break;
        _checkSource();
        final available = maxResults - results.length;
        results.addAll(page.files.take(available));
        scanned = page.scanned;
        directories = page.directories;
        if (page.files.length > available ||
            (results.length == maxResults && !page.done)) {
          error = '结果已达到 $maxResults 项；尚未搜索完整，请缩小目录或文件名范围';
          break;
        }
        done = page.done;
        _emit();
        if (done) break;
        await Future<void>.delayed(Duration.zero);
      }
    } catch (e) {
      if (!_cancelled && !_closing) error = '搜索未完成：$e';
    } finally {
      if (attempted) {
        try {
          await backend.close(id, generation, request);
        } catch (e) {
          _cleanupError = e;
          error = '${error ?? '搜索结果已保留'}；释放搜索通道失败：$e';
        }
      }
      if (_request == request) {
        _request = null;
        running = false;
      }
      _emit();
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    final request = _request;
    if (request != null) {
      try {
        await backend.close(id, generation, request);
      } catch (e) {
        _cleanupError = e;
        error = '取消搜索时释放通道失败：$e';
      }
    }
    await _work;
  }

  Future<void> close() async {
    _closing = true;
    await cancel();
    if (_cleanupError != null) throw StateError('搜索通道关闭未确认：$_cleanupError');
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
