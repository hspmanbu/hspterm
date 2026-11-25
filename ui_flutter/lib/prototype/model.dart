import 'package:flutter/foundation.dart';

import '../run_log.dart';

enum WorkPage { workspace, hosts, settings }

enum TransferState {
  active,
  waiting,
  paused,
  failed,
  partial,
  complete,
  cancelled,
}

class DemoHost {
  DemoHost(
    this.id,
    this.name,
    this.address,
    this.group, {
    this.favorite = false,
    this.user = '',
    this.port = 22,
    this.auth = '私钥',
    this.note = '',
    this.credentialSet = false,
    this.openSftp = true,
    this.followOsc7 = false,
    this.agentForwarding = false,
    this.tmuxEnabled = false,
    this.shellIntegration = false,
    this.proxy,
    this.jumpHostId,
    this.timeoutSeconds = 30,
    this.keepaliveSeconds = 30,
    this.keepaliveFailures = 3,
    this.useNetworkDefaults = false,
    this.keepaliveResponseSeconds,
  });
  final String id;
  String name, address, group, user, auth, note;
  int port;
  bool favorite, credentialSet;
  bool openSftp, followOsc7, agentForwarding, tmuxEnabled, shellIntegration;
  DemoProxy? proxy;
  String? jumpHostId;
  int timeoutSeconds, keepaliveSeconds, keepaliveFailures;
  bool useNetworkDefaults;
  int? keepaliveResponseSeconds;
  DemoHost snapshot() => DemoHost(
    id,
    name,
    address,
    group,
    favorite: favorite,
    user: user,
    port: port,
    auth: auth,
    note: note,
    credentialSet: credentialSet,
    openSftp: openSftp,
    followOsc7: followOsc7,
    agentForwarding: agentForwarding,
    tmuxEnabled: tmuxEnabled,
    shellIntegration: shellIntegration,
    proxy: proxy,
    jumpHostId: jumpHostId,
    timeoutSeconds: timeoutSeconds,
    keepaliveSeconds: keepaliveSeconds,
    keepaliveFailures: keepaliveFailures,
    useNetworkDefaults: useNetworkDefaults,
    keepaliveResponseSeconds: keepaliveResponseSeconds,
  );
  DemoHost copy(String id) => DemoHost(
    id,
    '$name 副本',
    address,
    group,
    favorite: favorite,
    user: user,
    port: port,
    auth: auth,
    note: note,
    credentialSet: credentialSet,
    openSftp: openSftp,
    followOsc7: followOsc7,
    agentForwarding: agentForwarding,
    tmuxEnabled: tmuxEnabled,
    shellIntegration: false,
    proxy: proxy,
    jumpHostId: jumpHostId,
    timeoutSeconds: timeoutSeconds,
    keepaliveSeconds: keepaliveSeconds,
    keepaliveFailures: keepaliveFailures,
    useNetworkDefaults: useNetworkDefaults,
    keepaliveResponseSeconds: keepaliveResponseSeconds,
  );
}

/// Immutable non-secret proxy metadata; credentials are write-only form values.
class DemoProxy {
  const DemoProxy({
    required this.socks5,
    required this.address,
    required this.port,
    this.enabled = true,
    this.authenticate = false,
    this.credentialSet = false,
  });
  final bool enabled, socks5, authenticate, credentialSet;
  final String address;
  final int port;
}

class KeyDetails {
  const KeyDetails(this.publicKey, this.fingerprint, this.algorithm);
  final String publicKey, fingerprint, algorithm;
}

/// One path the server refused to delete, with the restricted reason code and
/// fixed public phrase reported by the Rust bridge.
class RemoteDeleteFailure {
  const RemoteDeleteFailure(this.path, this.reasonCode, this.reasonText);
  final String path;
  final String reasonCode;
  final String reasonText;

  /// Chinese category phrase shown in the failure list; the bridge text is
  /// the fallback for codes this UI does not know.
  String get phrase => switch (reasonCode) {
    'PermissionDenied' => '权限不足',
    'Failure' => '被占用或目录非空',
    'NoSuchFile' => '文件已不存在（建议刷新）',
    'NameInvalid' => '名称含非UTF-8字节，建议终端处理',
    'Timeout' => '服务器响应超时，可重试',
    _ => reasonText.isEmpty ? '服务器拒绝' : reasonText,
  };
}

/// One batched remote delete: every entry actually removed (rm -f style — an
/// already-absent path counts as achieved) and every refusal, replacing the
/// old all-or-nothing error with an explicit partial result.
class RemoteDeleteResult {
  const RemoteDeleteResult({required this.succeeded, required this.failed});
  final List<String> succeeded;
  final List<RemoteDeleteFailure> failed;
  bool get fullySucceeded => failed.isEmpty;
}

class DemoFile {
  DemoFile(
    this.id,
    this.name, {
    this.folder = false,
    this.size = '—',
    this.kind = '文件',
    this.modified = '2026-10-22 09:41',
    this.byteSize,
    this.modifiedEpoch,
    this.symlink = false,
    this.permissions,
    this.owner,
  });
  final String id;
  String name;
  final bool folder;
  final String size, kind, modified;
  final int? byteSize, modifiedEpoch;
  final bool symlink;

  /// Raw Unix mode bits and the listing owner (name or numeric id) when the
  /// server reports them; round-9 permission/owner columns.
  final int? permissions;
  final String? owner;
}

class PathBookmark {
  const PathBookmark(this.id, this.name, this.path, this.hostId);
  final String id, name, path;
  final String? hostId;
}

class DemoTransfer {
  DemoTransfer(
    this.id,
    this.sessionId,
    this.name,
    this.upload,
    this.state,
    this.progress, {
    this.folder = false,
  });
  final String id, sessionId, name;
  final bool upload, folder;
  TransferState state;
  double progress;
  String get label => switch (state) {
    TransferState.active => '传输中',
    TransferState.waiting => '等待中',
    TransferState.paused => '已暂停',
    TransferState.failed => '失败',
    TransferState.partial => '部分完成',
    TransferState.complete => '已完成',
    TransferState.cancelled => '已取消',
  };
}

/// One-shot local selection request; never part of configuration or sync.
class RemoteFileLocation {
  const RemoteFileLocation(this.directory, this.file, this.generation);
  final String directory;
  final String? file;
  final int generation;
}

class RemoteRelativePaths {
  RemoteRelativePaths(this.directoryRevision, List<String> paths)
    : paths = List.unmodifiable(paths);
  final int directoryRevision;
  final List<String> paths;
}

class LocalTransferSubmissionFailure implements Exception {
  const LocalTransferSubmissionFailure(
    this.accepted,
    this.total, {
    this.upload = true,
  });
  final int accepted, total;
  final bool upload;
  @override
  String toString() =>
      '已加入 $accepted 项${upload ? '上传' : '下载'}任务，另有 ${total - accepted} 项未确认入队；请查看任务队列后重新选择剩余项';
}

class LocalTransferRequest {
  const LocalTransferRequest(this.local, this.remote);
  final String local, remote;
}

/// Stable-id SFTP listing column layout remembered per host (round-9).
class SftpColumnLayout {
  SftpColumnLayout({
    required this.order,
    required this.hidden,
    required this.widths,
  });
  final List<String> order;
  final Set<String> hidden;
  final Map<String, double> widths;
}

class TerminalSession {
  TerminalSession(this.id, this.host, {this.disconnected = false});
  final String id;
  final DemoHost host;
  bool get isMock => true;
  String get statusLabel => disconnected ? '已断开' : '模拟连接';
  bool disconnected;
  int connectionGeneration = 1;

  /// Connection generation whose listings are currently reusable in the
  /// session directory cache; a reconnect invalidates them.
  int directoryCacheGeneration = 0;
  bool sftpEnabled = true, loadingDirectory = false;
  String? sftpError;
  String? get sftpActivity => null;
  RemoteFileLocation? pendingFileLocation;
  String path = '/home/ubuntu/project';
  String draft = '';
  final entered = <String>[];
  final List<String> back = [], forward = [];
  final Map<String, List<DemoFile>> directories = {};

  /// A producer may supply a revision for complete directory publications.
  /// Null keeps mutable prototype/third-party models on per-build snapshots.
  int? get fileListRevision => null;
  List<DemoFile> get files => directories.putIfAbsent(
    path,
    () => [
      DemoFile('$path/config', 'config', folder: true, kind: '文件夹'),
      DemoFile('$path/src', 'src', folder: true, kind: '文件夹'),
      DemoFile('$path/assets', 'assets', folder: true, kind: '文件夹'),
      DemoFile('$path/compose', 'compose.yaml', size: '2.4 KB', kind: 'YAML'),
      DemoFile('$path/readme', 'README.md', size: '4.8 KB', kind: 'Markdown'),
      DemoFile('$path/env', '.env.example', size: '862 B', kind: '配置文件'),
      DemoFile('$path/log', 'application.log', size: '12.6 MB', kind: '日志'),
      DemoFile('$path/package', 'package.json', size: '1.2 KB', kind: 'JSON'),
    ],
  );
  void navigate(String value) {
    if (value == path) return;
    back.add(path);
    forward.clear();
    path = value;
  }
}

/// A tab owns no transport or terminal buffer; its stable session ID does.
class TerminalTab {
  TerminalTab(this.id, this.sessionId, this.name);
  final String id, sessionId;
  String name;
  bool pinned = false;
}

class TabGroup {
  TabGroup(this.id, TerminalTab first) : tabs = [first], selectedId = first.id;
  final String id;
  final List<TerminalTab> tabs;
  String selectedId;
  TerminalTab get selected => tabs.firstWhere((t) => t.id == selectedId);
}

sealed class SplitTree {
  Iterable<String> get groupIds;
}

class GroupLeaf extends SplitTree {
  GroupLeaf(this.groupId);
  final String groupId;
  @override
  Iterable<String> get groupIds => [groupId];
}

class GroupSplit extends SplitTree {
  GroupSplit(this.horizontal, this.first, this.second, {this.ratio = .5});
  final bool horizontal;
  SplitTree first, second;
  double ratio;
  @override
  Iterable<String> get groupIds => [...first.groupIds, ...second.groupIds];
}

enum TabPlacement { center, left, right, top, bottom }

/// Entire prototype state is disposable memory. No vault, SSH or filesystem API.
class WorkbenchModel extends ChangeNotifier {
  bool get isClosing => false;
  bool get hasPendingExternalDelivery => false;
  Future<RemoteRelativePaths> relativeRemotePaths(
    TerminalSession source,
    List<String> paths, {
    int? expectedRevision,
  }) => throw UnsupportedError('纯原型不能验证远端工作目录');
  WorkbenchModel();
  bool get isMock => true;
  bool get hasActiveEditors => false;
  bool get hasActiveSessions => sessions.any((s) => !s.disconnected);
  int get activeTransferCount => transfers
      .where(
        (t) => [TransferState.active, TransferState.waiting].contains(t.state),
      )
      .length;
  int get totalTransferCount => transfers.length;
  bool get hasTransferErrors => transfers.any(
    (t) => [TransferState.failed, TransferState.partial].contains(t.state),
  );
  Future<void> shutdown() async {}
  Future<void> testSavedHost(DemoHost host) =>
      throw UnsupportedError('Mock模式不执行真实握手测试');
  Future<void> cancelHostTest({Future<void>? expected}) async {}
  String? get remoteFileClipboardDescription => null;
  int get remoteFileClipboardRevision => 0;
  bool get remoteFileClipboardIsCut => false;
  void copyRemoteFileClipboard(
    TerminalSession session,
    List<DemoFile> files, {
    bool cut = false,
  }) => throw UnsupportedError('Mock文件剪贴板由原型管理');
  Future<List<String>> pasteRemoteFileClipboard(
    TerminalSession target,
    String directory,
    int expectedGeneration, {
    required bool allowMemoryRelay,
    bool allowDirect = false,
    required int expectedClipboardRevision,
  }) => throw UnsupportedError('Mock模式不执行真实远端复制');
  Future<String> enqueueFileTransfer(
    TerminalSession session,
    String local,
    String remote,
    bool upload, {
    int? expectedGeneration,
  }) => throw UnsupportedError('Mock模式不执行真实文件传输');
  Future<T> runTransferSubmission<T>(Future<T> Function() action) =>
      Future<T>.sync(action);
  Future<List<String>> submitFileTransfers(
    TerminalSession source,
    List<LocalTransferRequest> requests, {
    required int generation,
    required bool upload,
  }) {
    final frozen = List<LocalTransferRequest>.unmodifiable(requests);
    if (frozen.length > 4096 ||
        frozen.any(
          (r) =>
              r.local.isEmpty ||
              r.local.contains('\u0000') ||
              !r.remote.startsWith('/') ||
              r.remote.contains('\u0000'),
        )) {
      return Future.error(StateError('文件传输选择无效或超过容量，未入队'));
    }
    return runTransferSubmission(() async {
      final accepted = <String>[];
      try {
        for (final request in frozen) {
          if (!sessions.contains(source) ||
              source.disconnected ||
              source.connectionGeneration != generation) {
            throw StateError('原传输会话已变化，剩余项目未入队');
          }
          accepted.add(
            await enqueueFileTransfer(
              source,
              request.local,
              request.remote,
              upload,
              expectedGeneration: generation,
            ),
          );
        }
      } catch (_) {
        throw LocalTransferSubmissionFailure(
          accepted.length,
          frozen.length,
          upload: upload,
        );
      }
      return List<String>.unmodifiable(accepted);
    });
  }

  Future<KeyDetails> prepareKey(
    DemoHost host, {
    String? path,
    String? passphrase,
  }) => throw UnsupportedError('Mock 模式不生成或读取私钥');
  Future<KeyDetails> publicKey(String id) =>
      throw UnsupportedError('Mock 模式没有真实密钥');
  Future<void> exportKey(String id, String path, String masterPassword) =>
      throw UnsupportedError('Mock 模式不导出私钥');
  Future<void> exportPublicKey(String id, String path) =>
      throw UnsupportedError('Mock 模式没有真实公钥');
  List<String> get hostGroups =>
      groups.where((g) => g != '全部主机' && g != '收藏').toList();
  // Navigation buckets are not actual groups; their labels may also be valid
  // saved group names. Keep identity separate from presentation.
  List<(String, String)> get hostGroupEntries => [
    for (final name in hostGroups) ('group:$name', name),
  ];
  TerminalSession createSession(String id, DemoHost host) =>
      TerminalSession(id, host);
  WorkPage page = WorkPage.workspace;
  String? operationError;
  void reportOperation(Object error) {
    AppRunLog.instance.event(
      AppLogEvent.operationFailed,
      error: error,
      stack: StackTrace.current,
    );
    operationError = error.toString();
    changed();
  }

  bool light = false,
      sidebar = true,
      filesMaximized = false,
      queueMaximized = false,
      allTasks = false;
  bool get themeAvailable => true;
  void chooseTheme(bool value) {
    light = value;
    changed();
  }

  Future<void> applyTheme(bool value) async => chooseTheme(value);

  double sidebarWidth = 380, queueHeight = 238, hostListWidth = 290;

  /// Total visible SFTP column width (+ scrollbar allowance) published by the
  /// files panel each build; the sidebar grip caps the panel there so the
  /// pane cannot be stretched far past its content into dead space. Zero
  /// means "not published yet" and leaves the previous bound in place.
  double sftpContentBound = 0;
  final settings = <String, Object>{};
  String? requestedHostId, requestedHostCategory;
  void editHostSettings(String id, {String category = '连接'}) {
    if (!hosts.any((host) => host.id == id)) return;
    requestedHostId = id;
    requestedHostCategory = category;
    show(WorkPage.hosts);
  }

  bool get fileFoldersFirst => (settings['目录优先'] ?? true) as bool;
  bool get fileShowHidden => (settings['显示隐藏文件'] ?? false) as bool;
  bool get fileCompact => settings['默认视图'] == '紧凑列表';
  Object get fileDefaultsRevision =>
      (fileFoldersFirst, fileShowHidden, fileCompact);
  int _serial = 0;
  int _next() => ++_serial;
  final hosts = [
    DemoHost(
      'web',
      '生产 · Web 服务',
      'web-01.example.test',
      '生产环境',
      user: 'operator',
      favorite: true,
    ),
    DemoHost(
      'api',
      '生产 · API 服务',
      'api-01.example.test',
      '生产环境',
      user: 'operator',
      favorite: true,
    ),
    DemoHost(
      'dev',
      '开发工作站',
      'dev.example.test',
      '开发环境',
      favorite: true,
      user: 'developer',
    ),
    DemoHost('db', '数据库 · 只读', 'db.example.test', '生产环境', user: 'reader'),
  ];
  final groups = ['全部主机', '收藏', '生产环境', '开发环境'];
  final recent = <String>['dev', 'api'];
  final Map<String, TerminalSession> _sessions = {};
  final Map<String, TabGroup> tabGroups = {};
  SplitTree? root;
  String? focusedGroupId, maximizedGroupId;
  bool startPage = true;
  final transfers = <DemoTransfer>[];
  List<TerminalSession> get sessions => List.unmodifiable(_sessions.values);
  List<TabGroup> get layoutGroups => [
    for (final id in root?.groupIds ?? <String>[]) tabGroups[id]!,
  ];
  List<TerminalTab> get tabs => [for (final g in layoutGroups) ...g.tabs];
  TabGroup? get focusedGroup => tabGroups[focusedGroupId];
  TerminalSession session(TerminalTab tab) => _sessions[tab.sessionId]!;
  TerminalSession? get focus =>
      focusedGroup == null ? null : session(focusedGroup!.selected);
  TabGroup? groupOf(String tabId) =>
      layoutGroups.where((g) => g.tabs.any((t) => t.id == tabId)).firstOrNull;
  TerminalTab? tabById(String id) => tabs.where((t) => t.id == id).firstOrNull;
  void changed() => notifyListeners();
  void show(WorkPage value) {
    AppRunLog.instance.event(AppLogEvent.pageChanged, count: value.index);
    page = value;
    changed();
  }

  /// Quick-connect is an application page, never a placeholder session tab.
  void newTab() {
    startPage = true;
    page = WorkPage.workspace;
    changed();
  }

  void selectTab(String id) {
    final g = groupOf(id);
    if (g == null) return;
    g.selectedId = id;
    focusedGroupId = g.id;
    if (maximizedGroupId != null) maximizedGroupId = g.id;
    startPage = false;
    page = WorkPage.workspace;
    changed();
  }

  void focusGroup(String id) {
    final g = tabGroups[id];
    if (g != null) selectTab(g.selectedId);
  }

  /// Device-local per-host listing sort memory; the live model persists it.
  (int, bool)? rememberedSort(String hostId) => null;
  void rememberSort(String hostId, int column, bool ascending) {}
  SftpColumnLayout? rememberedColumns(String hostId) => null;
  void rememberColumns(String hostId, SftpColumnLayout layout) {}

  Future<void> openTemporaryHost(DemoHost host) =>
      Future.error(UnsupportedError('模拟模式不建立临时SSH连接'));

  void openHost(DemoHost host) {
    final s = createSession('s${_next()}', host);
    final t = TerminalTab('tab${_next()}', s.id, host.name);
    _sessions[s.id] = s;
    var g = focusedGroup;
    if (g == null) {
      g = TabGroup('g${_next()}', t);
      tabGroups[g.id] = g;
      root = GroupLeaf(g.id);
    } else {
      g.tabs.add(t);
    }
    focusedGroupId = g.id;
    g.selectedId = t.id;
    if (!recent.contains(host.id)) recent.insert(0, host.id);
    selectTab(t.id);
  }

  void demo() {
    openHost(hosts[0]);
    openHost(hosts[1]);
    openHost(hosts[3]);
    focus!.disconnected = true;
    final panes = sessions;
    transfers.addAll([
      DemoTransfer(
        't${_next()}',
        panes[0].id,
        'release-2026.10/',
        true,
        TransferState.active,
        .68,
        folder: true,
      ),
      DemoTransfer(
        't${_next()}',
        panes[0].id,
        'application.log',
        false,
        TransferState.waiting,
        0,
      ),
      DemoTransfer(
        't${_next()}',
        panes[0].id,
        'assets/',
        true,
        TransferState.partial,
        .94,
        folder: true,
      ),
      DemoTransfer(
        't${_next()}',
        panes[0].id,
        'backup.tar.gz',
        false,
        TransferState.paused,
        .31,
      ),
      DemoTransfer(
        't${_next()}',
        panes[0].id,
        'config.yaml',
        true,
        TransferState.failed,
        .12,
      ),
      DemoTransfer(
        't${_next()}',
        panes[0].id,
        'README.md',
        false,
        TransferState.complete,
        1,
      ),
    ]);
    focusedGroup!.selectedId = tabs.first.id;
    allTasks = true;
    changed();
  }

  SplitTree? _removeGroup(SplitTree node, String id) {
    if (node is GroupLeaf) return node.groupId == id ? null : node;
    final s = node as GroupSplit;
    final a = _removeGroup(s.first, id), b = _removeGroup(s.second, id);
    if (a == null) return b;
    if (b == null) return a;
    s.first = a;
    s.second = b;
    return s;
  }

  void _detach(TabGroup g, TerminalTab t) {
    final index = g.tabs.indexOf(t);
    g.tabs.remove(t);
    if (g.tabs.isEmpty) {
      root = _removeGroup(root!, g.id);
      tabGroups.remove(g.id);
      if (maximizedGroupId == g.id) maximizedGroupId = null;
    } else if (g.selectedId == t.id) {
      g.selectedId = g.tabs[index.clamp(0, g.tabs.length - 1)].id;
    }
  }

  /// Move the existing tab. The registry is untouched, including connection state.
  void moveTab(
    String tabId,
    String targetId, {
    TabPlacement placement = TabPlacement.center,
    String? beforeTabId,
  }) {
    final from = groupOf(tabId),
        target = tabGroups[targetId],
        t = tabById(tabId);
    if (from == null || target == null || t == null) return;
    if (placement != TabPlacement.center &&
        from == target &&
        from.tabs.length == 1) {
      return;
    }
    if (placement == TabPlacement.center && from == target) {
      if (beforeTabId == t.id) return;
      // Reorder inside the same group, preserving the fixed-tab prefix.
      from.tabs.remove(t);
    } else {
      _detach(from, t);
    }
    TabGroup destination;
    if (placement == TabPlacement.center) {
      destination = target;
      var index = target.tabs.indexWhere((v) => v.id == beforeTabId);
      if (index < 0) index = target.tabs.length;
      final pins = target.tabs.where((v) => v.pinned).length;
      index = t.pinned
          ? index.clamp(0, pins)
          : index.clamp(pins, target.tabs.length);
      target.tabs.insert(index, t);
    } else {
      destination = TabGroup('g${_next()}', t);
      tabGroups[destination.id] = destination;
      final leading =
          placement == TabPlacement.left || placement == TabPlacement.top;
      final horizontal =
          placement == TabPlacement.left || placement == TabPlacement.right;
      SplitTree replace(SplitTree node) {
        if (node is GroupLeaf) {
          if (node.groupId != target.id) return node;
          return GroupSplit(
            horizontal,
            leading ? GroupLeaf(destination.id) : node,
            leading ? node : GroupLeaf(destination.id),
          );
        }
        final s = node as GroupSplit;
        s.first = replace(s.first);
        s.second = replace(s.second);
        return s;
      }

      root = replace(root!);
      maximizedGroupId = null;
    }
    selectTab(t.id);
  }

  bool canSplit(String tabId, String targetId) {
    final from = groupOf(tabId);
    return from != null &&
        tabGroups.containsKey(targetId) &&
        (from.id != targetId || from.tabs.length > 1);
  }

  void mergeGroups() {
    final target = focusedGroup;
    if (target == null || tabGroups.length < 2) return;
    final all = tabs;
    target.tabs
      ..clear()
      ..addAll(all.where((t) => t.pinned))
      ..addAll(all.where((t) => !t.pinned));
    tabGroups
      ..clear()
      ..[target.id] = target;
    root = GroupLeaf(target.id);
    maximizedGroupId = null;
    changed();
  }

  void maximize(String groupId) {
    if (!tabGroups.containsKey(groupId)) return;
    maximizedGroupId = maximizedGroupId == groupId ? null : groupId;
    focusedGroupId = groupId;
    changed();
  }

  void closeTab(String id) {
    final t = tabById(id), g = groupOf(id);
    if (t == null || g == null) return;
    _detach(g, t);
    _sessions.remove(t.sessionId);
    if (!tabGroups.containsKey(focusedGroupId)) {
      focusedGroupId = root?.groupIds.firstOrNull;
    }
    if (root == null) startPage = true;
    changed();
  }

  void togglePin(String id) {
    final t = tabById(id), g = groupOf(id);
    if (t == null || g == null) return;
    g.tabs.remove(t);
    t.pinned = !t.pinned;
    g.tabs.insert(g.tabs.where((v) => v.pinned).length, t);
    changed();
  }

  void setDisconnected(String id, bool value) {
    final t = tabById(id);
    if (t == null) return;
    final s = session(t);
    if (!value && s.disconnected) s.connectionGeneration++;
    s.disconnected = value;
    changed();
  }

  void toggleSidebar() {
    sidebar = !sidebar;
    changed();
  }

  void queueToggle() {
    sidebar = true;
    queueMaximized = !queueMaximized;
    filesMaximized = false;
    changed();
  }

  List<DemoTransfer> get visibleTransfers =>
      transfers.where((t) => allTasks || t.sessionId == focus?.id).toList();
  void setTransfer(Iterable<String> ids, TransferState state) {
    for (final t in transfers.where((t) => ids.contains(t.id))) {
      t.state = state;
      if (state == TransferState.complete) t.progress = 1;
    }
    changed();
  }

  void addTransfer(String name, {required bool upload, bool folder = false}) {
    if (focus == null) return;
    transfers.add(
      DemoTransfer(
        't${_next()}',
        focus!.id,
        name,
        upload,
        TransferState.waiting,
        0,
        folder: folder,
      ),
    );
    changed();
  }

  void saveHost(DemoHost host) {
    final index = hosts.indexWhere((h) => h.id == host.id);
    if (index < 0) {
      hosts.add(host);
    } else {
      hosts[index] = host;
    }
    changed();
  }

  final _pathBookmarks = <PathBookmark>[];
  Future<List<PathBookmark>> listPathBookmarks(TerminalSession session) async =>
      _pathBookmarks
          .where((b) => b.hostId == null || b.hostId == session.host.id)
          .toList();
  Future<void> savePathBookmark(
    TerminalSession session, {
    required String name,
    required String path,
    required bool global,
    String? id,
  }) async {
    if (name.trim().isEmpty ||
        !path.startsWith('/') ||
        path.contains('\u0000')) {
      throw StateError('请输入名称和有效的绝对远端路径');
    }
    final bookmark = PathBookmark(
      id ?? nextId(),
      name.trim(),
      path,
      global ? null : session.host.id,
    );
    final index = _pathBookmarks.indexWhere((b) => b.id == id);
    if (id != null && index < 0) throw StateError('书签已不存在');
    if (index < 0) {
      _pathBookmarks.add(bookmark);
    } else {
      _pathBookmarks[index] = bookmark;
    }
  }

  Future<void> deletePathBookmark(String id) async {
    _pathBookmarks.removeWhere((b) => b.id == id);
  }

  Future<void> loadDirectory(
    TerminalSession session,
    String path, {
    bool remember = true,
    bool refresh = false,
  }) async {
    if (remember) {
      session.navigate(path);
    } else {
      session.path = path;
    }
    session.sftpEnabled = true;
    changed();
  }

  Future<void> renameRemote(
    TerminalSession session,
    DemoFile file,
    String name,
  ) async {
    file.name = name;
    changed();
  }

  final _followingDirectories = <String>{};
  bool followsTerminalDirectory(TerminalSession session) =>
      _followingDirectories.contains(session.id);
  Future<void> setTerminalDirectoryFollow(
    TerminalSession session,
    bool value,
  ) async {
    if (value) {
      _followingDirectories.add(session.id);
    } else {
      _followingDirectories.remove(session.id);
    }
    changed();
  }

  Future<void> jumpToTerminalDirectory(TerminalSession session) async =>
      throw UnsupportedError('模拟会话没有真实终端目录');
  Future<void> createRemoteFile(TerminalSession session, String name) async {
    session.files.add(
      DemoFile(nextId(), name, kind: '文件', size: '0 B', byteSize: 0),
    );
    changed();
  }

  Future<void> createRemoteDirectory(
    TerminalSession session,
    String name,
  ) async {
    session.files.add(DemoFile(nextId(), name, folder: true, kind: '文件夹'));
    changed();
  }

  Future<RemoteDeleteResult> deleteRemoteFiles(
    TerminalSession session,
    List<DemoFile> files,
  ) => deleteRemotePaths(session, files.map((f) => f.id).toList());

  /// Path-only variant the failure dialog's retry uses; the live model sends
  /// exactly these paths in one batched call.
  Future<RemoteDeleteResult> deleteRemotePaths(
    TerminalSession session,
    List<String> paths,
  ) async {
    session.files.removeWhere((f) => paths.contains(f.id));
    changed();
    return RemoteDeleteResult(succeeded: List.of(paths), failed: const []);
  }

  Future<void> moveRemoteFiles(
    TerminalSession session,
    String source,
    List<DemoFile> files,
    String destination,
  ) async {
    throw UnsupportedError('远端移动服务尚未接入');
  }

  Future<DemoHost> persistHost(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async {
    saveHost(host);
    return host;
  }

  Future<DemoHost> copyHost(DemoHost host) async => host.copy(nextId());
  Future<void> deleteHosts(Set<String> ids) async {
    hosts.removeWhere((h) => ids.contains(h.id));
    changed();
  }

  Future<void> persistDraft(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async {}
  Future<void> discardDraft(String id) async {}
  DemoHost? recoveredDraft(String id) => null;
  List<DemoHost> get recoverableDrafts => const [];
  Future<void> batchHosts(
    Set<String> ids, {
    String? group,
    bool? favorite,
  }) async {
    for (final h in hosts.where((h) => ids.contains(h.id))) {
      if (group != null) h.group = group;
      if (favorite != null) h.favorite = favorite;
    }
    changed();
  }

  String nextId() => 'demo${_next()}';
}
