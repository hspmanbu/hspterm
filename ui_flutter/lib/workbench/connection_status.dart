import 'package:flutter/material.dart';

import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import '../prototype/model.dart' show WorkPage;
import 'remote_inspection.dart';
import 'remote_inspection_panel.dart';

import '../terminal/controller.dart';
import 'model.dart';

String terminalTransportSummary(TerminalTransportInfo value) {
  final rtt = value.rttMicros == null
      ? '—'
      : '${(value.rttMicros! / 1000).toStringAsFixed(3)} ms';
  final size = value.columns == null || value.rows == null
      ? '—'
      : '${value.columns} × ${value.rows}${value.sizeLocked == true ? '（固定）' : ''}';
  return 'RTT $rtt · PTY $size';
}

class WorkbenchConnectionStatus extends StatefulWidget {
  const WorkbenchConnectionStatus({super.key, required this.model});
  final LiveWorkbenchModel model;
  @override
  State<WorkbenchConnectionStatus> createState() =>
      _WorkbenchConnectionStatusState();
}

class _WorkbenchConnectionStatusState extends State<WorkbenchConnectionStatus>
    with WidgetsBindingObserver {
  LiveWorkbenchModel get model => widget.model;
  RemoteInspectionController? _inspection;
  bool _foreground = true, _focused = true, _queued = false;
  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    model.addListener(_syncLater);
    _syncLater();
  }

  @override
  void didUpdateWidget(covariant WorkbenchConnectionStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, model)) {
      oldWidget.model.removeListener(_syncLater);
      model.addListener(_syncLater);
    }
    _syncLater();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncLater();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    _focused = event.state == ViewFocusState.focused;
    _syncLater();
  }

  void _syncLater() {
    if (_queued || !mounted) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted) return;
      final focus = model.focus;
      final target = focus is LiveTerminalSession ? focus.inspection : null;
      if (!identical(target, _inspection)) {
        _inspection?.setActive(false);
        _inspection = target;
      }
      target?.setActive(
        _foreground &&
            _focused &&
            !model.isClosing &&
            model.page == WorkPage.workspace &&
            !model.startPage,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    model.removeListener(_syncLater);
    WidgetsBinding.instance.removeObserver(this);
    _inspection?.setActive(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget label(String text) => Tooltip(
      message:
          '$text\nRTT 取自当前 SSH 心跳成功 ACK，包含本机排队与当前 SSH 路线。不额外探测；关闭心跳、旧兼容模式或尚无有效样本显示 —。任务数为当前已载入的真实任务记录。可选资源检查需单独授权独立通道；点击查看设置。',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          text,
          key: const ValueKey('workbench-connection-status'),
          maxLines: 1,
          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
        ),
      ),
    );
    final source = model.focus;
    if (source is! LiveTerminalSession) {
      return label(
        '未选择终端 · ${model.sessions.length} 个终端 · ${model.totalTransferCount} 个任务记录',
      );
    }
    return ValueListenableBuilder<TerminalTransportInfo>(
      valueListenable: source.controller.transportInfo,
      builder: (context, value, _) => ListenableBuilder(
        listenable: source.inspection,
        builder: (context, _) {
          final inspection = source.inspection;
          final resource = inspection.summary?.label;
          final details =
              '${source.statusLabel} · ${terminalTransportSummary(value)} · '
              '终端 ${model.sessions.length} · 任务 ${model.totalTransferCount}';
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Expanded(child: label(details)),
              if (inspection.metrics ||
                  resource != null ||
                  inspection.error != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    key: const ValueKey('remote-inspection-status'),
                    onTap: () => showRemoteInspection(context, source),
                    child: Tooltip(
                      message: resource ?? inspection.error ?? '资源采样中',
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: Text(
                          inspection.error != null
                              ? '资源采样已暂停'
                              : resource ?? '资源采样中…',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ] else
                InkWell(
                  key: const ValueKey('remote-inspection-status'),
                  onTap: () => showRemoteInspection(context, source),
                  child: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.monitor_heart_outlined, size: 15),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
