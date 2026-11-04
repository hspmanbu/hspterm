import 'dart:async';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/editors.dart';
import '../terminal/controller.dart';
import 'external_editor.dart';

abstract interface class EditorBackend {
  int begin(String token);
  EditorProgress? progress(String token, int operation);
  Future<EditorDocument> prepare(
    String token,
    int operation, {
    String? inputEncoding,
  });
  Future<EditorSummary> update(
    String token,
    int revision,
    String text,
    String encoding,
    String ending,
  );
  Future<EditorSummary> save(
    String token,
    int operation,
    int revision,
    int terminal,
    int generation,
  );
  Future<EditorSummary> bind(String token, int terminal, int generation);
  Future<void> cancel(String token, int operation);
  Future<void> close(String token, bool keepDraft);
}

class NativeEditorBackend implements EditorBackend {
  const NativeEditorBackend();
  @override
  int begin(String token) => rust.beginEditorOperation(editorId: token);
  @override
  EditorProgress? progress(String token, int operation) =>
      rust.editorProgress(editorId: token, operation: operation);
  @override
  Future<EditorDocument> prepare(
    String token,
    int operation, {
    String? inputEncoding,
  }) => rust.prepareEditor(
    editorId: token,
    operation: operation,
    inputEncoding: inputEncoding,
  );
  @override
  Future<EditorSummary> update(
    String token,
    int revision,
    String text,
    String encoding,
    String ending,
  ) => rust.updateEditor(
    editorId: token,
    expectedRevision: revision,
    text: text,
    encoding: encoding,
    lineEnding: ending,
  );
  @override
  Future<EditorSummary> save(
    String token,
    int operation,
    int revision,
    int terminal,
    int generation,
  ) => rust.saveEditor(
    editorId: token,
    operation: operation,
    expectedRevision: revision,
    id: terminal,
    generation: generation,
  );
  @override
  Future<EditorSummary> bind(String token, int terminal, int generation) =>
      rust.bindEditor(editorId: token, id: terminal, generation: generation);
  @override
  Future<void> cancel(String token, int operation) =>
      rust.cancelEditorOperation(editorId: token, operation: operation);
  @override
  Future<void> close(String token, bool keepDraft) =>
      rust.closeEditor(editorId: token, keepDraft: keepDraft);
}

/// Owns UI text and one coalesced draft writer independently of dialog rebuilds.
/// Local persistence never invokes Save, sends a PTY command or opens an SSH.
class RemoteEditorController extends ChangeNotifier {
  RemoteEditorController(
    this.token, {
    this.backend = const NativeEditorBackend(),
    this.externalBackend = const NativeExternalEditorBackend(),
    this.externalPlatform = const LocalExternalEditorPlatform(),
    TerminalController? source,
    this.initialInputEncoding,
    this.initialRawMode = false,
  }) {
    content.addListener(_textChanged);
    _setSource(source);
  }
  final String token;
  final EditorBackend backend;
  final String? initialInputEncoding;
  final bool initialRawMode;
  bool get rawMode => initialRawMode || summary?.rawBytes != null;
  final ExternalEditorBackend externalBackend;
  final ExternalEditorPlatform externalPlatform;
  ExternalEditorLink? external;
  bool _externalAttempted = false, _importingExternal = false, binding = false;
  Future<void>? _externalStartWork, _externalCleanupWork;
  bool get hasExternalCopy =>
      _externalAttempted ||
      summary?.externalDirectory != null ||
      external?.active == true;
  bool get externalActive => external?.active == true;
  bool get externalBusy =>
      external?.busy == true ||
      _externalStartWork != null ||
      _externalCleanupWork != null;
  final content = TextEditingController();
  EditorSummary? summary;
  TerminalController? _source;
  TerminalController? get source => _source;
  String encoding = 'utf8', lineEnding = 'lf';
  bool loading = true, saving = false, closing = false, closed = false;
  bool _cancelSave = false;
  bool get cancellingSave => saving && _cancelSave;
  bool _disposed = false, _composing = false;
  int _local = 0, _persisted = 0;
  String _committed = '';
  String? _localError, _remoteError;
  String? get error => _localError ?? _remoteError ?? external?.error;
  bool get ready => summary != null;
  bool get composing =>
      content.value.composing.isValid && !content.value.composing.isCollapsed;
  bool get dirty =>
      _local != _persisted ||
      (summary != null && summary!.revision != summary!.savedRevision);
  bool get persisted => ready && _local == _persisted;
  bool get canSave =>
      ready &&
      !loading &&
      !saving &&
      !closing &&
      !closed &&
      !composing &&
      !externalBusy &&
      (!hasExternalCopy || externalActive) &&
      (!rawMode || externalActive) &&
      _source?.connected == true;
  Timer? _timer;
  Timer? _progressTimer;
  EditorProgress? progress;
  int? _operation;
  Future<void>? _loadWork, _saveWork, _flushWork, _closeWork;
  Object? _connectionState;
  bool _pollProgress() {
    final operation = _operation;
    if (operation == null || closing || closed || _disposed) return false;
    try {
      final next = backend.progress(token, operation);
      if (next != null && next.operation == operation && next != progress) {
        progress = next;
        _emit();
      }
      return true;
    } catch (e) {
      _progressTimer?.cancel();
      _remoteError = '读取编辑传输进度失败；实际保存结果仍以远端确认返回为准：$e';
      _emit();
      return false;
    }
  }

  void _startProgress(int operation) {
    _operation = operation;
    progress = null;
    _progressTimer?.cancel();
    if (!_pollProgress()) return;
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _pollProgress(),
    );
  }

  void _stopProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _pollProgress();
    _operation = null;
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _accept(EditorSummary value) {
    final old = summary;
    if (old == null ||
        value.revision > old.revision ||
        (value.revision == old.revision &&
            value.savedRevision >= old.savedRevision)) {
      summary = value;
    }
  }

  void _setSource(TerminalController? source) {
    _source?.removeListener(_sourceChanged);
    _source = source;
    _connectionState = null;
    source?.addListener(_sourceChanged);
    _sourceChanged();
  }

  void _sourceChanged() {
    final s = _source;
    final state = (s?.id, s?.phase, s?.generation);
    if (_connectionState != state) {
      _connectionState = state;
      if (s?.connected != true) external?.pause();
      _emit();
    }
  }

  Future<void> load({String? inputEncoding}) {
    if (closed || closing || _disposed || ready) return Future.value();
    return _loadWork ??= _load(inputEncoding ?? initialInputEncoding)
        .whenComplete(() => _loadWork = null);
  }

  Future<void> _load(String? inputEncoding) async {
    loading = true;
    _remoteError = null;
    _emit();
    try {
      final operation = backend.begin(token);
      _startProgress(operation);
      final document = await backend.prepare(
        token,
        operation,
        inputEncoding: inputEncoding,
      );
      if (closing || closed || _disposed) return;
      summary = document.summary;
      encoding = document.summary.encoding;
      lineEnding = document.summary.lineEnding;
      _committed = document.text;
      content.text = document.text; // still loading: not a user edit
    } catch (e) {
      if (!closing && !closed) _remoteError = '读取编辑文件失败：$e';
    } finally {
      _stopProgress();
      loading = false;
      _emit();
    }
  }

  void _textChanged() {
    if (rawMode) return;
    if (loading || closing || closed || _disposed || _importingExternal) return;
    final beforeDirty = dirty, beforePersisted = persisted;
    final wasComposing = _composing;
    _composing = composing;
    if (!composing && !identical(_committed, content.text)) {
      _committed = content.text;
      _local++;
      _schedule();
    }
    if (wasComposing != composing ||
        beforeDirty != dirty ||
        beforePersisted != persisted) {
      _emit();
    }
  }

  void setFormat({String? encoding, String? lineEnding}) {
    if (rawMode) return;
    if (!ready ||
        saving ||
        closing ||
        closed ||
        externalActive ||
        externalBusy) {
      return;
    }
    final nextEncoding = encoding ?? this.encoding,
        nextEnding = lineEnding ?? this.lineEnding;
    if (nextEncoding == this.encoding && nextEnding == this.lineEnding) return;
    this.encoding = nextEncoding;
    this.lineEnding = nextEnding;
    _local++;
    _schedule();
    _emit();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 350), () {
      // _drain publishes persistence errors to the UI; no unhandled async error.
      unawaited(flush().catchError((Object _) {}));
    });
  }

  Future<void> flush() {
    _timer?.cancel();
    return _flushWork ??= _drain().whenComplete(() => _flushWork = null);
  }

  Future<void> _drain() async {
    if (!ready || closed) return;
    try {
      while (_persisted != _local) {
        final revision = _local;
        final text = _committed, format = encoding, ending = lineEnding;
        final result = await backend.update(
          token,
          summary!.revision,
          text,
          format,
          ending,
        );
        _accept(result);
        _persisted = revision;
        _localError = null;
        _emit();
        // Only the newest remaining text is captured after an in-flight write.
        // Slow disks cannot queue an entire file copy for every edit/debounce.
      }
    } catch (e) {
      _localError = '本机加密草稿未保存，当前文字仍保留，请重试：$e';
      _emit();
      rethrow;
    }
  }

  Future<void> save() => _startSave(refreshExternal: true);
  Future<void> _startSave({required bool refreshExternal}) {
    if (_saveWork != null) return _saveWork!;
    return _saveWork = _save(refreshExternal: refreshExternal)
        .whenComplete(() => _saveWork = null);
  }

  Future<void> _save({required bool refreshExternal}) async {
    if (!canSave) {
      _remoteError = composing
          ? '请先确认或取消输入法候选，再保存远端文件'
          : '请先手动连接并明确关联原SSH服务器；本机草稿保留';
      _emit();
      return;
    }
    saving = true;
    _cancelSave = false;
    progress =
        null; // Previous read/save bytes do not describe this local flush.
    _remoteError = null;
    _emit();
    try {
      await flush();
      if (refreshExternal && externalActive && !closing && !_cancelSave) {
        await external!.capture();
      }
      if (closing || closed) return;
      if (_cancelSave) {
        _remoteError = '保存已取消，完整本机草稿已加密保留；未开始上传';
        return;
      }
      final source = _source!;
      final id = source.id;
      final generation = source.generation;
      if (id == null || !source.connected) throw StateError('原SSH会话已断开');
      final operation = backend.begin(token);
      _startProgress(operation);
      _accept(
        await backend.save(token, operation, summary!.revision, id, generation),
      );
    } catch (e) {
      _remoteError = '远端保存未确认，本机完整草稿保留；远端可能已部分写入：$e';
    } finally {
      _stopProgress();
      saving = false;
      _emit();
    }
  }

  Future<void> bind(TerminalController source) async {
    final id = source.id, generation = source.generation;
    if (id == null ||
        !source.connected ||
        !ready ||
        saving ||
        closing ||
        externalBusy ||
        binding ||
        closed) {
      return;
    }
    binding = true;
    _emit();
    try {
      final result = await backend.bind(token, id, generation);
      if (closing || closed || _disposed) return;
      _accept(result);
      _setSource(source);
      _remoteError = null;
    } catch (e) {
      _remoteError = '无法关联此SSH会话：$e';
    } finally {
      binding = false;
    }
    _emit();
  }

  void _externalDocument(EditorDocument document) {
    if (_disposed || closed || closing) return;
    if (summary != null && document.summary.revision < summary!.revision) {
      return;
    }
    _importingExternal = true;
    try {
      _accept(document.summary);
      encoding = document.summary.encoding;
      lineEnding = document.summary.lineEnding;
      _committed = document.text;
      content.text = document.text;
      _local++;
      _persisted = _local; // Rust already committed this exact draft.
      _localError = null;
    } finally {
      _importingExternal = false;
    }
    _emit();
  }

  Future<bool> _uploadExternal() async {
    final desired = summary!.revision;
    if (summary!.savedRevision >= desired) return true;
    final pending = _saveWork;
    if (pending != null) {
      await pending;
      if (error != null || external?.paused == true) return false;
      if (summary!.savedRevision >= desired) return true;
    }
    if (closing ||
        closed ||
        _disposed ||
        external?.paused == true ||
        !canSave) {
      return false;
    }
    await _startSave(refreshExternal: false);
    return summary!.savedRevision >= desired;
  }

  Future<void> startExternal(
    String executable,
    String base,
    Future<bool> Function(String) confirmExisting,
  ) {
    if (!ready ||
        composing ||
        loading ||
        saving ||
        closing ||
        closed ||
        binding) {
      return Future.error(StateError('请先完成当前输入或编辑操作'));
    }
    return _externalStartWork ??=
        _startExternal(executable, base, confirmExisting).whenComplete(() {
          _externalStartWork = null;
          _emit();
        });
  }

  Future<void> _startExternal(
    String executable,
    String base,
    Future<bool> Function(String) confirmExisting,
  ) async {
    _externalAttempted =
        true; // Native can pin intent before file creation fails.
    _remoteError = null;
    var link = external;
    if (link == null) {
      link = ExternalEditorLink(
        token: token,
        revision: () => summary!.revision,
        onDocument: _externalDocument,
        onSummary: _accept,
        upload: _uploadExternal,
        canUpload: () => _source?.connected == true && !closing && !closed,
        alive: () => !_disposed && !closed && !closing,
        backend: externalBackend,
        platform: externalPlatform,
      );
      external = link;
      link.addListener(_emit);
    }
    _emit();
    try {
      await flush();
      if (closed || closing) return;
      await link.start(executable, base, confirmExisting);
    } catch (e) {
      _remoteError = '外部编辑未正常启动，草稿与可能的工作文件保留：$e';
      _emit();
      rethrow;
    }
  }

  void resumeExternalUploads() {
    if (_source?.connected != true || closing || closed) return;
    _remoteError = null;
    external?.resumeAndUpload();
  }

  Future<void> cleanupExternal() {
    if (saving || closing || closed || externalBusy) {
      return Future.error(StateError('请等待当前编辑操作结束'));
    }
    return _externalCleanupWork ??= _cleanupExternal().whenComplete(() {
      _externalCleanupWork = null;
      _emit();
    });
  }

  Future<void> _cleanupExternal() async {
    try {
      final link = external;
      if (link != null) {
        await link.cleanup();
      } else {
        _externalDocument(await externalBackend.cleanup(token));
      }
      _externalAttempted = false;
      _remoteError = null;
      _emit();
    } catch (e) {
      _remoteError = '工作文件尚未清理，草稿保留：$e';
      _emit();
      rethrow;
    }
  }

  Future<void> reconnect() async {
    final source = _source;
    if (source == null ||
        source.connected ||
        source.phase == 'Connecting' ||
        source.phase == 'Closed' ||
        closed ||
        saving ||
        closing) {
      return;
    }
    try {
      await source.reconnect();
    } catch (e) {
      _remoteError = '手动重新连接失败，草稿保留：$e';
      _emit();
    }
  }

  Future<void> cancelOperation() async {
    if (saving && !_cancelSave) {
      external?.pause();
      _cancelSave = true;
      _emit();
    }
    final operation = _operation;
    if (operation == null) return;
    try {
      await backend.cancel(token, operation);
    } catch (e) {
      _remoteError = '取消操作未确认，草稿保留：$e';
      _emit();
    }
  }

  Future<void> close({required bool keepDraft}) {
    if (closed) return Future.value();
    return _closeWork ??= _close(keepDraft)
        .whenComplete(() => _closeWork = null);
  }

  Future<void> _close(bool keepDraft) async {
    closing = true;
    external?.requestClose();
    _progressTimer?.cancel();
    _timer?.cancel();
    _emit();
    try {
      await cancelOperation();
      final load = _loadWork;
      if (load != null) await load;
      final save = _saveWork;
      if (save != null) await save;
      final startExternal = _externalStartWork;
      if (startExternal != null) {
        try {
          await startExternal;
        } catch (_) {
          /* visible error and pinned files are retained */
        }
      }
      final cleanup = _externalCleanupWork;
      if (cleanup != null) {
        try {
          await cleanup;
        } catch (_) {
          /* cleanup error is visible; pinned files retained */
        }
      }
      final link = external;
      if (link != null) await link.close();
      final flush = _flushWork;
      if (flush != null) {
        try {
          await flush;
        } catch (_) {
          if (keepDraft) rethrow; /* explicit discard */
        }
      }
      if (keepDraft) await this.flush();
      await backend.close(token, keepDraft || hasExternalCopy);
      closed = true;
      _source?.removeListener(_sourceChanged);
    } catch (e) {
      _localError = '关闭编辑文档失败，当前文字仍保留：$e';
      rethrow;
    } finally {
      closing = false;
      _emit();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _progressTimer?.cancel();
    _timer?.cancel();
    _source?.removeListener(_sourceChanged);
    external?.removeListener(_emit);
    external?.dispose();
    content.removeListener(_textChanged);
    content.clear();
    content.dispose();
    super.dispose();
  }
}
