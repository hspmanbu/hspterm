import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// An inbound OS file delivery surface. Remote file/path drags remain Flutter
/// gestures; this never handles terminal input or asks Explorer to move files.
class ExplorerFileDropRegion extends StatefulWidget {
  const ExplorerFileDropRegion({
    super.key,
    required this.owner,
    required this.view,
    required this.enabled,
    required this.onDrop,
    required this.onHover,
    required this.onFailure,
    required this.child,
  });
  final String owner;
  final Object view;
  final bool enabled;
  final Future<void> Function(List<String>, Offset) onDrop;
  final void Function(Offset?) onHover;
  final void Function(String) onFailure;
  final Widget child;
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  @override
  State<ExplorerFileDropRegion> createState() => _ExplorerFileDropRegionState();
}

class _Host {
  static const channel = MethodChannel('hspterm/explorer_drop');
  static _ExplorerFileDropRegionState? current;
  static Future<void>? tail;
  static int next = 0;
  static void install() {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'event' || call.arguments is! Map) return;
      final event = (call.arguments as Map).cast<Object?, Object?>();
      try {
        current?.receive(event);
      } finally {
        // Always ACK even a stale owner/view event. Native retains at most one
        // in-flight + one coalesced move, including while Dart is busy/unmounted.
        final sequence = event['sequence'];
        if (sequence is int && sequence > 0) {
          await invoke('ackMove', {'sequence': sequence}, failure: null);
        }
      }
    });
  }

  static Future<void> invoke(
    String method,
    Object? args, {
    required void Function(String)? failure,
  }) {
    final work = (tail ?? Future<void>.value()).then((_) async {
      try {
        await channel.invokeMethod<void>(method, args);
      } on MissingPluginException {
        failure?.call('当前窗口没有Explorer拖放适配，请使用上传按钮');
      } on PlatformException {
        failure?.call('Explorer拖放暂不可用，请使用上传按钮');
      } catch (_) {
        failure?.call('Explorer拖放状态未确认，请使用上传按钮');
      }
    });
    tail = work;
    // Retain ordering only while a native operation is pending. A completed
    // Future can otherwise carry a retired view's asynchronous zone forever.
    unawaited(
      work.then((_) {
        if (identical(tail, work)) tail = null;
      }),
    );
    return work;
  }
}

class _ExplorerFileDropRegionState extends State<ExplorerFileDropRegion>
    with WidgetsBindingObserver {
  final _bounds = GlobalKey();
  late final int _id;
  int _revision = 0, _finishedDrag = 0;
  Rect? _sent;
  bool _scheduled = false, _failed = false;
  bool _routeCurrent = true;
  String get zone => '$_id:$_revision';
  bool get eligible =>
      mounted &&
      widget.enabled &&
      _routeCurrent &&
      ExplorerFileDropRegion.supported;
  @override
  void initState() {
    super.initState();
    _id = ++_Host.next;
    WidgetsBinding.instance.addObserver(this);
    if (ExplorerFileDropRegion.supported) {
      _Host.install();
      _Host.current = this;
    }
  }

  @override
  void didChangeMetrics() {
    invalidate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    invalidate();
  }

  @override
  void didUpdateWidget(ExplorerFileDropRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.owner != widget.owner ||
        oldWidget.view != widget.view ||
        oldWidget.enabled != widget.enabled) {
      invalidate();
    }
  }

  void invalidate() {
    ++_revision;
    _sent = null;
    schedule();
  }

  void schedule() {
    if (!ExplorerFileDropRegion.supported || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !identical(_Host.current, this)) return;
      if (!eligible) {
        unawaited(_Host.invoke('clear', null, failure: failure));
        return;
      }
      final box = _bounds.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      final scale = View.of(context).devicePixelRatio;
      final position = box.localToGlobal(Offset.zero) * scale;
      final rect = position & (box.size * scale);
      if (!rect.isFinite || rect.isEmpty) return;
      if (rect == _sent) return;
      if (_sent != null) ++_revision;
      _sent = rect;
      final owner = widget.owner, token = zone;
      unawaited(
        _Host.invoke('bind', {
          'owner': owner,
          'zone': token,
          'rect': [rect.left, rect.top, rect.right, rect.bottom],
        }, failure: failure),
      );
    });
  }

  void failure(String message) {
    if (mounted && !_failed) {
      _failed = true;
      widget.onFailure(message);
    }
  }

  void receive(Map<Object?, Object?> event) {
    if (!eligible || event['owner'] != widget.owner || event['zone'] != zone) {
      return;
    }
    final drag = event['drag'];
    if (drag is! int || drag <= 0 || drag <= _finishedDrag) return;
    final kind = event['kind'];
    if (kind == 'leave' || kind == 'invalid') {
      _finishedDrag = drag;
      widget.onHover(null);
      if (kind == 'invalid') widget.onFailure('拖入的本地文件列表无效或超过容量；未入队');
      return;
    }
    if (kind == 'outside') {
      widget.onHover(null);
      return;
    }
    final x = event['x'], y = event['y'];
    if (x is! num || y is! num || !x.isFinite || !y.isFinite) return;
    final point =
        Offset(x.toDouble(), y.toDouble()) / View.of(context).devicePixelRatio;
    final box = _bounds.currentContext?.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        !(Offset.zero & box.size).contains(box.globalToLocal(point))) {
      widget.onHover(null);
      if (kind == 'drop') widget.onFailure('拖放区域已变化，未入队；请重新拖入');
      return;
    }
    if (kind == 'hover') {
      widget.onHover(point);
      return;
    }
    if (kind != 'drop') return;
    _finishedDrag = drag;
    widget.onHover(null);
    final paths = event['paths'];
    if (paths is! List ||
        paths.isEmpty ||
        paths.length > 4096 ||
        paths.any(
          (p) =>
              p is! String ||
              p.isEmpty ||
              p.length > 32767 ||
              p.contains('\u0000'),
        )) {
      widget.onFailure('拖入的本地文件列表无效；未入队');
      return;
    }
    final frozen = List<String>.unmodifiable(paths.cast<String>());
    var bytes = 0;
    for (final path in frozen) {
      bytes += utf8.encode(path).length;
      if (bytes > 4 * 1024 * 1024) {
        widget.onFailure('拖入的本地路径超过容量；未入队');
        return;
      }
    }
    final pending = Future<void>.sync(() => widget.onDrop(frozen, point));
    unawaited(
      pending.catchError((Object _) {
        if (mounted) widget.onFailure('上传入队未全部确认，请查看任务队列');
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(_Host.current, this)) {
      _Host.current = null;
      unawaited(_Host.invoke('clear', null, failure: null));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    schedule();
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        invalidate();
        return false;
      },
      child: SizedBox(key: _bounds, child: widget.child),
    );
  }
}

String explorerFileName(String path) {
  final value = path.replaceAll('\\', '/');
  final drive = RegExp(r'^[A-Za-z]:/').hasMatch(value);
  final unc =
      value.startsWith('//') &&
      !value.startsWith('//?/') &&
      !value.startsWith('//./') &&
      value.substring(2).split('/').where((p) => p.isNotEmpty).length >= 2;
  if (!drive && !unc) throw const FormatException('拖入的本地文件需要Windows绝对路径');
  final name = value.split('/').last;
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('\u0000') ||
      name.contains(':')) {
    throw const FormatException('无法将拖入的本地文件名安全映射到远端');
  }
  return name;
}
