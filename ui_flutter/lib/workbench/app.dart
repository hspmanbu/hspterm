import '../app_notice.dart';
import '../run_log.dart';
import 'palette_settings.dart';
import 'typography_settings.dart';
import 'configuration_backup_panel.dart';
import 'configuration_sync_settings.dart';
import 'configuration_sync_panel.dart';
import 'google_drive_account_panel.dart';
import 'google_drive_objects_panel.dart';
import 'configuration_sync_archives.dart';
import 'appearance.dart';
import 'sftp_view_settings.dart';
import 'windows_unlock.dart';
import 'terminal_preferences.dart';
import 'diagnostics.dart';
import 'connection_status.dart';
import '../prototype/command_palette.dart';
import '../terminal/application_keys.dart' show PaletteBinding;
import 'history_controls.dart';
import '../src/rust/tmux.dart' as tmx;
import 'tmux_choice.dart';
import 'tmux_restore_settings.dart';
import 'transfer_settings.dart';

import 'dart:async';
import 'dart:io' show ProcessInfo, File, Platform;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../prototype/app.dart';
import '../prototype/model.dart' show DemoHost, WorkPage;
import '../prototype/design.dart';
import '../prototype/files.dart';
import '../src/rust/api.dart' as rust;
import 'model.dart';
import 'runtime_diagnostics.dart';
import 'surface.dart';
import 'queue.dart';
import 'local_edit_launch.dart';
import 'file_open_settings.dart';
import 'file_editor.dart';
import 'file_search.dart';
import 'remote_destination.dart';
import 'terminal_links.dart';
import 'terminal_paths.dart';
import 'terminal_notifications.dart';
import 'ssh_network_defaults.dart';
import 'display_settings.dart';
import 'temporary_connection.dart';

/// Real workbench entry. Mock mode remains a separate explicit entrypoint.
class WorkbenchApp extends StatefulWidget {
  const WorkbenchApp({
    super.key,
    this.model,
    this.vaultPath,
    this.fileOpener,
    this.backupFiles = const NativeConfigurationBackupFiles(),
  });
  final LiveWorkbenchModel? model;
  final String? vaultPath;
  final Future<void> Function(String)? fileOpener;
  final ConfigurationBackupFiles backupFiles;
  @override
  State<WorkbenchApp> createState() => _WorkbenchAppState();
}

class _WorkbenchAppState extends State<WorkbenchApp> {
  late final m = widget.model ?? LiveWorkbenchModel();
  final _navigator = GlobalKey<NavigatorState>();
  final _workbench = GlobalKey<PrototypeAppState>();
  final _password = TextEditingController(),
      _confirmation = TextEditingController();
  Future<void> _confirmTail = Future.value();
  late final Future<TemporaryConnectionInput?> Function(
    DemoHost,
    TemporaryTarget?,
  )
  _temporaryRequest;
  late final AppLifecycleListener _lockedExit;
  late final TerminalNoticeHub _noticeHub;
  late final Future<void> Function() _retireNotices;
  late final VoidCallback _resumeNotices;
  late PaletteBinding _lastPaletteBinding;
  bool _unlocked = false, _busy = false;
  bool? _vaultExists;
  String? _vaultInspectionError;
  bool _lockedClosing = false;
  Future<void>? _openingVault;
  String? _error;
  late final Future<tmx.TmuxSelection?> Function(
    LiveTerminalSession,
    tmx.TmuxPrompt,
  )
  _tmuxRequest;
  Timer? _memorySampler;
  late final RuntimeDiagnostics _diagnostics = RuntimeDiagnostics(() => m);

  void _sampleMemory() {
    AppRunLog.instance.event(
      AppLogEvent.memorySample,
      count: (ProcessInfo.currentRss / 1024).round(),
      fields: {
        'bytes': ProcessInfo.currentRss,
        'maxRssKiB': (ProcessInfo.maxRss / 1024).round(),
        'kind': 'rssKiB',
      },
    );
  }

  @override
  void initState() {
    super.initState();
    // Memory samples: 10s for the first five minutes (the observed growth
    // phase), then once per minute. RSS/maxRSS only, no payloads.
    var fastSamples = 30;
    _sampleMemory();
    _memorySampler = Timer.periodic(
      fastSamples > 0
          ? const Duration(seconds: 10)
          : const Duration(minutes: 1),
      (_) {
        if (fastSamples == 0) {
          _memorySampler?.cancel();
          _memorySampler = Timer.periodic(
            const Duration(minutes: 1),
            (_) => _sampleMemory(),
          );
        }
        fastSamples--;
        _sampleMemory();
      },
    );
    // Threshold-gated stall/jank/counts instrumentation (round-8 feedback).
    _diagnostics.start();
    _noticeHub = TerminalNoticeHub(
      inline: (notice, activate) {
        final context = _navigator.currentContext;
        if (!mounted || context == null) return;
        showAppNotice(
          context,
          [
            notice.summary,
            notice.title,
            notice.body,
          ].where((s) => s.isNotEmpty).join(' · '),
          action: SnackBarAction(label: '查看终端', onPressed: activate),
        );
      },
      failure: (message) {
        final context = _navigator.currentContext;
        if (!mounted || context == null) return;
        showAppNotice(context, message, level: AppNoticeLevel.error);
      },
    );
    _retireNotices = _noticeHub.shutdown;
    _resumeNotices = _noticeHub.resume;
    m.retireTerminalNotifications = _retireNotices;
    m.resumeTerminalNotifications = _resumeNotices;
    m.addListener(_bindNotices);
    _lastPaletteBinding = m.paletteBinding;
    m.addListener(_paletteChanged);
    _bindNotices();
    _tmuxRequest = (source, prompt) {
      final result = Completer<tmx.TmuxSelection?>();
      _confirmTail = _confirmTail
          .then((_) async {
            final context = _navigator.currentContext;
            if (!mounted || context == null || !context.mounted) {
              result.complete(null);
              return;
            }
            result.complete(
              await showTmuxChoice(context, source.controller, prompt),
            );
          })
          .catchError((Object _) {
            if (!result.isCompleted) result.complete(null);
          });
      return result.future;
    };
    m.requestTmuxChoice ??= _tmuxRequest;
    _unlocked = widget.model != null;
    if (!_unlocked) unawaited(_inspectVault());
    _lockedExit = AppLifecycleListener(
      onExitRequested: () async {
        // The unlocked workbench owns the activity confirmation. Before unlock,
        // still await preview-cache initialization and teardown on normal exit.
        if (!_unlocked || _navigator.currentState == null) {
          if (mounted) setState(() => _lockedClosing = true);
          try {
            final opening = _openingVault;
            if (opening != null) await opening;
            await m.shutdown();
          } catch (error) {
            if (mounted) {
              setState(() {
                _lockedClosing = false;
                _error = '退出前保存或释放失败：$error';
              });
            }
            return AppExitResponse.cancel;
          }
        }
        return AppExitResponse.exit;
      },
    );
    unawaited(m.initializePreviewCache().catchError(m.reportOperation));
    _temporaryRequest = (host, previous) async {
      final context = _navigator.currentContext;
      if (!mounted || context == null || !context.mounted) return null;
      return showTemporaryConnection(context, host, previous: previous);
    };
    m.requestTemporaryParameters ??= _temporaryRequest;
    m.confirmHostKey = (host, event) {
      final result = Completer<bool>();
      _confirmTail = _confirmTail
          .then((_) async {
            final context = _navigator.currentContext;
            if (!mounted || context == null || !context.mounted) {
              result.complete(false);
              return;
            }
            final answer = await showAppDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(
                  event.kind == 'jumpHostKey'
                      ? '首次连接：确认跳板机 SSH 指纹'
                      : '首次连接：确认 SSH 主机指纹',
                ),
                content: SelectableText(
                  '目标配置：${host.name}\n${event.kind == 'jumpHostKey' ? '当前验证跳板机' : '当前验证目标主机'}\n${event.detail}\n${event.text}\n\n请通过可信途径核对。信任后加密保存；后续指纹变化将阻止连接。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('拒绝'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('信任并保存'),
                  ),
                ],
              ),
            );
            result.complete(answer == true);
          })
          .catchError((Object _) {
            if (!result.isCompleted) result.complete(false);
          });
      return result.future;
    };
  }

  void _paletteChanged() {
    final binding = m.paletteBinding;
    if (identical(binding, _lastPaletteBinding)) return;
    _lastPaletteBinding = binding;
    // PrototypeApp owns the persistent navigator/key router, but its binding
    // is a constructor snapshot. Rebuild only when the acknowledged shortcut
    // changes; ordinary session/queue notifications do not rebuild this root.
    if (mounted && _unlocked) setState(() {});
  }

  void _bindNotices() {
    if (!mounted) return;
    _noticeHub.reconcile(
      m.sessions.cast<LiveTerminalSession>().map(
        (s) => TerminalNoticeSubject(
          s,
          s.controller,
          () => m.page == WorkPage.workspace && identical(m.focus, s),
          () {
            final tab = m.tabs
                .where((t) => identical(m.session(t), s))
                .firstOrNull;
            if (tab != null) {
              unawaited(_activateNoticeTab(tab.id));
            }
          },
        ),
      ),
    );
  }

  Future<void> _activateNoticeTab(String id) async {
    try {
      // Bring an existing window forward first so an unsaved-draft decision is
      // visible. Activation alone neither changes pages nor grants navigation.
      if (Platform.isWindows) await _activateNoticeWindow();
      if (!mounted || !_unlocked || m.isClosing) return;
      await _workbench.currentState?.activateTab(id);
    } catch (error) {
      if (mounted) m.reportOperation(error);
    }
  }

  Future<void> _activateNoticeWindow() async {
    try {
      await const MethodChannel('hspterm/prototype_window')
          .invokeMethod<void>('activate');
    } catch (_) {
      final context = _navigator.currentContext;
      if (context != null && context.mounted) {
        showAppNotice(
          context,
          '终端已定位，但窗口激活未获确认；请从任务栏打开HSPTerm。',
          level: AppNoticeLevel.warning,
        );
      }
    }
  }

  Future<File> _vaultFile() async {
    if (widget.vaultPath != null) return File(widget.vaultPath!);
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}hspterm.vault');
  }

  Future<void> _inspectVault() async {
    try {
      final exists = await (await _vaultFile()).exists();
      if (mounted) {
        setState(() {
          _vaultExists = exists;
          _vaultInspectionError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _vaultInspectionError = '无法读取本机配置库位置，请检查目录权限后重试。');
      }
    }
  }

  Future<void> _unlock({bool withWindows = false}) {
    if (_busy || _lockedClosing || (!withWindows && _password.text.isEmpty)) {
      return Future.value();
    }
    if (!withWindows &&
        [_password.value, _confirmation.value].any(
          (value) => value.composing.isValid && !value.composing.isCollapsed,
        )) {
      setState(() => _error = '请先确认输入法候选，再打开配置库');
      return Future.value();
    }
    final operation = _performUnlock(withWindows);
    _openingVault = operation;
    return operation.whenComplete(() {
      if (identical(_openingVault, operation)) _openingVault = null;
    });
  }

  Future<void> _performUnlock(bool withWindows) async {
    AppRunLog.instance.event(AppLogEvent.vaultOpen);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await _vaultFile();
      final directory = file.parent, path = file.path;
      final exists = await File(path).exists();
      if (mounted) setState(() => _vaultExists = exists);
      if (withWindows && !exists) throw StateError('尚未创建配置库，请先设置主密码');
      if (!withWindows && !exists && _password.text != _confirmation.text) {
        throw StateError('首次创建配置库时，两次主密码必须一致');
      }
      final password = withWindows ? '' : _password.text;
      _password.clear();
      _confirmation.clear();
      if (withWindows) {
        await openWindowsProtectedVault(path);
      } else if (exists) {
        final token = await rust.vaultUnlockHint(path: path);
        await rust.unlockExistingVault(
          path: path,
          password: password,
          token: token,
        );
      } else {
        await directory.create(recursive: true);
        await rust.createConfigurationVault(path: path, password: password);
      }
      AppRunLog.instance.event(AppLogEvent.vaultOpened);
      await m.load();
      await m.appearance.load();
      await m.sftpView.load();
      await m.configurationSync.start();
      try {
        await m.typography.load();
      } catch (error) {
        m.reportOperation(error);
      }
      await m.refreshTransfers();
      if (mounted && !_lockedClosing) setState(() => _unlocked = true);
    } catch (error) {
      if (mounted) setState(() => _error = '无法打开加密配置：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _memorySampler?.cancel();
    _diagnostics.stop();
    m.removeListener(_bindNotices);
    m.removeListener(_paletteChanged);
    // Keep the original shutdown hook until the actual OS worker has ended,
    // including an externally owned model closed immediately after unmount.
    unawaited(
      _noticeHub.dispose().whenComplete(() {
        if (identical(m.retireTerminalNotifications, _retireNotices)) {
          m.retireTerminalNotifications = null;
        }
        if (identical(m.resumeTerminalNotifications, _resumeNotices)) {
          m.resumeTerminalNotifications = null;
        }
      }),
    );
    _lockedExit.dispose();
    if (identical(m.requestTmuxChoice, _tmuxRequest)) {
      m.requestTmuxChoice = null;
    }
    if (identical(m.requestTemporaryParameters, _temporaryRequest)) {
      m.requestTemporaryParameters = null;
    }
    _password.clear();
    _confirmation.clear();
    _password.dispose();
    _confirmation.dispose();
    if (widget.model == null) m.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) {
      return PrototypeApp(
        key: _workbench,
        model: m,
        appearanceSettingsBuilder: (_) =>
            AppearanceStatusPanel(controller: m.appearance),
        sftpViewSettingsBuilder: (_) =>
            SftpViewSettingsPanel(controller: m.sftpView),
        backupSettingsBuilder: (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WindowsUnlockSettingsPanel(
              run: (action) => m.runLocalSettings(action),
            ),
            const SizedBox(height: 20),
            ConfigurationBackupPanel(
              controller: m.configurationBackups,
              files: widget.backupFiles,
            ),
            const SizedBox(height: 24),
            ConfigurationSyncSettingsPanel(
              gateway: NativeConfigurationSyncSettingsGateway(m),
            ),
            const SizedBox(height: 24),
            ConfigurationSyncRuntimePanel(controller: m.configurationSync),
            const SizedBox(height: 20),
            GoogleDriveAccountPanel(controller: m.googleDriveAccount),
            const SizedBox(height: 20),
            GoogleDriveObjectsPanel(controller: m.googleDriveObjects),
            const SizedBox(height: 20),
            ConfigurationSyncArchivesPanel(
              gateway: NativeConfigurationSyncArchivesGateway(m),
            ),
          ],
        ),
        paletteBinding: m.paletteBinding,
        typographySettingsBuilder: (_) =>
            TypographySettingsPanel(controller: m.typography),
        terminalPreferencesBuilder: (_) => TerminalPreferencesPanel(
          gateway: NativeTerminalPreferencesGateway(m),
        ),
        diagnosticsBuilder: (_) =>
            DiagnosticsPanel(gateway: NativeDiagnosticsGateway(m)),
        statusBarBuilder: (_) => WorkbenchConnectionStatus(model: m),
        noticeBuilder: (_) =>
            ConfigurationSyncBanner(controller: m.configurationSync),
        paletteSettingsBuilder: (_) =>
            PaletteSettingsPanel(gateway: NativePaletteSettingsGateway(m)),
        navigatorKey: _navigator,
        transferSettingsBuilder: (_) => const TransferSettingsPanel(),
        fileOpenSettingsBuilder: (_) => const FileOpenSettingsPanel(),
        sshNetworkSettingsBuilder: (_) => const SshNetworkDefaultsPanel(),
        historySettingsBuilder: (_) =>
            HistoryControlsPanel(gateway: NativeHistoryControlsGateway(m)),
        displaySettingsBuilder: (_) => const DisplaySettingsPanel(),
        sidebarBuilder: (_) => SftpSidebar(
          model: m,
          queueBuilder: (_) => LiveTransferQueue(model: m),
          onOpenFile: (context, source, file) =>
              openLocalEdit(context, m, source as LiveTerminalSession, file),
          onSearchFiles: showRemoteFileSearch,
          onTransferTo: (context, source, files, move) =>
              showRemoteDestination(context, m, source, files, move),
          onEditFile: (context, source, file) =>
              showRemoteFileEditor(context, m, source, file),
          onEditRawFile: (context, source, file) =>
              showRemoteFileEditor(context, m, source, file, rawMode: true),
          onEditFileWithEncoding: (context, source, file) =>
              showRemoteFileEditor(
                context,
                m,
                source,
                file,
                chooseEncoding: true,
              ),
          onEditorDrafts: (context) => showEditorDrafts(context, m),
        ),
        terminalBuilder: (context, session) => LiveTerminalSurface(
          key: ValueKey('live-${session.id}'),
          session: session as LiveTerminalSession,
          focused: m.focus == session,
          fontSize: m.typography.forHost(session.host.id).size,
          typography: m.typography.forHost(session.host.id),
          typographyNotice: m.typography.hostNotice(session.host.id),
          retryTypography: () =>
              unawaited(m.typography.ensureHost(session.host.id, retry: true)),
          onLocatePath: (text) => m.locateTerminalPath(session, text),
          onOpenLink: (link) => openTerminalLink(context, m, session, link),
          onDropPaths: (paths, generation) => sendSessionPaths(
            context,
            m,
            session,
            paths,
            expectedGeneration: generation,
          ),
        ),
        extraCommands: () {
          final source = m.focus as LiveTerminalSession?;
          final view = source?.view.currentState;
          final generation = source?.controller.generation;
          bool originalView() =>
              source != null &&
              view != null &&
              identical(m.focus, source) &&
              identical(source.view.currentState, view) &&
              source.controller.generation == generation;
          return [
            AppCommand(
              'retry-terminal-retirement',
              '重试未完成的会话关闭',
              m.retryRetiringSessions,
              available: () => m.hasRetiringSessions && !m.isClosing,
              availableChanges: m,
            ),
            AppCommand('editor-drafts', '恢复本机编辑草稿', () async {
              final context = _navigator.currentContext;
              if (context != null) await showEditorDrafts(context, m);
            }),
            if (source != null && view != null) ...[
              AppCommand(
                'terminal-tmux-restore',
                'tmux 手动重连恢复设置',
                () async {
                  final context = _navigator.currentContext;
                  if (context != null && originalView()) {
                    await showTmuxRestoreSettings(context, m, source);
                  }
                },
                available: originalView,
                availableChanges: source.controller,
              ),
              AppCommand(
                'terminal-search',
                '终端搜索',
                view.showSearch,
                available: originalView,
                availableChanges: source.controller,
              ),
              AppCommand(
                'terminal-copy',
                '复制终端选择',
                view.copy,
                available: () =>
                    originalView() &&
                    source.controller.selectedText().isNotEmpty,
                availableChanges: source.controller,
              ),
              AppCommand(
                'terminal-paste',
                '粘贴到当前终端',
                view.paste,
                available: () => originalView() && source.controller.connected,
                availableChanges: source.controller,
              ),
              AppCommand(
                'terminal-export',
                '导出当前终端历史',
                view.exportHistory,
                available: originalView,
                availableChanges: source.controller,
              ),
            ],
            AppCommand('font-larger', '放大终端字体', () {
              m.typography.zoom(1, hostId: m.focus?.host.id);
            }, available: () => m.fontSize < 36),
            AppCommand('font-smaller', '缩小终端字体', () {
              m.typography.zoom(-1, hostId: m.focus?.host.id);
            }, available: () => m.fontSize > 9),
          ];
        },
      );
    }
    return MaterialApp(
      title: 'HSPTerm',
      debugShowCheckedModeBanner: false,
      theme: Desk.theme(false),
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.terminal, color: Desk.accent, size: 34),
                  const SizedBox(height: 18),
                  const Text(
                    'HSPTerm',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _vaultExists == null
                        ? '正在检查本机配置库…'
                        : _vaultExists!
                        ? '输入已有主密码解锁配置库。'
                        : '首次使用，请设置主密码。',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    key: const ValueKey('vault-password'),
                    enabled: !_busy && !_lockedClosing && _vaultExists != null,
                    controller: _password,
                    obscureText: true,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: _vaultExists == false ? '设置主密码' : '主密码',
                    ),
                    onSubmitted: (_) {
                      if (_vaultExists == true) _unlock();
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_vaultExists == false)
                    TextField(
                      key: const ValueKey('vault-confirm'),
                      enabled: !_busy && !_lockedClosing,
                      controller: _confirmation,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '确认主密码'),
                    ),
                  const SizedBox(height: 16),
                  if (_vaultInspectionError != null)
                    TextButton(
                      onPressed: _inspectVault,
                      child: Text(_vaultInspectionError!),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Desk.warning),
                      ),
                    ),
                  FilledButton(
                    key: const ValueKey('unlock-vault'),
                    onPressed: _busy || _lockedClosing || _vaultExists == null
                        ? null
                        : _unlock,
                    child: Text(
                      _lockedClosing
                          ? '正在退出…'
                          : _busy
                          ? '正在打开…'
                          : _vaultExists == false
                          ? '创建配置库'
                          : '解锁配置库',
                    ),
                  ),
                  if (Platform.isWindows && _vaultExists == true)
                    TextButton.icon(
                      key: const ValueKey('unlock-vault-windows'),
                      onPressed: _busy || _lockedClosing
                          ? null
                          : () => _unlock(withWindows: true),
                      icon: const Icon(Icons.lock_open, size: 16),
                      label: const Text('使用 Windows 账户解锁（需先启用）'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
