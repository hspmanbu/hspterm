import 'image_paste_binding.dart';
import 'shutdown_intent.dart';
import '../run_log.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;

import '../src/rust/api.dart' as rust;
import '../src/rust/tmux.dart' as tmx;
import 'backend.dart';
import 'notifications.dart';

typedef TerminalTransportInfo = ({
  int? rttMicros,
  int? columns,
  int? rows,
  bool? sizeLocked,
});

class TerminalController extends ChangeNotifier {
  final transportInfo = ValueNotifier<TerminalTransportInfo>((
    rttMicros: null,
    columns: null,
    rows: null,
    sizeLocked: null,
  ));
  void _roundTrip(int? sample) {
    final old = transportInfo.value;
    transportInfo.value = (
      rttMicros: sample,
      columns: old.columns,
      rows: old.rows,
      sizeLocked: old.sizeLocked,
    );
  }

  TerminalController(this.backend);
  final TerminalBackend backend;
  int? id;
  String phase = 'Idle';
  String? error;
  String? reconnectNotice;
  int _connectNoticeEpoch = 0;
  void dismissReconnectNotice() {
    reconnectNotice = null;
    if (!_disposed) notifyListeners();
  }

  String? profileId;
  String connectionLabel = '当前SSH终端';
  String title = 'HSPTerm';
  bool visible = true;
  double fontZoom = 0;
  rust.RenderFrame? metadata;
  List<List<rust.RenderCell>> rows = [];
  List<int> rowVersions = [];
  List<List<rust.RenderHyperlink>> hyperlinks = [];
  Point<int>? selectionStart, selectionEnd;
  int frameCount = 0;
  int reconnectCount = 0;
  int generation = 0;
  int directoryReportVersion = 0;
  String? reportedDirectory;
  Future<void> _inputTail = Future.value();
  Future<void> _ordered(Future<void> Function(int) action) {
    final value = id, expected = generation;
    if (value == null) return Future.value();
    return _inputTail = _inputTail
        .then((_) async {
          if (!_disposed && connected && expected == generation) {
            await action(value);
          }
        })
        .catchError(report);
  }

  bool _disposed = false;
  bool _notifiersDisposed = false;
  Future<void>? _startFuture;
  StreamSubscription<rust.BridgeEvent>? _subscription;
  final _streamClosed = Completer<void>();
  Future<void> _frameTail = Future.value();
  Future<void> _visibilityTail = Future.value();
  Future<void> _nativeVisibility(int value, bool shown) =>
      _visibilityTail = _visibilityTail
          .then((_) async {
            if (!_disposed) await backend.visible(value, shown);
          })
          .catchError(report);
  Timer? _resizeTimer;
  Timer? _searchTimer;
  int _searchToken = 0;
  String searchQuery = '';
  bool searchRegex = false, searchCaseSensitive = false, searchBusy = false;
  String? searchError;
  rust.SearchSummary? searchSummary;
  rust.SearchLocation? activeSearch;
  int searchOrdinal = -1;
  DateTime? _connectingSince;

  bool osc52Enabled = true;
  bool rightClickPaste = false;
  bool copyOnSelection = false;
  ImagePasteBinding imagePasteBinding = const ImagePasteBinding();
  int newOutputLines = 0;
  (int, int, int, int)? _desiredSize;
  Future<bool> Function(rust.BridgeEvent)? confirmHostKey;
  Future<tmx.TmuxSelection?> Function(tmx.TmuxPrompt)? chooseTmux;
  final _shutdownIntent = ShutdownIntent();
  bool manualReconnectRequired = false;
  String? _tmuxPane;
  DateTime? _tmuxShellAt;
  bool _tmuxShell = false;
  void reportTmuxShell(String pane, bool shell) {
    if (_tmuxPane != pane || _tmuxShell != shell) _shutdownIntent.invalidate();
    // A fresh pane has its own input line. Do not inherit partial input.
    if (shell && (_tmuxPane != pane || !_tmuxShell)) {
      _shutdownIntent.cancelLine();
    }
    _tmuxPane = pane;
    _tmuxShell = shell;
    _tmuxShellAt = DateTime.now();
  }

  bool get _shutdownInputEligible => tmuxReadonly != null
      ? tmuxReadonly == false &&
            _tmuxShell &&
            _tmuxShellAt != null &&
            DateTime.now().difference(_tmuxShellAt!) <
                const Duration(seconds: 4)
      : shellInputReady ||
            (metadata != null &&
                !metadata!.alternateScreen &&
                !metadata!.mouseReporting);
  void _trackPowerKey(rust.KeyboardInput input) {
    if (input.kind == 2) return;
    if (!_shutdownInputEligible) {
      _shutdownIntent.invalidate();
      return;
    }
    if (input.key == 'Enter' && input.modifiers == 0) {
      _shutdownIntent.enter();
      return;
    }
    if (input.key == 'Backspace' && input.modifiers == 0) {
      _shutdownIntent.backspace();
      return;
    }
    if (input.modifiers == 4 && ['u', 'U', 'c', 'C'].contains(input.key)) {
      _shutdownIntent.cancelLine();
      return;
    }
    if (['Shift', 'Control', 'Alt', 'Meta'].contains(input.key)) return;
    if ((input.modifiers & ~1) == 0 && input.text?.isNotEmpty == true) {
      _shutdownIntent.text(input.text!);
    } else {
      _shutdownIntent.invalidate();
    }
  }

  int? _tmuxToken;
  bool? tmuxReadonly;

  /// Display name of the tmux session this terminal joined (create or
  /// attach); null for a plain SSH shell. Tabs and session lists read it.
  /// Deliberately not cleared on reconnect: Rust auto-restore replays a
  /// previously confirmed session identity without a new dialog, and a new
  /// dialog choice simply overwrites it here.
  String? tmuxSessionName;
  // Encrypted SSH preferences; applied to live tmux tabs without reconnect.
  bool tmuxLocalSelection = true;
  bool tmuxShiftEnterLf = false;
  void setTmuxLocalSelection(bool value) {
    tmuxLocalSelection = value;
    notifyListeners();
  }

  void setTmuxShiftEnterLf(bool value) {
    tmuxShiftEnterLf = value;
    notifyListeners();
  }

  int? _tmuxStateGeneration;
  bool? _pendingTmuxMode;

  /// Small runtime invalidation only; it never repaints terminal cells or
  /// notifies the whole workbench. A visible management view may subscribe.
  final forwardingChanges = ValueNotifier<int>(0);
  final agentChanges = ValueNotifier<int>(0);
  final notices = ValueNotifier<RemoteTerminalNotice?>(null);
  String? notificationPolicy;
  int? _notificationPolicyGeneration;
  bool acceptsNotice(RemoteTerminalNotice notice) =>
      !_disposed &&
      connected &&
      _notificationPolicyGeneration == generation &&
      notificationPolicy == notice.policy;

  /// Source-bound dialogs can retire without repainting a disposing view.
  final closingChanges = ValueNotifier<bool>(false);
  final shellInputChanges = ValueNotifier<int>(0);

  /// True while the private plain-shell input proof is ready. An exited TUI
  /// often leaves mouse reporting on; forwarding events then only feeds the
  /// shell echo stream, so the view keeps them local instead.
  bool shellInputReady = false;
  Future<void> flushInput() async {
    // Input can be appended while a controlled operation is awaiting its ACK.
    // Read candidates only after the latest tail, not an earlier snapshot.
    while (!_disposed) {
      final pending = _inputTail;
      await pending;
      if (identical(pending, _inputTail)) return;
    }
  }

  /// Keep controlled actions ordered with real keys/IME commits. A stale source
  /// is proved unsent; an unknown native outcome is never repeated here.
  bool composing = false;

  Future<String> controlledInput(Future<String> Function(int, int) action) {
    _shutdownIntent.invalidate();
    final native = id, expected = generation;
    if (_disposed || composing || !connected || native == null) {
      return Future.value('Unavailable');
    }
    final work = _inputTail.then((_) async {
      if (_disposed ||
          composing ||
          !connected ||
          id != native ||
          generation != expected) {
        return 'Unavailable';
      }
      return action(native, expected);
    });
    _inputTail = work.then<void>(
      (_) {},
      onError: (Object error) {
        report(error);
      },
    );
    // External controlled actions (for example an SFTP path drop) must retire
    // visible candidates immediately, before another local Enter can select
    // a stale prefix. This notifier never repaints the terminal grid.
    if (!_notifiersDisposed) shellInputChanges.value++;
    return work;
  }

  /// Refresh non-secret target metadata before an explicit connection attempt.
  FutureOr<void> Function()? prepareConnection;
  Future<void> Function(int id, String profileId)? connectRequest;
  Future<void> Function()? reconnectRequest;
  bool _requestingReconnect = false;
  bool get connected => !_disposed && phase == 'Connected';
  bool get isClosing => _disposed;
  bool get shutdownComplete => _shutdownComplete;

  Future<void> start() {
    if (_disposed) return Future.value();
    return _startFuture ??= _start();
  }

  Future<void> _start() async {
    final value = await backend.create();
    // Shutdown owns even a late handle. Never lose it if native close fails.
    id = value;
    if (_disposed) return;
    if (!visible) await _nativeVisibility(value, false);
    if (_disposed) return;
    _subscription = backend
        .watch(value)
        .listen(
          (event) => unawaited(_event(value, event).catchError(report)),
          onError: (Object failure) => report(failure),
          onDone: () {
            if (!_streamClosed.isCompleted) _streamClosed.complete();
          },
        );
    final desired = _desiredSize;
    if (desired != null) {
      await backend.resize(
        value,
        desired.$1,
        desired.$2,
        desired.$3,
        desired.$4,
      );
    }
  }

  Future<void> _chooseTmux(int value, rust.BridgeEvent event) async {
    if (_tmuxToken == event.requestId) return;
    final token = event.requestId, expected = event.generation;
    _tmuxToken = token;
    bool current() =>
        !_disposed &&
        id == value &&
        generation == expected &&
        phase == 'Connecting';
    tmx.TmuxSelection? choice;
    tmx.TmuxPrompt? prompt;
    try {
      prompt = await backend.tmuxPrompt(value, token);
      // The independently coalesced status event can follow this prompt. The
      // native read validates its actual original Connecting attempt first.
      if (!_disposed &&
          id == value &&
          generation < expected &&
          prompt.generation == expected &&
          phase != 'Closed') {
        reportedDirectory = null;
        directoryReportVersion++;
        generation = expected;
        phase = 'Connecting';
        error = null;
        notifyListeners();
      }
      if (current() && prompt.generation == expected) {
        choice = await chooseTmux?.call(prompt);
      }
    } catch (failure) {
      if (current()) report(failure);
    } finally {
      if (!current()) choice = null;
      tmuxSessionName = _tmuxDisplayName(prompt, choice);
      notifyListeners();
      try {
        await backend.answerTmux(
          value,
          expected,
          token,
          choice ??
              const tmx.TmuxSelection(
                kind: 0,
                readonly: false,
                takeoverConfirmed: false,
                lockSize: false,
              ),
        );
      } catch (failure) {
        if (current()) report(failure);
      }
    }
  }

  /// The joined session's display name: the typed name for a created session,
  /// the listing entry for an attached one, null for plain shells/cancel.
  String? _tmuxDisplayName(tmx.TmuxPrompt? prompt, tmx.TmuxSelection? choice) {
    final c = choice;
    if (c == null || prompt == null) return null;
    switch (c.kind) {
      case 2:
        return c.name;
      case 3:
        for (final s in prompt.sessions) {
          if (s.id == c.sessionId) return s.name;
        }
        return null;
      default:
        return null;
    }
  }

  void report(Object failure) {
    AppRunLog.instance.event(
      AppLogEvent.terminalFailed,
      terminal: id,
      generation: generation,
      error: failure,
      stack: StackTrace.current,
    );
    if (_disposed) return;
    // Rust has already reduced these to the audited public error boundary.
    // Event-stream details use the same message; do not expose the FFI wrapper
    // or change an existing cancellation merely because its Future completes late.
    error = failure is AnyhowException ? failure.message : failure.toString();
    notifyListeners();
  }

  // Native clipboard events exist only after SSH authentication. The separately
  // delivered status stream may still show Connecting for the same generation.
  bool _clipboardAllowed(int requestGeneration) =>
      osc52Enabled &&
      requestGeneration == generation &&
      (phase == 'Connected' || phase == 'Connecting');

  Future<void> _event(int value, rust.BridgeEvent event) async {
    if (_disposed) return;
    switch (event.kind) {
      case 'frame':
        _frameTail = _frameTail
            .then((_) async {
              if (_disposed) return;
              final started = DateTime.now();
              final frame = await backend.frame(value);
              final pullMs = DateTime.now().difference(started).inMilliseconds;
              // Slow frame pulls signal FRB/Rust backlog long before the UI
              // visibly stalls; numbers only, never frame content.
              if (pullMs > 200) {
                AppRunLog.instance.event(
                  AppLogEvent.frameJank,
                  terminal: value,
                  count: pullMs,
                  fields: {'kind': 'pull', 'durationMs': pullMs},
                );
              }
              if (!_disposed && frame != null) applyFrame(frame);
            })
            .catchError(report);
        await _frameTail;
      case 'status':
        final newlyConnected =
            event.text == 'Connected' &&
            (phase != 'Connected' || generation != event.generation);
        if (newlyConnected && _connectingSince != null) {
          AppRunLog.instance.event(
            AppLogEvent.connectionTiming,
            terminal: value,
            generation: event.generation,
            fields: {
              'durationMs': DateTime.now()
                  .difference(_connectingSince!)
                  .inMilliseconds,
            },
          );
          _connectingSince = null;
        }
        if (event.text == 'Connecting') _connectingSince = DateTime.now();
        if (generation != event.generation ||
            (event.text != 'Connected' && event.text != 'Connecting')) {
          reportedDirectory = null;
          directoryReportVersion++;
        }
        if (generation != event.generation) {
          tmuxReadonly = _tmuxStateGeneration == event.generation
              ? _pendingTmuxMode
              : null;
        }
        if (generation != event.generation || event.text == 'Connecting') {
          _shutdownIntent.reset();
          manualReconnectRequired = false;
          _tmuxPane = null;
          _tmuxShellAt = null;
        }
        if (phase == 'Connected' &&
            event.text == 'Disconnected' &&
            _shutdownIntent.pending) {
          manualReconnectRequired = true;
        }
        generation = event.generation;
        phase = event.text ?? phase;
        error = manualReconnectRequired && phase == 'Disconnected'
            ? '检测到服务器重启/关机，请手动重连。'
            : event.detail;
        _roundTrip(connected ? event.rttMicros : null);
        notifyListeners();
        // A host-key/tmux choice can outlive a layout change. Startup used its
        // captured PTY size; replay the latest layout once after connection.
        // Rust's actual size lock remains authoritative and rejects resizing.
        if (newlyConnected) _scheduleResize();
      case 'latency':
        if (connected && generation == event.generation) {
          _roundTrip(event.rttMicros);
        }
        break;
      case 'agent':
        if (event.generation == generation) {
          agentChanges.value++;
        }
        break;
      case 'forwardings':
        if (event.generation == generation) {
          forwardingChanges.value++;
        }
      case 'workingDirectory':
        if (event.generation != generation ||
            (!connected && phase != 'Connecting')) {
          return;
        }
        // A trigger only. The model must validate the original actual SSH endpoint in Rust.
        reportedDirectory = event.text;
        directoryReportVersion++;
        notifyListeners();
      case 'tmuxState':
        if (event.generation < generation ||
            !['shell', 'readonly', 'control'].contains(event.text)) {
          return;
        }
        _tmuxStateGeneration = event.generation;
        _pendingTmuxMode = event.text == 'shell'
            ? null
            : event.text == 'readonly';
        if (event.generation == generation) {
          tmuxReadonly = _pendingTmuxMode;
          _shutdownIntent.invalidate();
          _tmuxPane = null;
          _tmuxShellAt = null;
          if (event.text == 'shell') {
            shellInputReady = false;
            reportedDirectory = null;
            directoryReportVersion++;
            _shutdownIntent.cancelLine();
            _scheduleResize();
          }
          notifyListeners();
        }
      case 'tmux':
        await _chooseTmux(value, event);
      case 'hostKey':
      case 'jumpHostKey':
        var accepted = false;
        try {
          accepted = await confirmHostKey?.call(event) ?? false;
        } finally {
          // A failed UI confirmation must reject, not leave the remote handshake
          // waiting forever with its security-confirmation timeout paused.
          if (!_disposed) {
            await backend.hostKey(value, event.requestId, accepted);
          }
        }
      case 'clipboardWrite':
        if (!_clipboardAllowed(event.generation)) {
          return;
        }
        await Clipboard.setData(ClipboardData(text: event.text ?? ''));
      case 'clipboardRead':
        if (!_clipboardAllowed(event.generation)) {
          return;
        }
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (!_disposed && _clipboardAllowed(event.generation)) {
          await backend.clipboard(value, event.requestId, data?.text ?? '');
        }
      case 'shellInput':
        if (event.generation == generation) {
          shellInputReady = event.detail == 'ready';
          shellInputChanges.value++;
        }
      case 'historyWarning':
        if (event.generation == generation) {
          report(StateError('合格命令历史未获保存确认；终端输入继续。'));
        }
      case 'title':
        title = event.text ?? 'HSPTerm';
        notifyListeners();
      case 'reconnected':
        reconnectCount++;
        selectionStart = selectionEnd = null;
        notifyListeners();
      case 'bell':
        // A local visual signal; no terminal output is copied into diagnostics.
        notifyListeners();
      case 'notification':
        if (id == value &&
            connected &&
            generation == event.generation &&
            event.text != null) {
          final notice = RemoteTerminalNotice.decode(event.text!);
          if (acceptsNotice(notice)) notices.value = notice;
        }
      case 'notificationPolicy':
        if (id == value &&
            event.generation >= generation &&
            event.text != null &&
            RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(event.text!)) {
          if (notificationPolicy != event.text ||
              _notificationPolicyGeneration != event.generation) {
            notices.value = null;
          }
          notificationPolicy = event.text;
          _notificationPolicyGeneration = event.generation;
        }
    }
  }

  // Display-only refreshes must not change the user's real selection. Check
  // raw text and mapping flags as well as the content/viewport identity; this
  // also protects against malformed frames with an unchanged content revision.
  bool _selectionUnchanged(rust.RenderFrame frame) {
    final old = metadata, a = selectionStart, b = selectionEnd;
    if (old == null ||
        a == null ||
        b == null ||
        old.columns != frame.columns ||
        old.rows != frame.rows ||
        old.historyLines != frame.historyLines ||
        old.displayOffset != frame.displayOffset ||
        old.alternateScreen != frame.alternateScreen ||
        old.mouseReporting != frame.mouseReporting ||
        rows.length != frame.rows) {
      return false;
    }
    final reversed = a.y > b.y || (a.y == b.y && a.x > b.x);
    final start = reversed ? b : a, end = reversed ? a : b;
    for (final row in frame.changedRows) {
      if (row.index < start.y || row.index > end.y) continue;
      if (row.index >= rows.length ||
          row.cells.length != rows[row.index].length) {
        return false;
      }
      final before = rows[row.index],
          left = row.index == start.y ? start.x : 0,
          right = row.index == end.y ? end.x : before.length - 1;
      if (left < 0 || right >= before.length) return false;
      for (var x = left; x <= right; x++) {
        if (before[x].text != row.cells[x].text ||
            before[x].flags & (16 | 32 | 64 | 256 | 1024) !=
                row.cells[x].flags & (16 | 32 | 64 | 256 | 1024)) {
          return false;
        }
      }
    }
    return true;
  }

  void applyFrame(rust.RenderFrame frame) {
    if (_disposed) return;
    if (frame.osc52Enabled != null) osc52Enabled = frame.osc52Enabled!;
    if (frame.rightClickPaste != null) rightClickPaste = frame.rightClickPaste!;
    if (frame.copyOnSelection != null) copyOnSelection = frame.copyOnSelection!;
    if (frame.imagePasteShortcut != null) {
      imagePasteBinding = ImagePasteBinding.parse(
        jsonDecode(frame.imagePasteShortcut!) as Map<String, dynamic>,
      );
    }
    if (!_selectionUnchanged(frame)) selectionStart = selectionEnd = null;
    if (frame.full ||
        rows.length != frame.rows ||
        (rows.isNotEmpty && rows.first.length != frame.columns)) {
      rows = List.generate(frame.rows, (_) => <rust.RenderCell>[]);
      rowVersions = List.filled(frame.rows, 0);
      hyperlinks = List.generate(frame.rows, (_) => <rust.RenderHyperlink>[]);
    }
    for (final row in frame.changedRows) {
      if (row.index >= rows.length || row.cells.length != frame.columns) {
        report(StateError('终端增量尺寸不一致'));
        return;
      }
      rows[row.index] = row.cells;
      hyperlinks[row.index] = row.hyperlinks ?? const [];
      rowVersions[row.index] = frameCount + 1;
    }
    final previous = metadata;
    if (previous != null &&
        previous.contentRevision != frame.contentRevision &&
        searchQuery.isNotEmpty) {
      activeSearch = null;
      searchSummary = null;
      searchOrdinal = -1;
      _searchTimer?.cancel();
      _searchTimer = Timer(
        const Duration(milliseconds: 300),
        () => unawaited(runSearch(navigate: false)),
      );
    }
    if (frame.displayOffset == 0) {
      newOutputLines = 0;
    } else if (previous != null &&
        previous.columns == frame.columns &&
        previous.rows == frame.rows) {
      newOutputLines += (frame.outputLines - previous.outputLines).clamp(
        0,
        1000000,
      );
    }
    // Keep only the frame's scalar state as metadata. The delta rows are
    // already owned by [rows]; anchoring the original frame here would keep
    // the whole delta (cell lists included) alive until the next frame,
    // doubling the resident terminal data and feeding allocator churn.
    metadata = rust.RenderFrame(
      revision: frame.revision,
      contentRevision: frame.contentRevision,
      outputLines: frame.outputLines,
      sizeLocked: frame.sizeLocked,
      sameWordEnabled: frame.sameWordEnabled,
      sameWordCaseSensitive: frame.sameWordCaseSensitive,
      decorationsLimited: frame.decorationsLimited,
      searchRevision: frame.searchRevision,
      searchSpans: frame.searchSpans,
      columns: frame.columns,
      rows: frame.rows,
      full: frame.full,
      changedRows: const [],
      cursorColumn: frame.cursorColumn,
      cursorRow: frame.cursorRow,
      cursorVisible: frame.cursorVisible,
      cursorShape: frame.cursorShape,
      cursorBlink: frame.cursorBlink,
      osc52Enabled: frame.osc52Enabled,
      rightClickPaste: frame.rightClickPaste,
      copyOnSelection: frame.copyOnSelection,
      imagePasteShortcut: frame.imagePasteShortcut,
      cursorColor: frame.cursorColor,
      background: frame.background,
      alternateScreen: frame.alternateScreen,
      mouseReporting: frame.mouseReporting,
      historyLines: frame.historyLines,
      displayOffset: frame.displayOffset,
    );
    transportInfo.value = (
      rttMicros: transportInfo.value.rttMicros,
      columns: frame.columns,
      rows: frame.rows,
      sizeLocked: frame.sizeLocked,
    );
    frameCount++;
    notifyListeners();
  }

  Future<void> connect(String savedProfileId, {String? label}) async {
    final value = id;
    if (_disposed || value == null || phase == 'Connecting' || connected) {
      return;
    }
    profileId = savedProfileId;
    if (label != null) connectionLabel = label;
    phase = 'Connecting';
    _shutdownIntent.reset();
    manualReconnectRequired = false;
    error = null;
    reconnectNotice = null;
    final noticeEpoch = ++_connectNoticeEpoch;
    try {
      await prepareConnection?.call();
      if (_disposed ||
          id != value ||
          noticeEpoch != _connectNoticeEpoch ||
          closingChanges.value) {
        return;
      }
      notifyListeners();
      await (connectRequest?.call(value, savedProfileId) ??
          backend.connect(value, savedProfileId));
      final notices = backend;
      if (notices is TerminalReconnectNoticeBackend) {
        String? message;
        try {
          message = await (notices as TerminalReconnectNoticeBackend)
              .reconnectNotice(value);
        } catch (_) {
          message = 'SSH已连接，但未取得传输恢复报告；请检查任务队列。';
        }
        if (!_disposed && id == value && noticeEpoch == _connectNoticeEpoch) {
          reconnectNotice = message;
          notifyListeners();
        }
      }
    } catch (failure) {
      if (_disposed || noticeEpoch != _connectNoticeEpoch) return;
      phase = 'Failed';
      report(failure);
    }
  }

  Future<void> reconnect() async {
    if (_disposed ||
        connected ||
        phase == 'Connecting' ||
        _requestingReconnect) {
      return;
    }
    _requestingReconnect = true;
    try {
      if (reconnectRequest != null) {
        await reconnectRequest!();
      } else {
        final profile = profileId;
        if (profile != null) await connect(profile);
      }
    } catch (error) {
      report(error);
    } finally {
      _requestingReconnect = false;
    }
  }

  Future<void> key(rust.KeyboardInput input) async {
    final value = id;
    if (value == null) return;
    if (!connected) {
      if (input.key == 'Enter' &&
          input.kind == 0 &&
          (phase == 'Disconnected' || phase == 'Failed')) {
        await reconnect();
      }
      return;
    }
    try {
      if (tmuxReadonly != null &&
          tmuxShiftEnterLf &&
          input.key == 'Enter' &&
          input.modifiers == 1) {
        if (tmuxReadonly == true || input.kind == 2) return;
        await _ordered((id) async {
          if (_shutdownInputEligible) {
            _shutdownIntent.enter();
          } else {
            _shutdownIntent.invalidate();
          }
          await backend.text(id, '\n');
        });
        return;
      }
      await _ordered((id) async {
        _trackPowerKey(input);
        await backend.key(id, input);
      });
    } catch (failure) {
      report(failure);
    }
  }

  Future<void> text(String text) async {
    final value = id;
    if (value != null && connected && text.isNotEmpty) {
      try {
        await _ordered((id) async {
          if (_shutdownInputEligible) {
            _shutdownIntent.text(text);
          } else {
            _shutdownIntent.invalidate();
          }
          await backend.text(id, text);
        });
      } catch (failure) {
        report(failure);
      }
    }
  }

  /// Serializes a deferred upload-path insertion with ordinary terminal input.
  Future<void> enqueueImagePath(
    int expectedGeneration,
    Future<void> Function() send,
  ) {
    final result = Completer<void>();
    final value = id;
    _inputTail = _inputTail
        .then((_) async {
          if (_disposed ||
              !connected ||
              id != value ||
              generation != expectedGeneration) {
            throw StateError('图片粘贴所属连接已改变，未输入');
          }
          await send();
          result.complete();
        })
        .catchError((Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        });
    return result.future;
  }

  Future<rust.PasteResult> paste(String text, bool confirmed) {
    final result = Completer<rust.PasteResult>();
    final value = id, expected = generation;
    _inputTail = _inputTail
        .then((_) async {
          if (value == null ||
              _disposed ||
              !connected ||
              generation != expected) {
            throw StateError('粘贴所属连接已结束');
          }
          final pasted = await backend.paste(value, text, confirmed);
          if (!pasted.needsConfirmation) {
            if (_shutdownInputEligible) {
              _shutdownIntent.text(text);
            } else {
              _shutdownIntent.invalidate();
            }
          }
          result.complete(pasted);
        })
        .catchError((Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        });
    return result.future;
  }

  Future<void> mouse(
    int column,
    int row,
    int action,
    int button,
    int modifiers,
  ) => _ordered(
    (value) => backend.mouse(value, column, row, action, button, modifiers),
  );
  Future<void> focus(bool value) => _ordered((id) => backend.focus(id, value));
  Future<void> scroll(int lines) async {
    final value = id;
    if (!_disposed && value != null) await backend.scroll(value, lines);
  }

  Future<void> seek(int topRow) async {
    final value = id;
    if (!_disposed && value != null) await backend.seek(value, topRow);
  }

  bool get commandOperationsAvailable => backend is TerminalCommandsBackend;
  Future<String?> copyCommandAt(int row, int column, int revision) async {
    final source = backend, value = id, originalGeneration = generation;
    if (source is! TerminalCommandsBackend ||
        value == null ||
        _disposed ||
        phase == 'Connecting' ||
        phase == 'Closed') {
      return null;
    }
    final text = await (source as TerminalCommandsBackend).copyCommandAt(
      value,
      originalGeneration,
      revision,
      row,
      column,
    );
    if (_disposed ||
        id != value ||
        generation != originalGeneration ||
        phase == 'Connecting' ||
        phase == 'Closed') {
      return null;
    }
    return text;
  }

  Future<void> navigateCommand(bool next, int topRow, int revision) async {
    final source = backend, value = id, originalGeneration = generation;
    if (source is! TerminalCommandsBackend ||
        value == null ||
        _disposed ||
        phase == 'Connecting' ||
        phase == 'Closed') {
      return;
    }
    await (source as TerminalCommandsBackend).navigateCommand(
      value,
      originalGeneration,
      revision,
      topRow,
      next,
    );
  }

  Future<void> lockSize(bool locked) async {
    if (_disposed) return;
    final value = id;
    if (value != null) {
      await backend.lockSize(value, locked);
      final desired = _desiredSize;
      if (!_disposed && !locked && desired != null) {
        await backend.resize(
          value,
          desired.$1,
          desired.$2,
          desired.$3,
          desired.$4,
        );
      }
    }
  }

  Future<void> setOsc52(bool enabled) async {
    if (_disposed) return;
    final value = id;
    final previous = osc52Enabled;
    osc52Enabled = enabled;
    if (!_disposed) notifyListeners();
    try {
      if (value != null) await backend.clipboardEnabled(value, enabled);
    } catch (_) {
      osc52Enabled = previous;
      if (!_disposed) notifyListeners();
      rethrow;
    }
  }

  Future<void> setSearch(
    String query, {
    bool? regex,
    bool? caseSensitive,
  }) async {
    if (_disposed) return;
    searchQuery = query;
    searchRegex = regex ?? searchRegex;
    searchCaseSensitive = caseSensitive ?? searchCaseSensitive;
    _searchTimer?.cancel();
    _searchToken++;
    searchSummary = null;
    activeSearch = null;
    searchOrdinal = -1;
    searchError = null;
    if (query.isEmpty) {
      final value = id;
      if (value != null) await backend.search(value, '', false, false);
      if (!_disposed) notifyListeners();
      return;
    }
    _searchTimer = Timer(
      const Duration(milliseconds: 200),
      () => unawaited(runSearch()),
    );
    if (!_disposed) notifyListeners();
  }

  Future<void> runSearch({bool navigate = true}) async {
    final value = id;
    if (value == null || _disposed || searchQuery.isEmpty) return;
    _searchTimer?.cancel();
    final token = ++_searchToken;
    searchBusy = true;
    searchError = null;
    notifyListeners();
    try {
      final summary = await backend.search(
        value,
        searchQuery,
        searchRegex,
        searchCaseSensitive,
      );
      if (_disposed || token != _searchToken) return;
      if (summary.revision != metadata?.contentRevision) {
        searchSummary = null;
        return;
      }
      searchSummary = summary;
      searchOrdinal = -1;
      activeSearch = null;
      if (navigate && summary.count > 0) await navigateSearch(1);
    } catch (error) {
      if (!_disposed && token == _searchToken) searchError = error.toString();
    } finally {
      if (!_disposed && token == _searchToken) {
        searchBusy = false;
        notifyListeners();
      }
    }
  }

  Future<void> navigateSearch(int direction) async {
    final value = id, summary = searchSummary;
    if (_disposed ||
        value == null ||
        summary == null ||
        summary.count == 0 ||
        summary.revision != metadata?.contentRevision) {
      return;
    }
    final ordinal = (searchOrdinal + direction) % summary.count;
    try {
      final location = await backend.navigate(value, ordinal);
      if (!_disposed && location.revision == metadata?.contentRevision) {
        activeSearch = location;
        searchOrdinal = ordinal;
        notifyListeners();
      }
    } catch (error) {
      if (!_disposed) {
        searchError = error.toString();
        notifyListeners();
      }
    }
  }

  void dismissError(String expected) {
    if (error != expected) return;
    error = null;
    notifyListeners();
  }

  void resize(int columns, int lines, double width, double height) {
    // Minimized/hidden surfaces can report a zero viewport. Sending a 2x2
    // clamped PTY destroys TUI geometry and needlessly reflows all history.
    if (_disposed ||
        columns < 2 ||
        lines < 2 ||
        !width.isFinite ||
        !height.isFinite) {
      return;
    }
    final desired = (
      columns.clamp(2, 4096),
      lines.clamp(2, 4096),
      width.round().clamp(1, 65535),
      height.round().clamp(1, 65535),
    );
    if (desired == _desiredSize) return;
    _desiredSize = desired;
    _scheduleResize();
  }

  void _scheduleResize() {
    _resizeTimer?.cancel();
    final desired = _desiredSize;
    if (desired == null || _disposed || !visible) return;
    _resizeTimer = Timer(const Duration(milliseconds: 60), () async {
      final value = id;
      if (value == null || _disposed) return;
      final expected = generation;
      try {
        await backend.resize(
          value,
          desired.$1,
          desired.$2,
          desired.$3,
          desired.$4,
        );
      } catch (failure) {
        if (!_disposed && id == value && generation == expected) {
          report(failure);
        }
      }
    });
  }

  Future<void> setVisible(bool value) async {
    if (_disposed) return;
    if (visible == value) return;
    visible = value;
    if (value) {
      _scheduleResize();
    } else {
      _resizeTimer?.cancel();
    }
    final terminal = id;
    if (terminal != null) await _nativeVisibility(terminal, value);
    // A snapshot already taken by Rust advances its delta baseline. Drain that
    // reply before hiding completes; discarding it would corrupt the next delta.
    if (!value) await _frameTail;
    if (!_disposed) notifyListeners();
  }

  void clearSelection() {
    if (_disposed) return;
    selectionStart = selectionEnd = null;
    notifyListeners();
  }

  void select(Point<int> start, Point<int> end) {
    if (_disposed) return;
    // Selection boundaries snap to whole wide (CJK) glyphs:
    // - the start never begins inside a wide glyph's trailing half;
    // - the end always covers the wide glyph it lands on, so the box's
    //   right edge matches the glyph the pointer is over (2026-11-06
    //   feedback: dragging over Chinese cut the pointed-at character).
    Point<int> snapStart(Point<int> p) {
      if (p.y >= 0 &&
          p.y < rows.length &&
          p.x > 0 &&
          p.x < rows[p.y].length &&
          rows[p.y][p.x].flags & 64 != 0) {
        return Point(p.x - 1, p.y);
      }
      return p;
    }

    Point<int> snapEnd(Point<int> p) {
      if (p.y >= 0 && p.y < rows.length && p.x >= 0 && p.x < rows[p.y].length) {
        final cell = rows[p.y][p.x];
        // Wide glyph lead cell: extend over its trailing half.
        if (cell.flags & 32 != 0 && p.x + 1 < rows[p.y].length) {
          return Point(p.x + 1, p.y);
        }
      }
      return p;
    }

    // Drag direction does not determine which endpoint is the left edge.
    // Normalize the geometric boundaries first, then preserve direction for
    // callers that inspect the original anchor/focus order.
    final reversed = start.y > end.y || (start.y == end.y && start.x > end.x);
    final left = snapStart(reversed ? end : start);
    final right = snapEnd(reversed ? start : end);
    selectionStart = reversed ? right : left;
    selectionEnd = reversed ? left : right;
    notifyListeners();
  }

  String selectedText() {
    final a = selectionStart, b = selectionEnd;
    if (a == null || b == null || rows.isEmpty) return '';
    final reversed = a.y > b.y || (a.y == b.y && a.x > b.x);
    final start = reversed ? b : a, end = reversed ? a : b;
    final out = StringBuffer();
    for (var y = start.y; y <= end.y && y < rows.length; y++) {
      if (y < 0 || rows[y].isEmpty) continue;
      final row = rows[y];
      final left = y == start.y ? start.x : 0;
      final right = y == end.y ? end.x : row.length - 1;
      final text = StringBuffer();
      for (var x = left; x <= right && x < row.length; x++) {
        if (x >= 0 && row[x].flags & (64 | 1024) == 0) text.write(row[x].text);
      }
      final value = text.toString();
      out.write(
        row.last.flags & 16 != 0 || right < row.length - 1
            ? value
            : value.replaceFirst(RegExp(r' +$'), ''),
      );
      if (y < end.y && row.last.flags & 16 == 0) out.write('\n');
    }
    return out.toString();
  }

  Future<void>? _shutdownFuture;
  bool _nativeClosed = false, _shutdownComplete = false;

  /// Permanently stops interaction. Failures retain the native handle/stream
  /// owner for an explicit retry; they never make this controller reusable.
  Future<void> shutdown() {
    if (!_disposed) {
      _disposed = true;
      phase = 'Closing';
      _connectNoticeEpoch++;
      _resizeTimer?.cancel();
      _searchTimer?.cancel();
      _searchToken++;
      if (!_notifiersDisposed) closingChanges.value = true;
      notifyListeners();
    }
    return _shutdownFuture ??= _shutdown().catchError((
      Object error,
      StackTrace stack,
    ) {
      _shutdownFuture = null;
      this.error = '终端关闭收尾未确认，请重试关闭。不会重新连接。';
      notifyListeners();
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _shutdown() async {
    // A create request cannot be cancelled. Its eventual handle must belong to
    // this same retryable shutdown, including after ChangeNotifier disposal.
    try {
      await _startFuture;
    } catch (_) {
      // Startup reports its own failure; any allocated handle is still below.
    }
    await _visibilityTail;
    await _frameTail;
    await _inputTail;
    if (!_nativeClosed) {
      final value = id;
      if (value != null) await backend.close(value);
      _nativeClosed = true;
      id = null;
    }
    // Native close confirmation and FRB port retirement are separate phases.
    // A stream timeout must not repeat a successfully acknowledged destroy.
    if (_subscription != null) {
      await _streamClosed.future.timeout(const Duration(seconds: 5));
      await _subscription!.cancel();
      _subscription = null;
    }
    phase = 'Closed';
    error = null;
    _shutdownComplete = true;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_notifiersDisposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_notifiersDisposed) return;
    // The workbench retains retiring controllers and awaits shutdown itself.
    // Dispose must not emit an unhandled error or erase its retryable owner.
    _notifiersDisposed = true;
    unawaited(shutdown().catchError((Object _) {}));
    forwardingChanges.dispose();
    agentChanges.dispose();
    notices.dispose();
    closingChanges.dispose();
    shellInputChanges.dispose();
    transportInfo.dispose();
    super.dispose();
  }
}
