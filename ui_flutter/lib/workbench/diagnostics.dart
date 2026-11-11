import '../prototype/design.dart';

import 'package:flutter/material.dart';

import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../run_log.dart';
import '../prototype/settings_style.dart';

import '../runtime_errors.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/diagnostics.dart';
import 'model.dart';

abstract interface class DiagnosticsGateway {
  Future<DiagnosticSnapshot> load();
  Future<void> clear();
  Future<String> exportLog();
}

class NativeDiagnosticsGateway implements DiagnosticsGateway {
  NativeDiagnosticsGateway(this.model);
  final LiveWorkbenchModel model;
  @override
  Future<DiagnosticSnapshot> load() =>
      model.runLocalSettings(rust.diagnosticSnapshot);
  @override
  Future<void> clear() => model.runLocalSettings(rust.clearDiagnostics);
  @override
  Future<String> exportLog() => model.runLocalSettings(rust.currentRunLog);
}

String diagnosticLabel(DiagnosticCode code) => switch (code) {
  DiagnosticCode.terminalCreated => '已创建终端',
  DiagnosticCode.terminalCloseRequested => '请求关闭终端',
  DiagnosticCode.connectionRequested => '请求 SSH 连接',
  DiagnosticCode.connectionSucceeded => '连接请求已完成',
  DiagnosticCode.connectionRejected => '连接请求未成功',
  DiagnosticCode.connectionInterrupted => '连接请求等待已中断',
  DiagnosticCode.stateIdle => '已观察：空闲',
  DiagnosticCode.stateConnecting => '已观察：连接中',
  DiagnosticCode.stateConnected => '已观察：已连接',
  DiagnosticCode.stateDisconnected => '已观察：已断线',
  DiagnosticCode.stateFailed => '已观察：连接失败',
  DiagnosticCode.stateClosed => '已观察：已关闭',
  DiagnosticCode.connectionCancelRequested => '请求取消本次连接',
  DiagnosticCode.disconnectRequested => '请求断开连接',
  DiagnosticCode.hostKeyAccepted => '已接受本次主机密钥',
  DiagnosticCode.hostKeyRejected => '已拒绝本次主机密钥',
  DiagnosticCode.vaultOpened => '已打开加密配置库',
  DiagnosticCode.configurationRestored => '已原子恢复配置',
  DiagnosticCode.terminalPreferencesSaved => '已保存终端偏好',
  DiagnosticCode.uploadQueued => '上传请求已入队',
  DiagnosticCode.downloadQueued => '下载请求已入队',
  DiagnosticCode.transferRequestRejected => '传输入队请求未成功',
  DiagnosticCode.coreWorkerPanicked => '核心工作异常退出（详情已脱敏）',
  DiagnosticCode.directorySizeRemote => '目录大小：远端扫描',
  DiagnosticCode.directorySizeFallback => '目录大小：回退本地扫描',
  DiagnosticCode.localEditReplaceLoss => '本地编辑替换后清理未完全成功',
};
bool diagnosticIsFailure(DiagnosticCode code) => [
  DiagnosticCode.connectionRejected,
  DiagnosticCode.stateFailed,
  DiagnosticCode.hostKeyRejected,
  DiagnosticCode.transferRequestRejected,
  DiagnosticCode.coreWorkerPanicked,
].contains(code);

class DiagnosticsPanel extends StatefulWidget {
  const DiagnosticsPanel({
    super.key,
    required this.gateway,
    this.chooseLogFile,
  });
  final DiagnosticsGateway gateway;
  final Future<String?> Function(String suggestedName)? chooseLogFile;
  @override
  State<DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends State<DiagnosticsPanel> {
  DiagnosticSnapshot? _snapshot;
  bool _busy = false, _io = false, _errorsOnly = false;
  String _terminal = 'all';
  String? _error, _status;
  Map<RuntimeFault, int> _runtime = const {};
  Future<void> _export() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    AppRunLog.instance.event(AppLogEvent.exportRequested);
    try {
      final name =
          'HSPTerm-${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}.log';
      final path = widget.chooseLogFile != null
          ? await widget.chooseLogFile!(name)
          : (await getSaveLocation(
              suggestedName: name,
              acceptedTypeGroups: [
                const XTypeGroup(label: '日志文件', extensions: ['log']),
              ],
            ))?.path;
      if (!mounted || path == null) return;
      setState(() => _io = true);
      final native = await widget.gateway.exportLog();
      final contents = AppRunLog.instance.export(native);
      // Replace, never append/reload any previous file or launch log.
      await File(path).writeAsString(contents, flush: true);
      AppRunLog.instance.event(AppLogEvent.exported, count: contents.length);
      if (mounted) setState(() => _status = '已导出本次启动日志。');
    } catch (error, stack) {
      AppRunLog.instance.event(
        AppLogEvent.exportFailed,
        error: error,
        stack: stack,
      );
      if (mounted) setState(() => _error = '日志导出失败，请检查目标文件权限后重试。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _io = true;
      _error = null;
      _status = null;
      _runtime = RuntimeFaults.instance.counts;
    });
    try {
      final value = await widget.gateway.load();
      if (mounted) setState(() => _adopt(value));
    } catch (error) {
      if (mounted) setState(() => _error = '未读取最新诊断：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  void _adopt(DiagnosticSnapshot value) {
    if (value.capacity != 1000 || value.events.length > value.capacity) {
      throw StateError('诊断快照超过约定容量');
    }
    _snapshot = value;
    if (_terminal != 'all' &&
        !value.events.any((e) => e.terminalId?.toString() == _terminal)) {
      _terminal = 'all';
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    var acknowledged = false;
    try {
      final accepted = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('清空本次运行诊断？'),
          content: const Text('清空全部终端的内存诊断，包括确认期间新增的记录。不影响终端滚动历史、命令历史、配置或传输。'),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('diagnostics-confirm-clear'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空诊断'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
      setState(() => _io = true);
      await widget.gateway.clear();
      RuntimeFaults.instance.clear();
      AppRunLog.instance.clear();
      acknowledged = true;
      if (!mounted) return;
      setState(() {
        _snapshot = null;
        _runtime = RuntimeFaults.instance.counts;
        _status = '本次运行诊断已清空。';
      });
      final latest = await widget.gateway.load();
      if (mounted) setState(() => _adopt(latest));
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = acknowledged
              ? '已清空诊断，但刷新失败：$error。请刷新查看，不必重复清空。'
              : '未确认清空成功：$error',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _snapshot;
    final terminals =
        data?.events
            .map((e) => e.terminalId)
            .whereType<int>()
            .toSet()
            .toList() ??
        <int>[];
    terminals.sort();
    final events =
        data?.events
            .where(
              (e) =>
                  (_terminal == 'all' ||
                      e.terminalId?.toString() == _terminal) &&
                  (!_errorsOnly || diagnosticIsFailure(e.code)),
            )
            .toList()
            .reversed
            .toList() ??
        <DiagnosticEvent>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('本次启动日志与诊断'),
        if (_runtime.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '界面固定计数（仅全局，刷新时读取）：\n${_runtime.entries.map((e) => '${runtimeFaultLabel(e.key)}：${e.value}').join('；')}',
              key: const ValueKey('diagnostics-runtime-faults'),
            ),
          ),
        const SizedBox(height: 8),
        const Text(
          '自动记录本次启动的时间、操作、阶段、错误类别及代码位置。日志仅在内存保留；导出后可用于问题诊断。不会读取以前的日志。',
        ),
        const SizedBox(height: 8),
        const Text('不记录密码、密钥、终端内容、命令或剪贴板。日志有容量上限，导出文件会标明被淘汰的数量。下方为核心事件摘要。'),
        if (_io) const LinearProgressIndicator(),
        if (data != null)
          Text(
            '当前 ${data.events.length} / ${data.capacity} 条；容量淘汰 ${data.dropped} 条；筛选后 ${events.length} 条。',
            key: const ValueKey('diagnostics-count'),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 220,
              child: SettingsField(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey('diagnostics-terminal-$_terminal'),
                  initialValue: _terminal,
                  decoration: const InputDecoration(labelText: '运行终端编号'),
                  items: [
                    const DropdownMenuItem(
                      value: 'all',
                      child: Text('全部（含全局）'),
                    ),
                    for (final id in terminals)
                      DropdownMenuItem(value: '$id', child: Text('终端 #$id')),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _terminal = v!),
                ),
              ),
            ),
            FilterChip(
              key: const ValueKey('diagnostics-errors'),
              label: const Text('仅失败 / 拒绝'),
              selected: _errorsOnly,
              onSelected: _busy ? null : (v) => setState(() => _errorsOnly = v),
            ),
            TextButton(
              key: const ValueKey('diagnostics-refresh'),
              onPressed: _busy ? null : _load,
              child: const Text('刷新'),
            ),
            TextButton(
              key: const ValueKey('diagnostics-clear'),
              onPressed: _busy ? null : _clear,
              child: const Text('清空本次诊断'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('diagnostics-export'),
              onPressed: _busy ? null : _export,
              icon: const Icon(Icons.save_alt, size: 17),
              label: const Text('导出本次启动日志'),
            ),
          ],
        ),
        if (_error != null)
          Text(
            _error!,
            key: const ValueKey('diagnostics-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_status != null)
          Text(_status!, key: const ValueKey('diagnostics-status')),
        const SizedBox(height: 10),
        SizedBox(
          height: 340,
          child: events.isEmpty
              ? const Center(child: Text('当前筛选没有诊断记录'))
              : ListView.builder(
                  key: const ValueKey('diagnostics-events'),
                  itemCount: events.length,
                  itemBuilder: (context, index) {
                    final e = events[index];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        diagnosticIsFailure(e.code)
                            ? Icons.error_outline
                            : Icons.info_outline,
                        size: 16,
                        color: diagnosticIsFailure(e.code)
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                      title: Text(
                        diagnosticLabel(e.code),
                        style: const TextStyle(fontSize: 12),
                      ),
                      subtitle: Text(
                        '#${e.sequence} · +${(e.elapsedMs.toDouble() / 1000).toStringAsFixed(3)}s · ${e.terminalId == null ? '全局' : '终端 #${e.terminalId}'}${e.generation == null ? '' : ' · 代次 ${e.generation}'}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
