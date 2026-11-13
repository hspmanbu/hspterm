import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'backend.dart';
import '../app_notice.dart' show appMessage;
import 'controller.dart';

class TmuxHistorySnapshot {
  TmuxHistorySnapshot(String raw) {
    final value = jsonDecode(raw) as Map<String, dynamic>;
    pane = value['pane'] as String;
    history = value['history'] as int;
    offset = value['offset'] as int;
    rows = value['rows'] as int;
    available = value['available'] as bool;
    readonly = value['readonly'] as bool;
    shell = value['shell'] == true;
    if (!RegExp(r'^%[0-9]{1,12}$').hasMatch(pane) ||
        history < 0 ||
        history > 10000000 ||
        offset < 0 ||
        offset > history ||
        rows < 1 ||
        rows > 65535) {
      throw const FormatException('tmux历史响应无效');
    }
  }
  late final String pane;
  late final int history, offset, rows;
  late final bool available, readonly, shell;
}

/// Metadata only; one request at a time, only for a visible attached terminal.
/// Seeking coalesces pointer events and stays bound to the original pane/id.
class TmuxHistoryScrollbar extends StatefulWidget {
  const TmuxHistoryScrollbar({super.key, required this.controller});
  final TerminalController controller;
  @override
  State<TmuxHistoryScrollbar> createState() => _TmuxHistoryScrollbarState();
}

class _TmuxHistoryScrollbarState extends State<TmuxHistoryScrollbar> {
  Timer? _timer;
  TmuxHistorySnapshot? _snapshot;
  (String, int)? _pending;
  int? _generation;
  int? _terminal;
  bool _busy = false;
  String? _error;
  TerminalController get c => widget.controller;
  bool get _eligible =>
      c.visible &&
      c.connected &&
      c.tmuxReadonly != null &&
      c.backend is TerminalTmuxHistoryBackend;
  @override
  void initState() {
    super.initState();
    c.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant TmuxHistoryScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_sync);
      c.addListener(_sync);
      _snapshot = null;
      _pending = null;
      _sync();
    }
  }

  void _sync() {
    if (_terminal != c.id || _generation != c.generation || !_eligible) {
      _snapshot = null;
      _pending = null;
      _terminal = c.id;
      _generation = c.generation;
    }
    if (!_eligible) {
      _timer?.cancel();
      _timer = null;
    } else if (_timer == null) {
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_request()),
      );
      // No synchronous setState while a parent is building a terminal.
      unawaited(Future<void>.delayed(Duration.zero, _request));
    }
  }

  Future<void> _request() async {
    if (!mounted || !_eligible || _busy || c.id == null) return;
    final source = c, id = c.id!, generation = c.generation;
    final pending = _pending;
    _pending = null;
    _busy = true;
    var busyRetry = false;
    try {
      final raw = await (c.backend as TerminalTmuxHistoryBackend).tmuxHistory(
        id,
        generation,
        pending?.$1,
        pending?.$2,
      );
      if (mounted &&
          identical(source, c) &&
          c.id == id &&
          c.generation == generation &&
          _eligible) {
        final snapshot = TmuxHistorySnapshot(raw);
        c.reportTmuxShell(
          snapshot.pane,
          snapshot.shell && snapshot.available && snapshot.offset == 0,
        );
        // An in-flight response from a different pane cannot redirect a drag.
        if (pending != null && pending.$1 != snapshot.pane) _pending = null;
        setState(() {
          _snapshot = snapshot;
          _error = null;
        });
      }
    } catch (error) {
      busyRetry = appMessage(error) == '远端检查正在处理或等待旧通道结束；未开始新请求';
      if (busyRetry) {
        // Preserve the proven snapshot while metrics owns the exec slot.
        // Retry a pending seek via the normal timer, never a busy loop.
        if (_pending == null &&
            c.id == id &&
            c.generation == generation &&
            _eligible) {
          _pending = pending;
        }
      }
      if (!busyRetry &&
          mounted &&
          identical(source, c) &&
          c.id == id &&
          c.generation == generation) {
        setState(() {
          _snapshot = null;
          _pending = null;
          _error = 'tmux历史暂不可用（需要远端Python 3）';
        });
      }
    } finally {
      _busy = false;
      if (!busyRetry && mounted && _pending != null && _eligible) {
        unawaited(_request());
      }
    }
  }

  @override
  void dispose() {
    c.removeListener(_sync);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final s = _snapshot;
      final enabled =
          _eligible && s != null && s.available && !s.readonly && s.history > 0;
      final height = s == null
          ? size.maxHeight
          : math
                .max(18.0, size.maxHeight * s.rows / (s.history + s.rows))
                .clamp(0.0, size.maxHeight);
      final travel = math.max(0.0, size.maxHeight - height);
      final top = s == null || s.history == 0
          ? 0.0
          : (s.history - s.offset) / s.history * travel;
      void seek(double y) {
        if (!enabled || travel <= 0) return;
        final offset =
            ((1 - ((y - height / 2) / travel).clamp(0.0, 1.0)) * s.history)
                .round()
                .clamp(0, s.history);
        _pending = (s.pane, offset);
        unawaited(_request());
      }

      return Tooltip(
        message:
            _error ??
            (s == null ? '读取tmux历史' : 'tmux历史 ${s.history} 行 · 位置 ${s.offset}'),
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (e) => seek(e.localPosition.dy),
            onVerticalDragUpdate: (e) => seek(e.localPosition.dy),
            child: Stack(
              children: [
                const SizedBox.expand(),
                if (s != null && s.available && s.history > 0)
                  Positioned(
                    top: top,
                    left: 2,
                    right: 2,
                    height: height,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurfaceVariant
                            .withValues(alpha: enabled ? .6 : .25),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
