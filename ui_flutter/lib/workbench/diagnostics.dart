import 'package:flutter/material.dart';

import '../runtime_errors.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/diagnostics.dart';
import 'model.dart';

abstract interface class DiagnosticsGateway {
  Future<DiagnosticSnapshot> load();
  Future<void> clear();
}

class NativeDiagnosticsGateway implements DiagnosticsGateway {
  NativeDiagnosticsGateway(this.model);
  final LiveWorkbenchModel model;
  @override
  Future<DiagnosticSnapshot> load() =>
      model.runLocalSettings(rust.diagnosticSnapshot);
  @override
  Future<void> clear() => model.runLocalSettings(rust.clearDiagnostics);
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
};
bool diagnosticIsFailure(DiagnosticCode code) => [
  DiagnosticCode.connectionRejected,
  DiagnosticCode.stateFailed,
  DiagnosticCode.hostKeyRejected,
  DiagnosticCode.transferRequestRejected,
  DiagnosticCode.coreWorkerPanicked,
].contains(code);

class DiagnosticsPanel extends StatefulWidget {
  const DiagnosticsPanel({super.key, required this.gateway});
  final DiagnosticsGateway gateway;
  @override
  State<DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends State<DiagnosticsPanel> {
  DiagnosticSnapshot? _snapshot;
  bool _busy = false, _io = false, _errorsOnly = false;
  String _terminal = 'all';
  String? _error, _status;
  Map<RuntimeFault, int> _runtime = const {};
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
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
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
        const Text('本次运行诊断 · 仅内存'),
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
          '最多保留1000条固定状态代码与运行编号。不记录终端正文、命令、剪贴板、地址、用户名、路径、密码或密钥；不写入文件、SQLite、备份、云同步或遥测。',
        ),
        const SizedBox(height: 8),
        const Text('此处是状态摘要，不是逐包日志；已入队不表示传输完成。连接状态通知可能合并。只有打开或明确刷新时读取，无后台轮询。'),
        if (_io) const LinearProgressIndicator(),
        if (data != null)
          Text(
            '当前 ${data.events.length} / ${data.capacity} 条；容量淘汰 ${data.dropped} 条；筛选后 ${events.length} 条。',
            key: const ValueKey('diagnostics-count'),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 180,
              child: DropdownButtonFormField<String>(
                key: ValueKey('diagnostics-terminal-$_terminal'),
                initialValue: _terminal,
                decoration: const InputDecoration(labelText: '运行终端编号'),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('全部（含全局）')),
                  for (final id in terminals)
                    DropdownMenuItem(value: '$id', child: Text('终端 #$id')),
                ],
                onChanged: _busy ? null : (v) => setState(() => _terminal = v!),
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
