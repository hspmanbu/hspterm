import '../app_notice.dart';
import '../run_log.dart';
import 'staging_cleanup_port.dart';
import '../terminal/application_keys.dart';
import '../src/rust/shortcut_settings.dart' as shortcut;
import 'typography_store.dart';
import 'remote_inspection.dart';
import 'configuration_backup.dart';
import 'configuration_sync.dart';
import 'local_edit_launch.dart';
import 'google_drive_account.dart';
import 'google_drive_objects.dart';
import 'appearance.dart';
import 'sftp_view_settings.dart';
import '../src/rust/history_controls.dart' as history;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:path_provider/path_provider.dart';

import '../prototype/model.dart';
import '../src/rust/api.dart' as rust;
import '../src/rust/transfers.dart' as jobs;
import '../src/rust/remote_transfers.dart' as remote;
import '../terminal/backend.dart';
import '../terminal/controller.dart';
import '../terminal/view.dart';
import 'store.dart';
import 'transfer_rate.dart';
import 'directory_reader.dart';
import 'directory_cache.dart';
import 'editor_controller.dart';
import 'connection_test.dart';
import 'temporary_connection.dart';
import '../src/rust/connections/temporary.dart' as once;
import '../src/rust/tmux.dart' as tmx;
import '../src/rust/host_ordering.dart' as ordering;
import '../src/rust/host_bulk.dart' as bulk;

/// SQLite acknowledged the change; a later metadata refresh is not a failed
/// save and must not invite an automatic reapplication of the old proposal.
class PaletteShortcutSavedFailure implements Exception {
  PaletteShortcutSavedFailure(this.saved);
  final shortcut.PaletteShortcutView saved;
  @override
  String toString() => '快捷键已保存到原配置库，但当前设置上下文已改变；请重新载入，不要重复提交旧修改';
}

class HostOrderingRefreshFailure implements Exception {
  HostOrderingRefreshFailure(this.saved, this.cause);
  final ordering.OrderingView saved;
  final Object cause;
  @override
  String toString() => '主机排序已保存，但列表刷新失败：$cause';
}

class HostBulkRefreshFailure implements Exception {
  HostBulkRefreshFailure(this.saved, this.cause);
  final bulk.HostBulkView saved;
  final Object cause;
  @override
  String toString() => '批量修改已保存，但列表刷新失败：$cause';
}

/// The key is already stored in the encrypted draft; metadata refresh may fail
/// independently and must not cause the UI to resubmit the previous secret.
class KeyPreparationRefreshFailure implements Exception {
  KeyPreparationRefreshFailure(this.saved, this.cause);
  final KeyDetails saved;
  final Object cause;
  @override
  String toString() => '密钥已写入加密草稿，但列表刷新失败；请勿重复生成或导入：$cause';
}

/// Only metadata, owned by the application model rather than a mounted sidebar.
/// Capturing a selection never reads source bodies or touches a filesystem.
class RemoteFileSelection {
  RemoteFileSelection._(
    this.source,
    this.nativeId,
    this.generation,
    List<String> paths, {
    this.cut = false,
  }) : paths = List.unmodifiable(paths);
  final LiveTerminalSession source;
  final int nativeId, generation;
  final List<String> paths;
  final bool cut;
}

/// A failed batch preserves only unsubmitted sources for an explicit retry.
class RemoteFileSubmissionFailure implements Exception {
  RemoteFileSubmissionFailure(
    List<String> acceptedIds,
    this.remaining,
    this.cause,
  ) : acceptedIds = List.unmodifiable(acceptedIds);
  final List<String> acceptedIds;
  final RemoteFileSelection remaining;
  final Object cause;
  @override
  String toString() =>
      '已加入 ${acceptedIds.length} 个任务，另有 ${remaining.paths.length} 项未入队：$cause';
}

/// A stable session owns the controller. Flutter display nodes never own SSH.
class LiveTerminalSession extends TerminalSession {
  LiveTerminalSession(super.id, super.host, TerminalBackend backend)
    : controller = TerminalController(backend),
      super(disconnected: true) {
    path = '.';
    sftpEnabled = false;
    controller.visible = false;
    controller.profileId = host.id;
  }
  final TerminalController controller;
  RemoteInspectionController? _inspection;
  RemoteInspectionController get inspection =>
      _inspection ??= RemoteInspectionController(controller);
  Future<void> stopInspection() => _inspection?.shutdown() ?? Future.value();
  void disposeInspection() => _inspection?.dispose();

  bool temporaryConnection = false;

  /// Connection generation that already used its single automatic reconnect
  /// attempt; user-initiated reconnects are never blocked by it.
  int autoReconnectAttempted = 0;
  bool wasConnected = false;
  TemporaryTarget? temporaryTarget;
  once.TemporarySource? pendingTemporarySource;
  TemporaryConnectionInput? pendingTemporaryInput;
  void clearTemporaryInput() {
    pendingTemporaryInput?.forgetSecrets();
    pendingTemporaryInput = null;
    pendingTemporarySource = null;
  }

  final view = GlobalKey<TerminalViewState>();
  Object? _view;
  VoidCallback? changedListener;
  int directoryEpoch = 0, sftpGeneration = 0;
  int pathLocationEpoch = 0;
  int followedDirectoryVersion = -1;
  late final directoryCache = DirectoryCache(directories);
  @override
  bool get isMock => false;
  @override
  String get statusLabel => switch (controller.phase) {
    'Connected' =>
      controller.tmuxReadonly == null
          ? '已连接'
          : controller.tmuxReadonly!
          ? '已连接 · tmux只读'
          : '已连接 · tmux控制',
    'Connecting' => '正在连接',
    'Failed' => '连接失败',
    'Disconnected' => '已断开',
    'Closing' => '正在关闭 · 等待收尾',
    'Closed' => '已关闭',
    _ => '等待连接',
  };
  @override
  List<DemoFile> get files => directories[path] ?? const [];
  Object attachView() {
    final token = Object();
    _view = token;
    unawaited(controller.setVisible(true).catchError(controller.report));
    return token;
  }

  void detachView(Object token) {
    // A newly mounted view can precede disposal of the old tree node.
    if (!identical(_view, token)) return;
    _view = null;
    unawaited(controller.setVisible(false).catchError(controller.report));
  }
}

/// An explicit UI selection holds its original runtime identity through a
/// dialog. Profile metadata is only a filter; Native checks authenticated target.
class TransferConnectionRef {
  TransferConnectionRef(this.session)
    : nativeId = session.controller.id ?? (throw StateError('SSH尚未就绪')),
      generation = session.controller.generation;
  final LiveTerminalSession session;
  final int nativeId, generation;
  bool valid(Iterable<LiveTerminalSession> sessions, String? host) =>
      host != null &&
      sessions.contains(session) &&
      session.host.id == host &&
      session.controller.connected &&
      session.controller.id == nativeId &&
      session.controller.generation == generation;
}

/// UI preference only. The native task still verifies address/user/host key
/// and its current generation before any IO. A profile ID is not that proof.
LiveTerminalSession? chooseTransferConnection(
  Iterable<LiveTerminalSession> sessions, {
  required LiveTerminalSession? focus,
  required String? hostId,
  required int? preferredId,
  required int? preferredGeneration,
}) {
  if (hostId == null) return null;
  final connected = sessions
      .where(
        (s) =>
            s.host.id == hostId &&
            s.controller.id != null &&
            s.controller.connected,
      )
      .toList();
  final original = preferredId == null || preferredGeneration == null
      ? null
      : connected
            .where(
              (s) =>
                  s.controller.id == preferredId &&
                  s.controller.generation == preferredGeneration,
            )
            .firstOrNull;
  if (original != null) return original;
  if (focus != null && connected.contains(focus)) return focus;
  return connected.firstOrNull;
}

class LiveWorkbenchModel extends WorkbenchModel implements StagingCleanupPort {
  @override
  bool get isClosing => _disposed || _shutdown != null;
  Future<tmx.TmuxSelection?> Function(LiveTerminalSession, tmx.TmuxPrompt)?
  requestTmuxChoice;
  Future<TemporaryConnectionInput?> Function(DemoHost, TemporaryTarget?)?
  requestTemporaryParameters;
  bool _temporaryDialogOpen = false;
  LiveTerminalSession? _followSubject;
  bool _followPolicy = false, _followBusy = false;
  int _followToken = 0;
  Timer? _followTimer;
  (LiveTerminalSession, int)? _followLoading;

  final _followOverrides = Expando<bool>();
  @override
  bool followsTerminalDirectory(TerminalSession session) =>
      _followOverrides[session] ??
      (_records[session.host.id]?.followOsc7 ?? false);
  @override
  Future<void> setTerminalDirectoryFollow(
    TerminalSession session,
    bool value,
  ) async {
    final s = _connected(session);
    _followOverrides[s] = value;
    s.followedDirectoryVersion = -1;
    _syncDirectoryFollow();
    changed();
  }

  @override
  Future<void> jumpToTerminalDirectory(TerminalSession session) {
    final s = _connected(session),
        native = s.controller.id!,
        generation = s.controller.generation;
    final work = () async {
      final path = await rust.terminalWorkingDirectory(
        id: native,
        generation: generation,
      );
      _checkSftpMutation(s, native, generation);
      if (path == null) {
        throw StateError('终端尚未报告工作目录；请在启用 Shell 集成后手动重连并返回普通提示符');
      }
      await loadDirectory(s, path);
    }();
    _track(work);
    return work;
  }

  @override
  Future<void> createRemoteFile(TerminalSession session, String name) {
    final s = _connected(session), directory = session.path;
    return _mutateAndRefresh(
      s,
      (id, generation) => rust.sftpCreateFile(
        id: id,
        generation: generation,
        path: remotePath(directory, name),
      ),
      affectedDirectories: {directory},
    );
  }

  bool _canFollow(LiveTerminalSession s) =>
      !_disposed &&
      _shutdown == null &&
      sessions.contains(s) &&
      identical(focus, s) &&
      sidebar &&
      page == WorkPage.workspace &&
      !startPage &&
      s.sftpEnabled &&
      s.controller.connected &&
      followsTerminalDirectory(s);

  void _cancelDirectoryFollow() {
    _followTimer?.cancel();
    _followTimer = null;
    _followToken++;
    final loading = _followLoading;
    _followLoading = null;
    if (loading != null && loading.$1.directoryEpoch == loading.$2) {
      loading.$1.directoryEpoch++;
      loading.$1.loadingDirectory = false;
    }
  }

  void _scheduleDirectoryFollow(LiveTerminalSession s) {
    if (!_canFollow(s)) {
      if (identical(_followSubject, s)) _cancelDirectoryFollow();
      return;
    }
    if (_followBusy ||
        _followTimer != null ||
        s.followedDirectoryVersion == s.controller.directoryReportVersion) {
      return;
    }
    final token = _followToken;
    _followTimer = Timer(const Duration(milliseconds: 150), () {
      _followTimer = null;
      if (_canFollow(s) && token == _followToken) {
        _track(_followDirectory(s, token));
      }
    });
  }

  Future<void> _followDirectory(LiveTerminalSession s, int token) async {
    _followBusy = true;
    final id = s.controller.id!, generation = s.controller.generation;
    final directoryEpoch = s.directoryEpoch;
    s.followedDirectoryVersion = s.controller.directoryReportVersion;
    bool current() =>
        token == _followToken &&
        _canFollow(s) &&
        s.controller.id == id &&
        s.controller.generation == generation;
    try {
      final path = await rust.terminalWorkingDirectory(
        id: id,
        generation: generation,
      );
      if (!current() ||
          s.directoryEpoch != directoryEpoch ||
          path == null ||
          path == s.path) {
        return;
      }
      _followLoading = (s, directoryEpoch + 1);
      await loadDirectory(s, path, remember: false, fromOsc7: true);
    } catch (error) {
      if (current()) {
        s.sftpError = '终端目录跟随失败：${appMessage(error)}';
        reportOperation(error);
      }
    } finally {
      if (token == _followToken) _followLoading = null;
      _followBusy = false;
      final active = focus;
      if (active is LiveTerminalSession) _scheduleDirectoryFollow(active);
    }
  }

  void _syncDirectoryFollow() {
    final s = focus is LiveTerminalSession
        ? focus as LiveTerminalSession
        : null;
    final policy = s != null && followsTerminalDirectory(s);
    if (!identical(s, _followSubject) || policy != _followPolicy) {
      final enabling = policy && !_followPolicy && identical(s, _followSubject);
      _cancelDirectoryFollow();
      _followSubject = s;
      _followPolicy = policy;
      if (enabling) s.followedDirectoryVersion = -1;
    }
    if (s != null) _scheduleDirectoryFollow(s);
  }

  LiveWorkbenchModel({
    this.store = const NativeHostStore(),
    this.directoryReader = const PagedDirectoryReader(),
    this.previewCacheDirectory,
    this.editorSupportDirectory,
    this.paletteLoader = rust.commandPaletteShortcut,
    TerminalTypographyController? typographyController,
    AppearanceController? appearanceController,
    SftpViewSettingsController? sftpViewController,
    TerminalBackend Function()? backendFactory,
  }) : sftpView = sftpViewController ?? SftpViewSettingsController(),
       appearance = appearanceController ?? AppearanceController(),
       typography = typographyController ?? TerminalTypographyController(),
       backendFactory =
           backendFactory ?? (() => const NativeTerminalBackend()) {
    hosts.clear();
    typography.addListener(_typographyChanged);
    appearance.addListener(_appearanceChanged);
    sftpView.addListener(_sftpViewChanged);
    recent.clear();
    groups
      ..clear()
      ..addAll(['全部主机', '收藏', '未分组']);
  }
  final Future<shortcut.PaletteShortcutView> Function() paletteLoader;
  PaletteBinding paletteBinding = const PaletteBinding(enabled: false);
  shortcut.PaletteShortcutView? _paletteShortcut;
  int _paletteEpoch = 0;
  void _acceptShortcut(shortcut.PaletteShortcutView value) {
    final key = PaletteBinding.keys[value.key];
    if (key == null) throw StateError('当前界面不支持此快捷键；没有替换保存设置');
    _paletteShortcut = value;
    paletteBinding = PaletteBinding(
      enabled: value.enabled,
      key: key,
      modifiers: value.modifiers,
      applicationInTerminal: value.applicationInTerminal,
    );
    changed();
  }

  Future<shortcut.PaletteShortcutView> reloadPaletteShortcut() async {
    if (_disposed || _shutdown != null) throw StateError('应用正在关闭');
    final epoch = ++_paletteEpoch;
    try {
      final value = await paletteLoader();
      if (_disposed || _shutdown != null || epoch != _paletteEpoch) {
        throw StateError('快捷键读取已过期');
      }
      _acceptShortcut(value);
      return value;
    } catch (error) {
      if (!_disposed && epoch == _paletteEpoch) {
        _paletteShortcut = null;
        paletteBinding = const PaletteBinding(enabled: false);
        changed();
      }
      rethrow;
    }
  }

  Future<shortcut.PaletteShortcutView> savePaletteShortcut(
    shortcut.PaletteShortcutView value,
  ) {
    if (_disposed ||
        _shutdown != null ||
        _paletteShortcut?.vaultScope != value.vaultScope ||
        _paletteShortcut?.revision != value.revision) {
      return Future.error(StateError('原快捷键上下文已改变，请重新载入；未保存'));
    }
    final epoch = _paletteEpoch;
    final operation = () async {
      final saved = await rust.saveCommandPaletteShortcut(value: value);
      if (_disposed) return saved;
      if (epoch != _paletteEpoch ||
          _paletteShortcut?.vaultScope != value.vaultScope) {
        throw PaletteShortcutSavedFailure(saved);
      }
      _acceptShortcut(saved);
      return saved;
    }();
    _track(operation.then<void>((_) {}));
    return operation;
  }

  final TerminalTypographyController typography;
  Future<void> Function()? retireTerminalNotifications;
  VoidCallback? resumeTerminalNotifications;
  final SftpViewSettingsController sftpView;
  void _sftpViewChanged() {
    if (_disposed) return;
    if (sftpView.error != null) operationError = sftpView.error;
    changed();
  }

  @override
  bool get fileFoldersFirst =>
      sftpView.confirmed?.settings.foldersFirst ?? true;
  @override
  bool get fileShowHidden => sftpView.confirmed?.settings.showHidden ?? false;
  @override
  bool get fileCompact => sftpView.confirmed?.settings.compact ?? false;
  @override
  Object get fileDefaultsRevision =>
      (sftpView.confirmed?.scope, sftpView.confirmed?.revision);
  final AppearanceController appearance;
  void _appearanceChanged() {
    if (_disposed) return;
    final value = appearance.value;
    if (value != null) light = value.light;
    if (appearance.error != null) operationError = appearance.error;
    changed();
  }

  @override
  bool get themeAvailable => !isClosing && appearance.available;
  @override
  void chooseTheme(bool value) {
    if (themeAvailable) unawaited(appearance.choose(value));
  }

  @override
  Future<void> applyTheme(bool value) async {
    if (!themeAvailable) throw StateError('外观设置尚未就绪');
    await appearance.choose(value);
    if (appearance.value?.light != value) {
      throw StateError(appearance.error ?? '外观设置未确认保存');
    }
  }

  late final configurationBackups = ConfigurationBackupController(
    onRestored: _afterBackupRestored,
  );
  late final configurationSync = ConfigurationSyncController(
    onCommitted: _reloadRestoredConfiguration,
  );
  late final googleDriveAccount = GoogleDriveAccountController();
  late final googleDriveObjects = GoogleDriveObjectsController(
    accounts: googleDriveAccount,
  );
  Future<void> _afterBackupRestored() async {
    // Full backup restore rotates the runtime scope. Ordinary cloud merge
    // deliberately does not use this path or retire unrelated operations.
    await configurationSync.shutdown();
    await googleDriveObjects.shutdown();
    await googleDriveAccount.shutdown();
    if (_disposed || _shutdown != null) return;
    configurationSync.resumeAfterCancelledShutdown();
    googleDriveObjects.resumeAfterCancelledShutdown();
    googleDriveAccount.resumeAfterCancelledShutdown();
    await _reloadRestoredConfiguration();
    if (!_disposed && _shutdown == null) await googleDriveAccount.load();
    if (!_disposed && _shutdown == null) {
      await googleDriveObjects.loadCreation();
    }
  }

  Future<void> _reloadRestoredConfiguration() async {
    if (_disposed || _shutdown != null) return;
    await load();
    if (_disposed || _shutdown != null) return;
    await typography.load();
    if (_disposed || _shutdown != null) return;
    await appearance.load();
    if (_disposed || _shutdown != null) return;
    await sftpView.load();
    if (!_disposed) changed();
  }

  TypographySnapshot? _seenTypography;
  void _typographyChanged() {
    if (_disposed) return;
    final current = typography.snapshot;
    if (!identical(current, _seenTypography)) {
      _seenTypography = current;
      for (final s in sessions) {
        unawaited(typography.ensureHost(s.host.id));
      }
    }
    changed();
  }

  double get fontSize => typography.forHost(focus?.host.id).size;
  final _editors = <RemoteEditorController>{};
  bool _editorRequested = false;
  @override
  bool get hasActiveEditors => _editors.any((editor) => !editor.closed);
  void registerEditor(RemoteEditorController editor) {
    if (_disposed || _shutdown != null) throw StateError('应用正在关闭');
    _editors.add(editor);
    _editorRequested |= editor.backend is NativeEditorBackend;
    // Progress/text belong to the dialog. Rebuilding the whole workbench for
    // each editor notification is wasteful and can notify during route mount.
    changed();
  }

  void unregisterEditor(RemoteEditorController editor) {
    _editors.remove(editor);
    changed();
  }

  final HostStore store;
  HostConnectionTest? _hostTest;
  Future<void>? _hostTestOperation;
  @override
  Future<void> testSavedHost(DemoHost host) {
    if (_disposed || _shutdown != null) {
      return Future.error(StateError('应用正在关闭'));
    }
    if (_hostTest != null) return Future.error(StateError('已有连接测试正在进行'));
    final saved = _records[host.id];
    if (saved == null) return Future.error(StateError('请先正式保存主机配置'));
    if (saved.address != host.address ||
        saved.port != host.port ||
        saved.username != host.user ||
        saved.jumpHostId != host.jumpHostId) {
      return Future.error(StateError('主机目标已变化，请重新选择并明确测试'));
    }
    final captured = _host(saved);
    final test = HostConnectionTest(
      backend: backendFactory(),
      hostId: saved.id,
      address: saved.address,
      port: saved.port,
      username: saved.username,
      jumpHostId: saved.jumpHostId,
      confirmHostKey: (event) async =>
          await confirmHostKey?.call(captured, event) ?? false,
    );
    _hostTest = test;
    changed();
    final operation = test.run().whenComplete(() {
      if (identical(_hostTest, test)) {
        _hostTest = null;
        _hostTestOperation = null;
      }
      changed();
    });
    _hostTestOperation = operation;
    _track(operation, reportFailure: () => !test.cancelled);
    return operation;
  }

  @override
  Future<void> cancelHostTest({Future<void>? expected}) async {
    if (expected != null && !identical(expected, _hostTestOperation)) return;
    await _hostTest?.cancel();
  }

  final PagedDirectoryReader directoryReader;
  final String? previewCacheDirectory;
  final String? editorSupportDirectory;
  Future<void>? _previewInitialization;
  bool _previewRequested = false;
  Future<void> initializePreviewCache() {
    _previewRequested = true;
    return _previewInitialization ??= () async {
      try {
        final directory =
            previewCacheDirectory ?? (await getTemporaryDirectory()).path;
        if (_disposed || _shutdown != null) throw StateError('应用正在关闭');
        final deferred = await rust.initializeFilePreviews(
          cacheDirectory: directory,
        );
        if (deferred > 0) {
          reportOperation(StateError('$deferred 份遗留预览缓存清理失败，将在后续启动重试'));
        }
      } catch (e) {
        _previewInitialization = null;
        rethrow;
      }
    }();
  }

  final TerminalBackend Function() backendFactory;
  final _records = <String, rust.HostConfig>{};
  final _drafts = <String, DemoHost>{};
  final _draftRecords = <String, rust.HostConfig>{};
  final _groups = <rust.HostGroupConfig>[];
  @override
  List<String> get hostGroups =>
      _groups.isEmpty ? super.hostGroups : _groups.map((g) => g.name).toList();
  @override
  List<(String, String)> get hostGroupEntries => _groups.isEmpty
      ? super.hostGroupEntries
      : [for (final g in _groups) (g.id, g.name)];
  final _pending = <Future<void>>{};
  final _retiringSessions = <LiveTerminalSession>{};
  final _retirementWork = <LiveTerminalSession, Future<void>>{};
  bool get hasRetiringSessions => _retiringSessions.isNotEmpty;

  Future<void> _retireDetachedSession(LiveTerminalSession source) {
    if (_remoteFileClipboards.remove(source.id) != null) _clipboardRevision++;
    final existing = _retirementWork[source];
    if (existing != null) return existing;
    _retiringSessions.add(source);
    final work =
        () async {
          Object? failure;
          StackTrace? trace;
          try {
            await source.stopInspection();
          } catch (error, stack) {
            failure = error;
            trace = stack;
          }
          try {
            await source.controller.shutdown();
          } catch (error, stack) {
            failure ??= error;
            trace ??= stack;
          }
          if (failure != null) Error.throwWithStackTrace(failure, trace!);
          if (!source.controller.shutdownComplete) {
            throw StateError('原终端仍在关闭，尚未释放会话所有者');
          }
          _retiringSessions.remove(source);
          source.disposeInspection();
          source.controller.dispose();
          if (!_disposed) changed();
        }().whenComplete(() {
          _retirementWork.remove(source);
        });
    _retirementWork[source] = work;
    return work;
  }

  /// Explicit retry of cleanup only. Never recreates a terminal/Transport.
  Future<void> retryRetiringSessions() {
    final work = Future.wait(
      _retiringSessions.toList().map(_retireDetachedSession),
    ).then<void>((_) {});
    _track(work);
    return work;
  }

  Future<void>? _shutdown;
  bool _disposed = false;
  List<jobs.TransferTaskView> transferTasks = [];
  final _remoteFileClipboards = <String, RemoteFileSelection>{};
  RemoteFileSelection? get _remoteFileClipboard =>
      focus == null ? null : _remoteFileClipboards[focus!.id];
  set _remoteFileClipboard(RemoteFileSelection? value) {
    if (value != null) {
      _remoteFileClipboards[value.source.id] = value;
    } else if (focus != null) {
      _remoteFileClipboards.remove(focus!.id);
    }
  }

  int _clipboardRevision = 0;
  final _cutPastes = <RemoteFileSelection>{};
  int _enqueueBatches = 0;
  final _explorerExports =
      <
        Object,
        ({Future<void> Function() cancel, Future<void> Function() release})
      >{};
  void registerExplorerExport(
    Object owner, {
    required Future<void> Function() cancel,
    required Future<void> Function() release,
  }) {
    if (isClosing) throw StateError('应用正在关闭，不能建立Explorer交付');
    _explorerExports[owner] = (cancel: cancel, release: release);
  }

  void unregisterExplorerExport(Object owner) => _explorerExports.remove(owner);
  @override
  bool get hasPendingExternalDelivery => _explorerExports.isNotEmpty;
  Future<void> endExplorerDeliveries() async {
    final current = _explorerExports.values.toList();
    await Future.wait(current.map((e) => e.cancel()));
    await Future.wait(current.map((e) => e.release()));
    await _refreshAfterTransferMutation();
  }

  void monitorExplorerExport(Future<void> work) => _track(work);
  @override
  int get remoteFileClipboardRevision => _clipboardRevision;
  @override
  bool get remoteFileClipboardIsCut => _remoteFileClipboard?.cut ?? false;
  @override
  String? get remoteFileClipboardDescription {
    final clip = _remoteFileClipboard;
    return clip == null
        ? null
        : '${clip.cut ? '剪切' : '复制'} · ${clip.paths.length} 项 · ${clip.source.host.name}';
  }

  RemoteFileSelection prepareRemoteFileSelection(
    TerminalSession session,
    List<DemoFile> files, {
    bool cut = false,
  }) {
    final source = _connected(session);
    if (!source.sftpEnabled ||
        files.isEmpty ||
        files.length > 4096 ||
        !source.path.startsWith('/')) {
      throw StateError('请选择当前远端目录中的有效项目');
    }
    final remaining = files.toSet();
    if (remaining.length != files.length) throw StateError('文件选择不能包含重复项目');
    for (final current in source.files) {
      remaining.remove(current);
      if (remaining.isEmpty) break;
    }
    if (remaining.isNotEmpty) throw StateError('原目录选择已失效，请重新选择');
    final paths = <String>[];
    var bytes = 0;
    for (final file in files) {
      final path = remotePath(source.path, file.name);
      bytes += utf8.encode(path).length;
      if (bytes > 4 * 1024 * 1024 || path.contains('\u0000')) {
        throw StateError('文件剪贴板超过安全容量或包含无效路径');
      }
      paths.add(path);
    }
    return RemoteFileSelection._(
      source,
      source.controller.id!,
      source.controller.generation,
      List.unmodifiable(paths),
      cut: cut,
    );
  }

  @override
  void copyRemoteFileClipboard(
    TerminalSession session,
    List<DemoFile> files, {
    bool cut = false,
  }) {
    _remoteFileClipboard = prepareRemoteFileSelection(session, files, cut: cut);
    _clipboardRevision++;
    changed();
  }

  @override
  Future<List<String>> pasteRemoteFileClipboard(
    TerminalSession target,
    String directory,
    int expectedGeneration, {
    required bool allowMemoryRelay,
    bool allowDirect = false,
    required int expectedClipboardRevision,
  }) async {
    final clip = _remoteFileClipboards[target.id];
    if (clip == null ||
        !identical(clip.source, target) ||
        _clipboardRevision != expectedClipboardRevision) {
      throw StateError('文件剪贴板为空或确认期间已经改变，请重新粘贴');
    }
    return enqueueRemoteFileSelection(
      clip,
      target,
      directory,
      expectedGeneration,
      allowMemoryRelay: allowMemoryRelay,
      allowDirect: allowDirect,
    );
  }

  Future<List<String>> enqueueRemoteFileSelection(
    RemoteFileSelection clip,
    TerminalSession target,
    String directory,
    int expectedGeneration, {
    required bool allowMemoryRelay,
    bool allowDirect = false,
    bool Function()? shouldStop,
  }) async {
    final source = _connected(clip.source), destination = _connected(target);
    if (source.controller.id != clip.nativeId ||
        source.controller.generation != clip.generation ||
        destination.controller.generation != expectedGeneration) {
      throw StateError('源或目标SSH代次已改变，请重新选择文件；不会自动连接');
    }
    if (!directory.startsWith('/') || directory.contains('\u0000')) {
      throw StateError('粘贴目标需要远端绝对目录');
    }
    final targetId = destination.controller.id!;
    if (identical(source, destination)) {
      if (clip.cut && !_cutPastes.add(clip)) {
        throw StateError('该剪切选择正在执行，请等待完成');
      }
      return runLocalSettings(() async {
        var completed = 0;
        try {
          for (final path in clip.paths) {
            if (shouldStop?.call() ?? false) throw StateError('已停止后续文件操作');
            _checkSftpMutation(source, clip.nativeId, clip.generation);
            final targetPath = remotePath(directory, path.split('/').last);
            if (clip.cut) {
              await rust.sftpRename(
                id: clip.nativeId,
                source: path,
                destination: targetPath,
                expectedGeneration: clip.generation,
              );
            } else {
              await rust.sftpCopyOnServer(
                id: clip.nativeId,
                generation: clip.generation,
                source: path,
                destination: targetPath,
              );
            }
            completed++;
          }
          return <String>[];
        } catch (error) {
          throw StateError(
            '已完成 $completed 项远端${clip.cut ? '移动' : '复制'}；后续操作未确认，请刷新核对：${appMessage(error)}',
          );
        } finally {
          if (clip.cut) {
            _cutPastes.remove(clip);
            if (completed > 0 &&
                identical(_remoteFileClipboards[source.id], clip)) {
              final remaining = clip.paths.skip(completed).toList();
              if (remaining.isEmpty) {
                _remoteFileClipboards.remove(source.id);
              } else {
                _remoteFileClipboards[source.id] = RemoteFileSelection._(
                  source,
                  clip.nativeId,
                  clip.generation,
                  remaining,
                  cut: true,
                );
              }
              _clipboardRevision++;
            }
          }
          source.directoryCache.remove(directory);
          for (final path in clip.paths) {
            source.directoryCache.remove(
              path.substring(0, path.lastIndexOf('/')).isEmpty
                  ? '/'
                  : path.substring(0, path.lastIndexOf('/')),
            );
          }
          if (!isClosing &&
              source.controller.generation == clip.generation &&
              source.controller.connected) {
            await loadDirectory(
              source,
              source.path,
              remember: false,
              refresh: true,
            );
          }
        }
      });
    }
    final tasks = <String>[];
    if (clip.cut && !_cutPastes.add(clip)) {
      throw StateError('该剪切选择正在入队，请等待完成');
    }
    _enqueueBatches++;
    try {
      for (final path in clip.paths) {
        if (shouldStop?.call() ?? false) {
          throw StateError('已停止继续入队；已接受的任务仍由队列管理');
        }
        tasks.add(
          clip.cut
              ? await rust.enqueueRemoteMove(
                  sourceId: clip.nativeId,
                  targetId: targetId,
                  source: path,
                  destination: remotePath(directory, path.split('/').last),
                  expectedSourceGeneration: clip.generation,
                  expectedTargetGeneration: expectedGeneration,
                  allowMemoryRelay: allowMemoryRelay,
                  allowDirect: allowDirect,
                )
              : await rust.enqueueRemoteCopy(
                  sourceId: clip.nativeId,
                  targetId: targetId,
                  source: path,
                  destination: remotePath(directory, path.split('/').last),
                  allowMemoryRelay: allowMemoryRelay,
                  allowDirect: allowDirect,
                  expectedSourceGeneration: clip.generation,
                  expectedTargetGeneration: expectedGeneration,
                ),
        );
        if (tasks.length == 1) unawaited(_refreshAfterTransferMutation());
      }
      return List.unmodifiable(tasks);
    } catch (error) {
      throw RemoteFileSubmissionFailure(
        tasks,
        RemoteFileSelection._(
          clip.source,
          clip.nativeId,
          clip.generation,
          clip.paths.skip(tasks.length).toList(),
          cut: clip.cut,
        ),
        error,
      );
    } finally {
      _enqueueBatches--;
      if (clip.cut) {
        _cutPastes.remove(clip);
        if (tasks.isNotEmpty &&
            identical(_remoteFileClipboards[clip.source.id], clip)) {
          final remaining = clip.paths
              .skip(tasks.length)
              .toList(growable: false);
          final nextClipboard = remaining.isEmpty
              ? null
              : RemoteFileSelection._(
                  clip.source,
                  clip.nativeId,
                  clip.generation,
                  remaining,
                  cut: true,
                );
          if (nextClipboard == null) {
            _remoteFileClipboards.remove(clip.source.id);
          } else {
            _remoteFileClipboards[clip.source.id] = nextClipboard;
          }
          _clipboardRevision++;
          changed();
        }
      }
      await _refreshAfterTransferMutation();
    }
  }

  final transferRates = <String, TransferRate>{};
  final _rateClock = Stopwatch()..start();
  @override
  int get activeTransferCount => transferTasks.where((t) => t.busy).length;
  @override
  int get totalTransferCount => transferTasks.length;
  @override
  bool get hasTransferErrors =>
      transferTasks.any((t) => t.state == 'Partial' || t.state == 'Failed');
  Timer? _transferTimer;
  Future<void>? _transferRefresh;
  // A read begun before enqueue/stop may contain an older registry snapshot.
  // Join it first, then fetch the state after this explicit mutation.
  Future<void> _refreshAfterTransferMutation() async {
    if (isClosing) return;
    final pending = _transferRefresh;
    if (pending != null) await pending;
    if (!isClosing) await refreshTransfers();
  }

  Future<void> refreshTransfers() {
    if (isClosing) return Future.value();
    return _transferRefresh ??= _readTransfers().whenComplete(
      () => _transferRefresh = null,
    );
  }

  Future<void> _readTransfers() async {
    _transferTimer?.cancel();
    try {
      final batches = await Future.wait([
        rust.listTransferTasks(),
        rust.listRemoteCopies(),
      ]);
      final tasks = batches.expand((batch) => batch).toList();
      if (_disposed || _shutdown != null) return;
      var ratesChanged = false;
      final running = tasks
          .where((t) => t.busy && t.state == 'Running')
          .map((t) => t.id)
          .toSet();
      transferRates.removeWhere((id, _) => !running.contains(id));
      for (final task in tasks.where((t) => running.contains(t.id))) {
        ratesChanged =
            transferRates
                .putIfAbsent(task.id, TransferRate.new)
                .sample(
                  acknowledged: task.acknowledged,
                  total: task.total,
                  running: true,
                  elapsed: _rateClock.elapsed,
                ) ||
            ratesChanged;
      }
      if (!listEquals(transferTasks, tasks)) {
        final previous = transferTasks;
        transferTasks = tasks;
        for (final task in tasks.where(
          (t) =>
              t.upload &&
              !t.busy &&
              // Ending local waiting is not an observed remote mutation. It
              // must not initiate a directory refresh or need a connection.
              t.remoteMovePhase != 'UserEnded' &&
              previous.where((p) => p.id == t.id).firstOrNull?.busy != false,
        )) {
          final sourceAffected =
              task.remoteOperation == 'move' ||
              task.remoteOperation == 'relocate';
          final related = sessions
              .cast<LiveTerminalSession>()
              .where(
                (s) =>
                    s.controller.connected &&
                    s.sftpEnabled &&
                    ((s.controller.id == task.terminalId &&
                            s.controller.generation ==
                                task.terminalGeneration) ||
                        (sourceAffected &&
                            s.controller.id == task.sourceTerminalId &&
                            s.controller.generation ==
                                task.sourceTerminalGeneration)),
              )
              .toList();
          for (final session in related) {
            if (sourceAffected &&
                session.controller.id == task.sourceTerminalId) {
              final root = task.sourceRemote!;
              final parent = root.substring(0, root.lastIndexOf('/'));
              for (final key
                  in session.directories.keys
                      .where((p) => p == root || p.startsWith('$root/'))
                      .toList()) {
                session.directoryCache.remove(key);
              }
              session.directoryCache.remove(parent.isEmpty ? '/' : parent);
            }
            _track(
              loadDirectory(
                session,
                session.path,
                remember: false,
                refresh: true,
              ),
            );
          }
        }
        changed();
      } else if (ratesChanged) {
        changed();
      }
      if (_enqueueBatches > 0 || tasks.any((t) => t.busy)) {
        _transferTimer = Timer(
          const Duration(milliseconds: 200),
          () => unawaited(refreshTransfers()),
        );
      }
    } catch (error) {
      if (!_disposed) reportOperation(error);
    }
  }

  @override
  Future<String> enqueueFileTransfer(
    TerminalSession session,
    String local,
    String remote,
    bool upload, {
    int? expectedGeneration,
  }) async {
    if (_disposed || _shutdown != null) throw StateError('应用正在关闭，不能开始传输');
    final s = _connected(session);
    final generation = expectedGeneration ?? s.controller.generation;
    if (generation != s.controller.generation) {
      throw StateError('原传输SSH会话代次已变化，请重新选择文件');
    }
    final id = await rust.enqueueTransfer(
      id: s.controller.id!,
      local: local,
      remote: remote,
      upload: upload,
      expectedGeneration: generation,
    );
    await _refreshAfterTransferMutation();
    return id;
  }

  @override
  Future<T> runTransferSubmission<T>(Future<T> Function() action) {
    if (_disposed || _shutdown != null) {
      return Future.error(StateError('应用正在关闭，不能开始传输'));
    }
    _enqueueBatches++;
    final operation = Future<T>.sync(action).whenComplete(() {
      _enqueueBatches--;
    });
    _track(operation.then<void>((_) {}));
    return operation;
  }

  int _stagingReviewEpoch = 0;
  ({
    String task,
    String host,
    String ticket,
    WeakReference<LiveTerminalSession> owner,
    int native,
    int generation,
    String path,
  })?
  _stagingReview;

  Map<String, dynamic> _stagingJson(String raw) {
    if (utf8.encode(raw).length > 2 * 1024 * 1024) {
      throw StateError('暂存清单超过容量');
    }
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // Cleanup requires only the original destination, never opens a source SSH.
  // Rust independently verifies the actual address/account/fingerprint.
  LiveTerminalSession _stagingTarget(String host) {
    if (_disposed || _shutdown != null) throw StateError('应用正在关闭');
    final target = sessions
        .cast<LiveTerminalSession>()
        .where(
          (s) =>
              s.host.id == host &&
              s.controller.connected &&
              s.controller.id != null,
        )
        .firstOrNull;
    if (target == null) throw StateError('请先手动连接原目标主机；不会自动连接');
    return target;
  }

  @override
  Future<Map<String, dynamic>> stagingTasks(int offset) => runLocalSettings(
    () async =>
        _stagingJson(await rust.remoteStagingTasks(offset: offset, limit: 32)),
    reportFailure: false,
  );
  @override
  Future<Map<String, dynamic>> stagingInventory(String id, int offset) =>
      runLocalSettings(
        () async => _stagingJson(
          await rust.remoteStagingInventory(
            taskId: id,
            offset: offset,
            limit: 32,
          ),
        ),
        reportFailure: false,
      );
  @override
  Future<Map<String, dynamic>> prepareStaging(
    String id,
    String host,
    int index,
  ) {
    _stagingReview = null;
    final epoch = ++_stagingReviewEpoch;
    final target = _stagingTarget(host);
    final native = target.controller.id!,
        generation = target.controller.generation;
    return runLocalSettings(() async {
      final raw = await rust.prepareRemoteStagingCleanup(
        targetId: native,
        taskId: id,
        index: index,
      );
      if (_stagingReviewEpoch != epoch ||
          _disposed ||
          _shutdown != null ||
          !sessions.contains(target) ||
          target.controller.id != native ||
          !target.controller.connected ||
          target.controller.generation != generation) {
        throw StateError('暂存检查的原SSH会话已改变');
      }
      final view = _stagingJson(raw);
      final ticket = view['ticket'] as String, path = view['path'] as String;
      if (!path.startsWith('/') || path.contains('\u0000')) {
        throw StateError('暂存路径无效');
      }
      // One weak, one-use UI review; tab sorting/focus never substitutes another
      // connected session sharing a saved host ID. Rust remains authoritative.
      _stagingReview = (
        task: id,
        host: host,
        ticket: ticket,
        owner: WeakReference(target),
        native: native,
        generation: generation,
        path: path,
      );
      return view;
    }, reportFailure: false);
  }

  @override
  Future<void> applyStaging(
    String id,
    String host,
    String ticket,
    bool uncertain,
  ) {
    final review = _stagingReview;
    _stagingReview = null;
    ++_stagingReviewEpoch;
    final target = review?.owner.target;
    if (review == null ||
        target == null ||
        review.task != id ||
        review.host != host ||
        review.ticket != ticket ||
        !sessions.contains(target) ||
        !target.controller.connected ||
        target.controller.id != review.native ||
        target.controller.generation != review.generation) {
      return Future.error(StateError('暂存清理确认已过期，请重新检查原会话'));
    }
    return runLocalSettings(() async {
      await rust.applyRemoteStagingCleanup(
        targetId: review.native,
        taskId: id,
        ticket: ticket,
        allowUncertain: uncertain,
      );
      await _refreshAfterTransferMutation();
      if (!_disposed &&
          _shutdown == null &&
          sessions.contains(target) &&
          target.controller.connected &&
          target.controller.id == review.native &&
          target.controller.generation == review.generation) {
        final slash = review.path.lastIndexOf('/');
        final parent = slash == 0 ? '/' : review.path.substring(0, slash);
        target.directoryCache.remove(parent);
        if (identical(focus, target) &&
            sidebar &&
            !queueMaximized &&
            target.sftpEnabled &&
            target.path == parent) {
          // Cleanup already succeeded. A subsequent listing error is a separate
          // refresh failure, never a reason to send the DELETE ticket again.
          _track(loadDirectory(target, parent, remember: false, refresh: true));
        }
      }
    }, reportFailure: false);
  }

  @override
  Future<Map<String, dynamic>> prepareStagingEnd(String id) {
    _stagingReview = null;
    ++_stagingReviewEpoch;
    return runLocalSettings(
      () async => _stagingJson(await rust.prepareRemoteStagingEnd(taskId: id)),
      reportFailure: false,
    );
  }

  @override
  Future<void> endStagingWait(String id, String ticket) =>
      runLocalSettings(() async {
        await rust.endRemoteStagingWait(taskId: id, ticket: ticket);
        await _refreshAfterTransferMutation();
      }, reportFailure: false);

  (LiveTerminalSession, LiveTerminalSession) _remoteTaskPair(
    jobs.TransferTaskView task, {
    TransferConnectionRef? sourceConnection,
    TransferConnectionRef? targetConnection,
  }) {
    if (_disposed || _shutdown != null) throw StateError('应用正在关闭');
    LiveTerminalSession? pick(
      int? native,
      int? generation,
      String? host,
      TransferConnectionRef? chosen,
    ) {
      if (chosen != null) {
        if (!chosen.valid(sessions.cast<LiveTerminalSession>(), host)) {
          throw StateError('所选传输连接已改变，请重新选择原任务会话');
        }
        return chosen.session;
      }
      return chooseTransferConnection(
        sessions.cast<LiveTerminalSession>(),
        focus: focus as LiveTerminalSession?,
        hostId: host,
        preferredId: native,
        preferredGeneration: generation,
      );
    }

    final source = pick(
      task.sourceTerminalId,
      task.sourceTerminalGeneration,
      task.sourceHostId,
      sourceConnection,
    );
    final target = pick(
      task.terminalId,
      task.terminalGeneration,
      task.hostId,
      targetConnection,
    );
    if (source == null || target == null) {
      throw StateError('请先手动连接任务原来的源和目标主机；不会自动连接');
    }
    return (source, target);
  }

  Future<remote.RemoteMoveEndReview> prepareRemoteMoveEnd(
    jobs.TransferTaskView task,
  ) {
    if (_disposed || _shutdown != null) throw StateError('应用正在关闭');
    final operation = task.remoteOperation == 'relocate'
        ? rust.prepareSourceRetirementEnd(taskId: task.id)
        : rust.prepareRemoteMoveEnd(taskId: task.id);
    _track(operation.then<void>((_) {}));
    return operation;
  }

  Future<void> endRemoteMoveWait(jobs.TransferTaskView task, String ticket) {
    if (_disposed || _shutdown != null) throw StateError('应用正在关闭');
    final operation = () async {
      if (task.remoteOperation == 'relocate') {
        await rust.endSourceRetirementWait(taskId: task.id, ticket: ticket);
      } else {
        await rust.endRemoteMoveWait(taskId: task.id, ticket: ticket);
      }
      await _refreshAfterTransferMutation();
    }();
    _track(operation);
    return operation;
  }

  Future<remote.RemoteMoveInspection> inspectRemoteMove(
    jobs.TransferTaskView task,
  ) {
    final (source, target) = _remoteTaskPair(task);
    final operation = task.remoteOperation == 'relocate'
        ? rust.inspectSourceRetirement(
            sourceId: source.controller.id!,
            targetId: target.controller.id!,
            taskId: task.id,
          )
        : rust.inspectRemoteMove(
            sourceId: source.controller.id!,
            targetId: target.controller.id!,
            taskId: task.id,
          );
    // Keep the Native request alive through application shutdown; the original
    // future still delivers its result/error to the owning dialog.
    _track(operation.then<void>((_) {}));
    return operation;
  }

  Future<void> acknowledgeRemoteMove(
    jobs.TransferTaskView task,
    String ticket,
  ) {
    final (source, target) = _remoteTaskPair(task);
    final operation = () async {
      await rust.acknowledgeRemoteMove(
        sourceId: source.controller.id!,
        targetId: target.controller.id!,
        taskId: task.id,
        ticket: ticket,
      );
      await _refreshAfterTransferMutation();
    }();
    _track(operation);
    return operation;
  }

  Future<void> controlTransfer(
    jobs.TransferTaskView task,
    String action, {
    int? node,
    String? rename,
    TransferConnectionRef? sourceConnection,
    TransferConnectionRef? targetConnection,
  }) {
    if (isClosing) return Future.error(StateError('应用正在关闭'));
    final work = _controlTransfer(
      task,
      action,
      node: node,
      rename: rename,
      sourceConnection: sourceConnection,
      targetConnection: targetConnection,
    );
    _track(work, reportFailure: () => false);
    return work;
  }

  Future<void> _controlTransfer(
    jobs.TransferTaskView task,
    String action, {
    int? node,
    String? rename,
    TransferConnectionRef? sourceConnection,
    TransferConnectionRef? targetConnection,
  }) async {
    if (isClosing) throw StateError('应用正在关闭');
    if (task.sourceRemote != null) {
      if (action == 'pause' || action == 'cancel') {
        await rust.stopRemoteCopy(taskId: task.id, cancel: action == 'cancel');
      } else {
        final (source, target) = _remoteTaskPair(
          task,
          sourceConnection: sourceConnection,
          targetConnection: targetConnection,
        );
        await rust.resumeRemoteCopy(
          sourceId: source.controller.id!,
          targetId: target.controller.id!,
          sourceGeneration: source.controller.generation,
          targetGeneration: target.controller.generation,
          taskId: task.id,
          node: node,
          decision: task.remoteOperation == 'move' && action == 'retry'
              ? 'continue'
              : action == 'continue' && task.failed + task.conflicts > 0
              ? 'retry'
              : action,
          rename: rename,
        );
      }
      await _refreshAfterTransferMutation();
      return;
    }
    if (action == 'pause' || action == 'cancel') {
      await rust.stopTransfer(taskId: task.id, cancel: action == 'cancel');
    } else {
      if (targetConnection != null &&
          !targetConnection.valid(
            sessions.cast<LiveTerminalSession>(),
            task.hostId,
          )) {
        throw StateError('所选传输连接已改变，请重新选择原任务会话');
      }
      final s =
          targetConnection?.session ??
          chooseTransferConnection(
            sessions.cast<LiveTerminalSession>(),
            focus: focus as LiveTerminalSession?,
            hostId: task.hostId,
            preferredId: task.terminalId,
            preferredGeneration: task.terminalGeneration,
          );
      if (s == null || !s.controller.connected) {
        throw StateError('请先手动连接原主机，在该会话的“全部任务”中继续；不会自动连接');
      }
      await rust.resumeTransfer(
        id: s.controller.id!,
        generation: s.controller.generation,
        taskId: task.id,
        node: node,
        decision: action == 'continue' && task.failed + task.conflicts > 0
            ? 'retry'
            : action,
        rename: rename,
      );
    }
    await _refreshAfterTransferMutation();
  }

  Future<void> clearEndedTasks() {
    if (isClosing) return Future.error(StateError('应用正在关闭'));
    final work = () async {
      await rust.clearEndedTransfers();
      if (isClosing) return;
      await rust.clearEndedRemoteCopies();
      await _refreshAfterTransferMutation();
    }();
    _track(work, reportFailure: () => false);
    return work;
  }

  Future<bool> Function(DemoHost, rust.BridgeEvent)? confirmHostKey;
  @override
  bool get isMock => false;
  @override
  bool get hasActiveSessions =>
      hasRetiringSessions ||
      _hostTest != null ||
      transferTasks.any((t) => t.busy) ||
      sessions.cast<LiveTerminalSession>().any(
        (s) =>
            s.controller.connected ||
            s.controller.phase == 'Connecting' ||
            (s.controller.isClosing && !s.controller.shutdownComplete),
      );
  DemoHost _host(rust.HostConfig h) => DemoHost(
    h.id,
    h.name,
    h.address,
    _groups.where((g) => g.id == h.groupId).firstOrNull?.name ?? '未分组',
    user: h.username,
    port: h.port,
    auth: h.privateKey ? '私钥' : '密码',
    favorite: h.favorite,
    note: h.note,
    credentialSet: h.credentialSet,
    openSftp: h.openSftp,
    followOsc7: h.followOsc7 ?? false,
    agentForwarding: h.agentForwarding ?? false,
    tmuxEnabled: h.tmuxEnabled ?? false,
    shellIntegration: h.shellIntegration ?? false,
    jumpHostId: h.jumpHostId,
    timeoutSeconds: h.timeoutSeconds,
    keepaliveSeconds: h.keepaliveSeconds,
    keepaliveFailures: h.keepaliveFailures,
    useNetworkDefaults: h.useNetworkDefaults ?? false,
    keepaliveResponseSeconds: h.keepaliveResponseSeconds,
    proxy: h.proxy == null
        ? null
        : DemoProxy(
            socks5: h.proxy!.socks5,
            address: h.proxy!.address,
            port: h.proxy!.port,
            authenticate: h.proxy!.authenticate,
            credentialSet: h.proxy!.credentialSet ?? false,
          ),
  );
  rust.HostConfig _record(
    DemoHost h, {
    bool secretPresent = false,
    bool proxySecretPresent = false,
  }) {
    return rust.HostConfig(
      id: h.id,
      name: h.name,
      address: h.address,
      port: h.port,
      username: h.user,
      privateKey: h.auth == '私钥',
      groupId:
          _groups.where((g) => g.name == h.group).firstOrNull?.id ??
          'group-default',
      favorite: h.favorite,
      note: h.note,
      credentialSet: h.credentialSet || secretPresent,
      timeoutSeconds: h.timeoutSeconds,
      keepaliveSeconds: h.keepaliveSeconds,
      keepaliveFailures: h.keepaliveFailures,
      useNetworkDefaults: h.useNetworkDefaults,
      keepaliveResponseSeconds: h.keepaliveResponseSeconds,
      openSftp: h.openSftp,
      followOsc7: h.followOsc7,
      agentForwarding: h.agentForwarding,
      tmuxEnabled: h.tmuxEnabled,
      shellIntegration: h.shellIntegration,
      jumpHostId: h.jumpHostId,
      proxy: h.proxy == null
          ? null
          : rust.HostProxyConfig(
              socks5: h.proxy!.socks5,
              address: h.proxy!.address,
              port: h.proxy!.port,
              authenticate: h.proxy!.authenticate,
              credentialSet: h.proxy!.credentialSet || proxySecretPresent,
            ),
    );
  }

  int _catalogEpoch = 0;
  Future<void> load() {
    if (isClosing) return Future.error(StateError('应用正在关闭，不能载入主机目录'));
    final work = _loadCatalog(++_catalogEpoch);
    _track(work, reportFailure: () => false);
    return work;
  }

  Future<void> _loadCatalog(int epoch) async {
    final atomic = store is HostCatalogStore
        ? await (store as HostCatalogStore).snapshot()
        : null;
    final records = atomic?.hosts ?? await store.hosts();
    final data = atomic == null
        ? await Future.wait([store.groups(), store.drafts()])
        : [atomic.groups, atomic.drafts];
    if (_disposed || _shutdown != null || epoch != _catalogEpoch) return;
    try {
      await reloadPaletteShortcut();
    } catch (error) {
      if (!_disposed && epoch == _catalogEpoch) reportOperation(error);
    }
    if (_disposed || _shutdown != null || epoch != _catalogEpoch) return;
    if (atomic != null &&
        _paletteShortcut != null &&
        atomic.vaultScope != _paletteShortcut!.vaultScope) {
      throw StateError('读取期间配置库已改变，未发布旧主机目录');
    }
    for (final s in sessions.cast<LiveTerminalSession>()) {
      final next = records.where((h) => h.id == s.host.id).firstOrNull;
      if ((next?.followOsc7 ?? false) &&
          !(_records[s.host.id]?.followOsc7 ?? false)) {
        s.followedDirectoryVersion = -1;
      }
    }
    _groups
      ..clear()
      ..addAll(data[0].cast<rust.HostGroupConfig>());
    groups
      ..clear()
      ..addAll(['全部主机', '收藏', ..._groups.map((g) => g.name)]);
    _records
      ..clear()
      ..addEntries(records.map((h) => MapEntry(h.id, h)));
    hosts
      ..clear()
      ..addAll(records.map(_host));
    _draftRecords
      ..clear()
      ..addEntries(
        data[1].cast<rust.HostConfig>().map((h) => MapEntry(h.id, h)),
      );
    _drafts
      ..clear()
      ..addEntries(_draftRecords.values.map((h) => MapEntry(h.id, _host(h))));
    unawaited(_loadRecents(epoch));
    unawaited(_loadSftpSortPrefs());
    changed();
  }

  /// Restores the device-local recent-host list after the encrypted catalog
  /// loads; unknown IDs (deleted hosts) simply do not surface.
  Future<void> _loadRecents(int epoch) async {
    try {
      final ids = await rust.loadRecentHosts();
      if (_disposed ||
          _shutdown != null ||
          epoch != _catalogEpoch ||
          ids.isEmpty) {
        return;
      }
      recent
        ..clear()
        ..addAll(ids.where(_records.containsKey));
      changed();
    } catch (_) {
      // Convenience ordering only; never blocks the catalog display.
    }
  }

  /// Persists one host open into the device-local recent list.
  void _recordRecent(DemoHost host) {
    if (_disposed || _shutdown != null || !_records.containsKey(host.id)) {
      return;
    }
    final id = host.id, epoch = _catalogEpoch;
    _track(
      rust.recordRecentHost(hostId: id).then<void>((ids) {
        if (_disposed || _shutdown != null || epoch != _catalogEpoch) return;
        recent
          ..clear()
          ..addAll(ids.where(_records.containsKey));
        changed();
      }),
      reportFailure: () => false,
    );
  }

  @override
  String nextId() => store.newId();
  @override
  TerminalSession createSession(String id, DemoHost host) =>
      LiveTerminalSession(id, host.snapshot(), backendFactory());
  @override
  void openHost(DemoHost host) => _openHost(host);

  DemoHost _temporaryHost(DemoHost previous, once.TemporarySource source) =>
      previous.snapshot()
        ..name = source.name
        ..address = source.address
        ..port = source.port
        ..user = source.username
        ..auth = source.privateKey ? '私钥' : '密码'
        ..credentialSet = source.credentialPresent
        ..shellIntegration = false;

  @override
  Future<void> openTemporaryHost(DemoHost host) async {
    if (_shutdown != null || _disposed || _temporaryDialogOpen) return;
    _temporaryDialogOpen = true;
    TemporaryConnectionInput? input;
    try {
      final source = await rust.temporaryConnectionSource(profileId: host.id);
      if (_shutdown != null || _disposed) return;
      final current = _temporaryHost(host, source);
      input = await requestTemporaryParameters?.call(current, null);
      if (input == null) return;
      if (_shutdown != null || _disposed || !_records.containsKey(host.id)) {
        return;
      }
      _openHost(current, temporarySource: source, temporaryInput: input);
      input = null; // Ownership transfers to that original session only.
    } catch (error) {
      reportOperation(error);
    } finally {
      input?.forgetSecrets();
      _temporaryDialogOpen = false;
    }
  }

  Future<void> _confirmTemporaryReconnect(LiveTerminalSession s) async {
    final id = s.controller.id, generation = s.controller.generation;
    bool current() =>
        !_disposed &&
        _shutdown == null &&
        sessions.contains(s) &&
        s.controller.id == id &&
        s.controller.generation == generation &&
        !s.controller.connected &&
        s.controller.phase != 'Connecting';
    if (!current()) return;
    final source = await rust.temporaryConnectionSource(profileId: s.host.id);
    if (!current()) return;
    final input = await requestTemporaryParameters?.call(
      _temporaryHost(s.host, source),
      s.temporaryTarget,
    );
    if (input == null) return;
    if (!current()) {
      input.forgetSecrets();
      return;
    }
    s.pendingTemporarySource = source;
    s.pendingTemporaryInput = input;
    s.temporaryTarget = input.target;
    try {
      await s.controller.connect(s.host.id);
    } finally {
      s.clearTemporaryInput();
    }
  }

  void _openHost(
    DemoHost host, {
    once.TemporarySource? temporarySource,
    TemporaryConnectionInput? temporaryInput,
  }) {
    if (_shutdown != null) {
      temporaryInput?.forgetSecrets();
      return;
    }
    if (!_records.containsKey(host.id)) throw StateError('请先正式保存主机配置');
    super.openHost(host);
    _recordRecent(host);
    final s = focus! as LiveTerminalSession;
    unawaited(typography.ensureHost(host.id));
    if (temporarySource != null && temporaryInput != null) {
      s.temporaryConnection = true;
      s.pendingTemporarySource = temporarySource;
      s.pendingTemporaryInput = temporaryInput;
      s.temporaryTarget = temporaryInput.target;
      s.controller.reconnectRequest = () => _confirmTemporaryReconnect(s);
      s.controller.connectRequest = (id, profileId) async {
        final source = s.pendingTemporarySource,
            input = s.pendingTemporaryInput;
        if (source == null || input == null) {
          throw StateError('本次覆盖已用完，请重新确认连接参数');
        }
        s.pendingTemporarySource = null;
        s.pendingTemporaryInput = null;
        try {
          final target = input.target;
          await rust.connectTerminalOnce(
            id: id,
            source: source,
            options: rust.TemporaryConnectionOptions(
              address: target.address,
              port: target.port,
              username: target.username,
              authentication: target.auth.index,
            ),
            password: input.password,
            keyFile: input.keyFile,
            passphrase: input.passphrase,
          );
        } finally {
          input.forgetSecrets();
        }
      };
      tabById(focusedGroup!.selectedId)?.name = '${host.name} · 本次';
    }
    s.controller.prepareConnection = () {
      final current = _records[s.host.id];
      if (current == null) throw StateError('主机配置已删除，请先保存配置后再连接');
      final target = s.temporaryConnection
          ? _temporaryHost(
              _host(current),
              s.pendingTemporarySource ?? (throw StateError('请重新确认本次临时覆盖')),
            )
          : _host(current);
      if (s.temporaryConnection) {
        final selected =
            s.pendingTemporaryInput?.target ?? (throw StateError('本次覆盖凭据已释放'));
        target.address = selected.address;
        target.port = selected.port;
        target.user = selected.username;
        target.name = '${target.name} · 本次';
        if (selected.auth != TemporaryAuth.saved) {
          target.auth = selected.auth == TemporaryAuth.privateKey ? '私钥' : '密码';
        }
      }
      s.host
        ..name = target.name
        ..address = target.address
        ..user = target.user
        ..port = target.port
        ..auth = target.auth
        ..openSftp = target.openSftp
        ..followOsc7 = target.followOsc7;
      s.host
        ..timeoutSeconds = target.timeoutSeconds
        ..keepaliveSeconds = target.keepaliveSeconds
        ..keepaliveFailures = target.keepaliveFailures;
      s.host
        ..useNetworkDefaults = target.useNetworkDefaults
        ..keepaliveResponseSeconds = target.keepaliveResponseSeconds
        ..agentForwarding = target.agentForwarding
        ..tmuxEnabled = target.tmuxEnabled
        ..shellIntegration = target.shellIntegration;
      s.host.proxy = target.proxy;
      s.controller.connectionLabel =
          '${target.user}@${target.address}:${target.port}';
    };
    var observed = '', observedDirectory = -1;
    String? observedReconnectNotice;
    s.changedListener = () {
      if (_disposed || !sessions.contains(s)) return;
      // 2026-11-05 revision (default off): one automatic reconnect attempt
      // per connection generation after an unexpected drop; temporary
      // connections never reconnect implicitly.
      final connected = s.controller.connected;
      if (s.wasConnected && !connected && !s.temporaryConnection) {
        // Brief delay before the single attempt: avoids hammering a
        // transport that is still retiring (the 2026-11-06 log's rejected
        // auto attempt was the user's own server restart — failure then is
        // correct and manual retry stays available).
        Timer(const Duration(seconds: 3), () {
          if (!_disposed && _shutdown == null && sessions.contains(s)) {
            unawaited(_autoReconnectIfEnabled(s));
          }
        });
      }
      s.wasConnected = connected;
      if (observedDirectory != s.controller.directoryReportVersion) {
        observedDirectory = s.controller.directoryReportVersion;
        if (identical(_followSubject, s) && _followBusy) {
          _cancelDirectoryFollow();
        }
        _scheduleDirectoryFollow(s);
      }
      if (observedReconnectNotice != s.controller.reconnectNotice) {
        observedReconnectNotice = s.controller.reconnectNotice;
        if (observedReconnectNotice != null) {
          _track(_refreshAfterTransferMutation());
        }
      }
      final state =
          '${s.controller.reconnectNotice}/${s.controller.phase}/${s.controller.generation}/${s.controller.error}/${s.controller.tmuxReadonly}';
      if (state == observed) return;
      observed = state;
      s.disconnected = !s.controller.connected;
      s.connectionGeneration = s.controller.generation;
      if (s.controller.connected &&
          s.sftpGeneration != s.controller.generation) {
        s.sftpGeneration = s.controller.generation;
        // A manually reconnected host can now refer to a different endpoint.
        // Never expose the previous server's cached files in that generation.
        s.directoryCache.clear();
        if (s.sftpEnabled || (_records[s.host.id]?.openSftp ?? false)) {
          _track(_restoreSftp(s));
        }
      }
      changed();
    };
    s.controller.addListener(s.changedListener!);
    s.controller.chooseTmux = (prompt) async =>
        await requestTmuxChoice?.call(s, prompt);
    s.controller.confirmHostKey = (event) async =>
        await confirmHostKey?.call(s.host, event) ?? false;
    _track(_start(s));
  }

  Future<void> _start(LiveTerminalSession s) async {
    try {
      await s.controller.start();
      if (_shutdown != null || !sessions.contains(s)) {
        s.clearTemporaryInput();
        await s.controller.shutdown();
        return;
      }
      await s.controller.connect(
        s.host.id,
        label: '${s.host.user}@${s.host.address}:${s.host.port}',
      );
      s.followedDirectoryVersion = -1;
      _scheduleDirectoryFollow(s);
    } catch (error) {
      s.controller.report(error);
    } finally {
      s.clearTemporaryInput();
    }
  }

  Future<void> _autoReconnectIfEnabled(LiveTerminalSession s) async {
    final generation = s.controller.generation;
    if (s.autoReconnectAttempted == generation ||
        _disposed ||
        _shutdown != null ||
        !sessions.contains(s)) {
      return;
    }
    try {
      final defaults = await rust.sshNetworkDefaults();
      if (_disposed ||
          _shutdown != null ||
          !sessions.contains(s) ||
          s.controller.connected ||
          !defaults.autoReconnect ||
          s.autoReconnectAttempted == generation) {
        return;
      }
      s.autoReconnectAttempted = generation;
      AppRunLog.instance.event(
        AppLogEvent.autoReconnectTriggered,
        terminal: s.controller.id,
        generation: generation,
      );
      await s.controller.connect(s.host.id);
    } catch (error) {
      AppRunLog.instance.event(
        AppLogEvent.autoReconnectDisabled,
        terminal: s.controller.id,
        generation: generation,
        error: error,
      );
    }
  }

  final localEdits = LocalEditRegistry();

  final _sftpSortPrefs = <String, (int, bool)>{};
  bool _sftpSortLoaded = false;

  @override
  (int, bool)? rememberedSort(String hostId) => _sftpSortPrefs[hostId];

  @override
  void rememberSort(String hostId, int column, bool ascending) {
    if (_disposed || _shutdown != null) return;
    _sftpSortPrefs[hostId] = (column, ascending);
    _track(
      rust.recordSftpSortPref(
        hostId: hostId,
        column: column,
        ascending: ascending,
      ),
      reportFailure: () => false,
    );
  }

  final _sftpColumnPrefs = <String, SftpColumnLayout>{};

  @override
  SftpColumnLayout? rememberedColumns(String hostId) =>
      _sftpColumnPrefs[hostId];

  @override
  void rememberColumns(String hostId, SftpColumnLayout layout) {
    if (_disposed || _shutdown != null) return;
    _sftpColumnPrefs[hostId] = layout;
    _track(
      rust.recordSftpColumnPref(
        hostId: hostId,
        order: layout.order,
        hidden: layout.hidden.toList(),
        widths: [
          for (final entry in layout.widths.entries)
            if (entry.value.isFinite) (entry.key, entry.value.round()),
        ],
      ),
      reportFailure: () => false,
    );
  }

  Future<void> _loadSftpColumnPrefs() async {
    if (_sftpSortLoaded || _disposed || _shutdown != null) return;
    try {
      final entries = await rust.loadSftpColumnPrefs();
      if (_disposed || _shutdown != null) return;
      for (final e in entries) {
        if (!_sftpColumnPrefs.containsKey(e.hostId)) {
          _sftpColumnPrefs[e.hostId] = SftpColumnLayout(
            order: e.order,
            hidden: e.hidden.toSet(),
            widths: {
              for (final (id, w) in e.widths)
                if (w > 0) id: w.toDouble(),
            },
          );
        }
      }
    } catch (_) {
      // Preference loading is best-effort; defaults apply on any failure.
    }
  }

  Future<void> _loadSftpSortPrefs() async {
    if (_sftpSortLoaded || _disposed || _shutdown != null) return;
    _sftpSortLoaded = true;
    unawaited(_loadSftpColumnPrefs());
    try {
      final entries = await rust.loadSftpSortPrefs();
      if (_disposed || _shutdown != null) return;
      _sftpSortPrefs
        ..clear()
        ..addEntries(
          entries.map((e) => MapEntry(e.hostId, (e.column, e.ascending))),
        );
      changed();
    } catch (_) {
      // Convenience only; the default sort stays.
    }
  }

  final _sftpLastDirs = <String, String>{};
  bool _sftpLastDirsLoaded = false;
  Timer? _sftpLastDirFlush;

  Future<void> _loadSftpLastDirs() async {
    if (_sftpLastDirsLoaded || _disposed || _shutdown != null) return;
    _sftpLastDirsLoaded = true;
    try {
      final entries = await rust.loadSftpLastDirs();
      if (_disposed || _shutdown != null) return;
      _sftpLastDirs
        ..clear()
        ..addEntries(entries.map((e) => MapEntry(e.hostId, e.path)));
    } catch (_) {
      // Convenience only; failures fall back to the default start directory.
    }
  }

  void _rememberSftpLastDir(LiveTerminalSession s) {
    final host = s.host.id, path = s.path;
    if (path.isEmpty || !path.startsWith('/')) return;
    _sftpLastDirs[host] = path;
    _sftpLastDirFlush?.cancel();
    _sftpLastDirFlush = Timer(const Duration(seconds: 2), () {
      if (_disposed || _shutdown != null) return;
      _track(
        rust.recordSftpLastDir(hostId: host, path: path),
        reportFailure: () => false,
      );
    });
  }

  Future<void> _restoreSftp(LiveTerminalSession s) async {
    try {
      await _loadSftpLastDirs();
      final restore =
          sftpView.value?.settings.restoreLastDirectory ??
          sftpView.confirmed?.settings.restoreLastDirectory ??
          false;
      final remembered = _sftpLastDirs[s.host.id];
      if (restore && remembered != null && s.controller.connected) {
        await loadDirectory(s, remembered, remember: false);
        return;
      }
      await loadDirectory(s, s.path, remember: false, fromOsc7: true);
    } catch (error) {
      s.sftpError = 'SFTP 初始化失败：$error';
      changed();
    }
  }

  void _track(Future<void> work, {bool Function()? reportFailure}) {
    final monitored = work.catchError((Object error) {
      if (reportFailure?.call() ?? true) reportOperation(error);
    });
    _pending.add(monitored);
    unawaited(monitored.whenComplete(() => _pending.remove(monitored)));
  }

  /// Explicit local configuration operations outlive their settings page; exit
  /// waits for their actual native ACK through the existing pending registry.
  Future<T> runLocalSettings<T>(
    Future<T> Function() action, {
    bool reportFailure = true,
  }) {
    if (_disposed || _shutdown != null) {
      return Future.error(StateError('应用正在关闭，不能开始配置操作'));
    }
    final operation = action();
    _track(operation.then<void>((_) {}), reportFailure: () => reportFailure);
    return operation;
  }

  @override
  Future<DemoHost> persistHost(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async {
    final saved = await store.save(
      _record(host, secretPresent: secret != null),
      secret,
      passphrase,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
    );
    _catalogEpoch++;
    _records[saved.id] = saved;
    _draftRecords.remove(saved.id);
    _drafts.remove(saved.id);
    final h = _host(saved);
    super.saveHost(h);
    return h;
  }

  @override
  Future<void> persistDraft(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async {
    final record = _record(
      host,
      secretPresent: secret != null,
      proxySecretPresent: proxyUsername != null && proxyPassword != null,
    );
    await store.draft(
      record,
      secret,
      passphrase,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
    );
    _catalogEpoch++;
    _draftRecords[host.id] = record;
    _drafts[host.id] = _host(record);
    changed();
  }

  KeyDetails _keyDetails(rust.HostKeyInfo key) =>
      KeyDetails(key.publicKey, key.fingerprint, key.algorithm);
  @override
  Future<KeyDetails> prepareKey(
    DemoHost host, {
    String? path,
    String? passphrase,
  }) async {
    final key = path == null
        ? await store.generate(_record(host), passphrase)
        : await store.importKey(_record(host), path, passphrase);
    final saved = _keyDetails(key);
    try {
      await load();
    } catch (error) {
      throw KeyPreparationRefreshFailure(saved, error);
    }
    return saved;
  }

  @override
  Future<KeyDetails> publicKey(String id) async =>
      _keyDetails(await store.publicKey(id));
  @override
  Future<void> exportKey(String id, String path, String masterPassword) =>
      store.exportKey(id, path, masterPassword);
  @override
  Future<void> exportPublicKey(String id, String path) =>
      store.exportPublicKey(id, path);

  @override
  DemoHost? recoveredDraft(String id) => _drafts[id];
  @override
  List<DemoHost> get recoverableDrafts => _drafts.values.toList();
  @override
  Future<void> discardDraft(String id) async {
    await store.discard(id);
    _draftRecords.remove(id);
    _drafts.remove(id);
    changed();
  }

  @override
  Future<DemoHost> copyHost(DemoHost host) async {
    final copy = await store.copy(host.id);
    _draftRecords[copy.id] = copy;
    final h = _host(copy);
    _drafts[h.id] = h;
    changed();
    return h;
  }

  @override
  Future<void> deleteHosts(Set<String> ids) async {
    await store.delete(ids.toList());
    for (final id in ids) {
      _records.remove(id);
      _drafts.remove(id);
      _draftRecords.remove(id);
    }
    await super.deleteHosts(ids);
  }

  LiveTerminalSession _connected(TerminalSession session) {
    final s = session as LiveTerminalSession;
    if (!sessions.contains(s) ||
        !s.controller.connected ||
        s.controller.id == null) {
      throw StateError('关联 SSH 会话未连接');
    }
    return s;
  }

  String remotePath(String directory, String name) =>
      '${directory == '/' ? '' : directory}/$name';

  @override
  Future<RemoteRelativePaths> relativeRemotePaths(
    TerminalSession source,
    List<String> paths, {
    int? expectedRevision,
  }) {
    final session = _connected(source);
    final id = session.controller.id!,
        generation = session.controller.generation;
    final frozen = List<String>.unmodifiable(paths);
    if (frozen.isEmpty || frozen.length > 1024) {
      return Future.error(StateError('相对路径最多1024项，请分批复制'));
    }
    var bytes = 0;
    for (final path in frozen) {
      bytes += utf8.encode(path).length;
      if (bytes > 1024 * 1024) {
        return Future.error(StateError('路径数据超过1MiB，请分批复制'));
      }
    }
    return runLocalSettings(() async {
      final value = await rust.terminalRelativePaths(
        id: id,
        generation: generation,
        expectedDirectoryRevision: expectedRevision,
        paths: frozen,
      );
      if (_disposed ||
          _shutdown != null ||
          !sessions.contains(session) ||
          session.controller.id != id ||
          session.controller.generation != generation ||
          !session.controller.connected) {
        throw StateError('原路径所属连接已结束，未复制到其他会话');
      }
      return RemoteRelativePaths(value.directoryRevision, value.paths);
    }, reportFailure: false);
  }

  Future<void> locateTerminalPath(TerminalSession session, String text) {
    final s = _connected(session);
    final id = s.controller.id!, generation = s.controller.generation;
    final request = ++s.pathLocationEpoch, directoryEpoch = s.directoryEpoch;
    void check(int expectedDirectoryEpoch) {
      if (_disposed ||
          _shutdown != null ||
          !sessions.contains(s) ||
          !s.controller.connected ||
          s.controller.id != id ||
          s.controller.generation != generation ||
          s.pathLocationEpoch != request ||
          s.directoryEpoch != expectedDirectoryEpoch) {
        throw StateError('原会话或目录已改变；未定位到其他会话');
      }
    }

    final operation = () async {
      check(directoryEpoch);
      // Only an explicit local menu action reaches this metadata request.
      final entry = await rust.sftpLocateTerminalPath(
        id: id,
        generation: generation,
        text: text,
      );
      check(directoryEpoch);
      final folder = entry.directory && !entry.symlink;
      final parent = entry.path.substring(0, entry.path.lastIndexOf('/'));
      final directory = folder
          ? entry.path
          : parent.isEmpty
          ? '/'
          : parent;
      await loadDirectory(s, directory);
      check(directoryEpoch + 1);
      if (s.path != directory) throw StateError('目录尚未成功读取；未发布文件选择');
      s.pendingFileLocation = RemoteFileLocation(
        directory,
        folder ? null : entry.path,
        generation,
      );
      if (identical(focus, s)) sidebar = true;
      changed();
    }();
    _track(operation);
    return operation;
  }

  @override
  Future<List<PathBookmark>> listPathBookmarks(TerminalSession session) async =>
      (await rust.listSftpBookmarks(hostId: session.host.id))
          .map((b) => PathBookmark(b.id, b.name, b.path, b.hostId))
          .toList();
  @override
  Future<void> savePathBookmark(
    TerminalSession session, {
    required String name,
    required String path,
    required bool global,
    String? id,
  }) async {
    await rust.saveSftpBookmark(
      value: rust.SftpBookmark(
        id: id ?? '',
        name: name,
        path: path,
        hostId: global ? null : session.host.id,
      ),
    );
  }

  @override
  Future<void> deletePathBookmark(String id) =>
      rust.deleteSftpBookmark(bookmarkId: id);
  @override
  Future<void> loadDirectory(
    TerminalSession session,
    String path, {
    bool remember = true,
    bool fromOsc7 = false,
    bool refresh = false,
  }) async {
    final s = _connected(session);
    if (!fromOsc7) {
      if (identical(_followSubject, s)) _cancelDirectoryFollow();
      s.followedDirectoryVersion = s.controller.directoryReportVersion;
    }
    // WinSCP-style session cache: this connection's earlier listings are
    // reused for navigation. Explicit refresh, mutations and a new connection
    // generation always reload from the server.
    if (!refresh &&
        !fromOsc7 &&
        s.controller.connected &&
        s.directoryCacheGeneration == s.connectionGeneration &&
        s.directoryCache.files.containsKey(path)) {
      if (remember && s.path != path) {
        s.back.add(s.path);
        s.forward.clear();
      }
      s.path = path;
      AppRunLog.instance.event(
        AppLogEvent.sftpDirectoryCacheHit,
        terminal: s.controller.id,
        generation: s.controller.generation,
      );
      changed();
      return;
    }
    final epoch = ++s.directoryEpoch;
    s.pendingFileLocation = null;
    final generation = s.controller.generation;
    s.loadingDirectory = true;
    s.sftpError = null;
    changed();
    final timingStart = DateTime.now();
    try {
      final result = await directoryReader.read(
        id: s.controller.id!,
        generation: generation,
        request: epoch,
        path: path,
        isCurrent: () =>
            !_disposed &&
            _shutdown == null &&
            s.directoryEpoch == epoch &&
            sessions.contains(s) &&
            s.controller.generation == generation &&
            s.controller.connected,
      );
      if (result == null) return;
      if (remember && s.path != result.path) {
        s.back.add(s.path);
        s.forward.clear();
      }
      s.path = result.path;
      s.sftpEnabled = true;
      s.directoryCacheGeneration = s.connectionGeneration;
      s.directoryCache.store(result);
      if (session is LiveTerminalSession) {
        _rememberSftpLastDir(session);
      }
      AppRunLog.instance.event(
        AppLogEvent.sftpDirectoryLoaded,
        terminal: s.controller.id,
        generation: generation,
        count: result.files.length,
      );
      AppRunLog.instance.event(
        AppLogEvent.sftpDirectoryTiming,
        terminal: s.controller.id,
        generation: generation,
        fields: {
          'durationMs': DateTime.now().difference(timingStart).inMilliseconds,
          'result': 'loaded',
        },
      );
    } catch (error) {
      AppRunLog.instance.event(
        AppLogEvent.sftpDirectoryFailed,
        terminal: s.controller.id,
        generation: generation,
        error: error,
      );
      if (s.directoryEpoch == epoch) s.sftpError = '目录读取失败：$error';
      rethrow;
    } finally {
      if (s.directoryEpoch == epoch) s.loadingDirectory = false;
      changed();
    }
  }

  @override
  Future<void> renameRemote(
    TerminalSession session,
    DemoFile file,
    String name,
  ) {
    final s = _connected(session);
    // Rename stays in the selected object's original parent, even if OSC7 or
    // navigation changed the visible directory while an editor was open.
    final parent = file.id.substring(0, file.id.lastIndexOf('/'));
    return _mutateAndRefresh(s, (id, generation) async {
      await rust.sftpRename(
        id: id,
        source: file.id,
        destination: remotePath(parent.isEmpty ? '/' : parent, name),
        expectedGeneration: generation,
      );
    }, affectedDirectories: {parent.isEmpty ? '/' : parent});
  }

  @override
  Future<void> createRemoteDirectory(TerminalSession session, String name) {
    final s = _connected(session);
    final directory = s.path;
    return _mutateAndRefresh(s, (id, generation) async {
      await rust.sftpCreateDirectory(
        id: id,
        path: remotePath(directory, name),
        expectedGeneration: generation,
      );
    }, affectedDirectories: {directory});
  }

  @override
  Future<void> deleteRemoteFiles(
    TerminalSession session,
    List<DemoFile> files,
  ) {
    final s = _connected(session);
    final frozen = List<DemoFile>.unmodifiable(files);
    final affected = frozen.map((file) {
      final index = file.id.lastIndexOf('/');
      return index <= 0 ? '/' : file.id.substring(0, index);
    }).toSet();
    return _mutateAndRefresh(s, (id, generation) async {
      for (final file in frozen) {
        _checkSftpMutation(s, id, generation);
        await rust.sftpRemove(
          id: id,
          path: file.id,
          recursive: file.folder && !file.symlink,
          expectedGeneration: generation,
        );
      }
    }, affectedDirectories: affected);
  }

  void _checkSftpMutation(LiveTerminalSession s, int id, int generation) {
    if (isClosing ||
        !sessions.contains(s) ||
        !s.controller.connected ||
        s.controller.id != id ||
        s.controller.generation != generation) {
      throw StateError('原SSH文件操作已关闭或代次改变；未继续操作其他连接');
    }
  }

  Future<void> _mutateAndRefresh(
    LiveTerminalSession session,
    Future<void> Function(int id, int generation) mutation, {
    required Set<String> affectedDirectories,
  }) {
    final id = session.controller.id!,
        generation = session.controller.generation;
    final originalPath = session.path, epoch = session.directoryEpoch;
    _checkSftpMutation(session, id, generation);
    final affected = Set<String>.unmodifiable(affectedDirectories);
    final operation = () async {
      Object? failure;
      StackTrace? trace;
      try {
        await mutation(id, generation);
      } catch (error, stack) {
        failure = error;
        trace = stack;
      }
      // Invalidate even after partial failure, but never replace a newer view
      // or refresh an unrelated Root that reuses this saved host or native ID.
      if (sessions.contains(session) &&
          session.controller.id == id &&
          session.controller.generation == generation) {
        for (final path in affected) {
          session.directoryCache.remove(path);
        }
        if (!isClosing &&
            session.controller.connected &&
            session.path == originalPath &&
            session.directoryEpoch == epoch &&
            affected.contains(originalPath)) {
          try {
            await loadDirectory(session, originalPath, remember: false);
          } catch (error, stack) {
            failure ??= error;
            trace ??= stack;
          }
        }
      }
      if (failure != null) Error.throwWithStackTrace(failure, trace!);
    }();
    _track(operation);
    return operation;
  }

  @override
  Future<void> moveRemoteFiles(
    TerminalSession session,
    String source,
    List<DemoFile> files,
    String destination,
  ) {
    final s = _connected(session);
    final frozen = List<DemoFile>.unmodifiable(files);
    return _mutateAndRefresh(s, (id, generation) async {
      for (final file in frozen) {
        _checkSftpMutation(s, id, generation);
        await rust.sftpRename(
          id: id,
          source: remotePath(source, file.name),
          destination: remotePath(destination, file.name),
          expectedGeneration: generation,
        );
      }
    }, affectedDirectories: {source, destination});
  }

  @override
  Future<void> batchHosts(
    Set<String> ids, {
    String? group,
    bool? favorite,
  }) async {
    final groupId = group == null
        ? null
        : _groups.firstWhere((g) => g.name == group).id;
    await store.batch(ids.toList(), groupId, favorite);
    await load();
  }

  /// Explicit preferences/clear only; no terminal input collector is exposed.
  Future<history.HistoryControls> updateCommandHistory(
    history.HistoryControls source, {
    bool? enabled,
    String? clearHostId,
  }) {
    if (_disposed || _shutdown != null) {
      return Future.error(StateError('应用正在关闭；未修改命令历史'));
    }
    final operation = enabled == null
        ? rust.clearCommandHistory(
            vaultScope: source.vaultScope,
            revision: source.revision,
            hostId: clearHostId,
          )
        : rust.setCommandHistoryEnabled(
            vaultScope: source.vaultScope,
            revision: source.revision,
            enabled: enabled,
          );
    _track(operation.then<void>((_) {}));
    return operation;
  }

  Future<ordering.OrderingView> saveHostOrdering(
    ordering.OrderingView source,
    List<String> groups,
    List<String> hosts,
    List<ordering.OrderingPlacement> placements,
  ) {
    if (_disposed || _shutdown != null) {
      return Future.error(StateError('应用正在关闭；未保存主机排序'));
    }
    final operation = () async {
      final result = await rust.applyHostOrdering(
        vaultScope: source.vaultScope,
        revision: source.revision,
        groups: groups,
        hosts: hosts,
        placements: placements,
      );
      if (!_disposed) {
        try {
          await load();
        } catch (error) {
          throw HostOrderingRefreshFailure(result, error);
        }
      }
      return result;
    }();
    _track(operation.then<void>((_) {}));
    return operation;
  }

  Future<bulk.HostBulkView> saveHostBulk(
    bulk.HostBulkView original,
    bulk.HostBulkPatch patch,
  ) => runLocalSettings(() async {
    final result = await rust.applyHostBulk(
      vaultScope: original.vaultScope,
      revision: original.revision,
      ids: original.hosts.map((h) => h.id).toList(),
      patch: patch,
    );
    if (!_disposed) {
      try {
        await load();
      } catch (error) {
        throw HostBulkRefreshFailure(result, error);
      }
    }
    return result;
  });

  @override
  void setDisconnected(String id, bool value) {
    final t = tabById(id);
    if (t == null) return;
    final s = session(t) as LiveTerminalSession;
    if (s.controller.isClosing) {
      reportOperation(StateError('原终端已停止交互，请重试关闭或退出收尾；不会重新连接'));
      return;
    }
    _track(() async {
      try {
        if (value && s.controller.connected) {
          await rust.disconnectTerminal(id: s.controller.id!);
        } else if (value && s.controller.phase == 'Connecting') {
          await s.controller.backend.cancel(s.controller.id!);
        } else if (!value) {
          await s.controller.reconnect();
        }
      } catch (error) {
        s.controller.report(error);
      }
    }());
  }

  @override
  void closeTab(String id) {
    final t = tabById(id);
    if (t == null) return;
    final s = session(t) as LiveTerminalSession;
    s.clearTemporaryInput();
    s.controller.removeListener(s.changedListener!);
    _retiringSessions.add(s);
    super.closeTab(id);
    _track(_retireDetachedSession(s));
  }

  @override
  Future<void> shutdown() => _shutdown ??=
      () async {
        await retireTerminalNotifications?.call();
        await localEdits.disposeAll();
        await configurationSync.shutdown();
        await googleDriveObjects.shutdown();
        await googleDriveAccount.shutdown();
        await configurationBackups.shutdown();
        await typography.shutdown();
        await appearance.shutdown();
        await sftpView.shutdown();
        await cancelHostTest();
        _cancelDirectoryFollow();
        final editors = _editors.toList();
        await Future.wait(
          editors.map((editor) => editor.close(keepDraft: true)),
        );
        if (_editorRequested) await rust.shutdownEditors();
        for (final editor in editors) {
          unregisterEditor(editor);
        }
        _transferTimer?.cancel();
        // A final list read may still own a Native request after its sidebar
        // unmounts. Closing suppresses publication/rearming; await its real end.
        await _transferRefresh;
        _remoteFileClipboards.clear();
        _clipboardRevision++;
        _rateClock.stop();
        await Future.wait(
          _retiringSessions.toList().map(_retireDetachedSession),
        );
        await Future.wait(
          sessions.cast<LiveTerminalSession>().map((s) {
            s.clearTemporaryInput();
            return s.stopInspection().whenComplete(s.controller.shutdown);
          }),
        );
        // End source work after Root shutdown, then wait for actual local file
        // readers before releasing their cache leases. Native late callbacks
        // see a closed batch and cannot start a new source during exit.
        await Future.wait(
          _explorerExports.values.toList().map((e) => e.cancel()),
        );
        while (_pending.isNotEmpty) {
          await Future.wait(_pending.toList());
        }
        await Future.wait(
          _explorerExports.values.toList().map((e) => e.release()),
        );
        if (_previewRequested) {
          final initialization = _previewInitialization;
          if (initialization != null) {
            try {
              await initialization;
            } catch (e) {
              reportOperation(e);
            }
          }
          await rust.shutdownFilePreviews();
        }
      }().catchError((Object error, StackTrace stack) {
        _shutdown = null;
        resumeTerminalNotifications?.call();
        configurationSync.resumeAfterCancelledShutdown();
        googleDriveObjects.resumeAfterCancelledShutdown();
        googleDriveAccount.resumeAfterCancelledShutdown();
        typography.resumeAfterCancelledShutdown();
        appearance.resumeAfterCancelledShutdown();
        sftpView.resumeAfterCancelledShutdown();
        for (final s in sessions.cast<LiveTerminalSession>()) {
          s._inspection?.resumeAfterCancelledShutdown();
        }
        configurationBackups.resumeAfterCancelledShutdown();
        Error.throwWithStackTrace(error, stack);
      });
  @override
  void changed() {
    if (!_disposed) {
      _syncDirectoryFollow();
      super.changed();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _cancelDirectoryFollow();
    _disposed = true;
    typography.removeListener(_typographyChanged);
    unawaited(
      shutdown().whenComplete(() {
        typography.dispose();
        appearance.removeListener(_appearanceChanged);
        appearance.dispose();
        sftpView.removeListener(_sftpViewChanged);
        sftpView.dispose();
        configurationBackups.dispose();
        configurationSync.dispose();
        googleDriveObjects.dispose();
        googleDriveAccount.dispose();
        for (final s in sessions.cast<LiveTerminalSession>()) {
          s.clearTemporaryInput();
          s.disposeInspection();
          s.controller.dispose();
        }
      }),
    );
    super.dispose();
  }
}
