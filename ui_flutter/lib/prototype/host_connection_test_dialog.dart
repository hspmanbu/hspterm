import 'dart:async';

import 'package:flutter/material.dart';

import 'design.dart';
import 'model.dart';

class HostConnectionTestDialog extends StatefulWidget {
  const HostConnectionTestDialog({
    super.key,
    required this.model,
    required this.host,
  });
  final WorkbenchModel model;
  final DemoHost host;
  @override
  State<HostConnectionTestDialog> createState() =>
      _HostConnectionTestDialogState();
}

class _HostConnectionTestDialogState extends State<HostConnectionTestDialog> {
  Future<void>? _operation;
  bool _busy = true, _closing = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    // Starting work can notify the outer workbench; wait until this route mounts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closing) unawaited(_run());
    });
  }

  Future<void> _run() async {
    try {
      final operation = widget.model.testSavedHost(widget.host);
      _operation = operation;
      await operation;
    } catch (error) {
      if (mounted) _error = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    try {
      final operation = _operation;
      if (_busy && operation != null) {
        await widget.model.cancelHostTest(expected: operation);
      }
      if (mounted) {
        setState(() => _busy = false);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '取消测试失败：$error';
          _closing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    final operation = _operation;
    if (_busy && operation != null) {
      unawaited(
        widget.model
            .cancelHostTest(expected: operation)
            .catchError(widget.model.reportOperation),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    onPopInvokedWithResult: (popped, _) {
      if (!popped) unawaited(_close());
    },
    child: AlertDialog(
      scrollable: true,
      title: const Text('测试已保存的主机'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              '${widget.host.name}\n${widget.host.user}@${widget.host.address}:${widget.host.port}',
            ),
            const SizedBox(height: 16),
            if (_busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              const Text('正在检查 TCP、代理、SSH 握手与主机指纹…'),
            ] else if (_error != null)
              Text(
                '连接测试未通过：$_error',
                key: const ValueKey('host-test-error'),
                style: const TextStyle(color: Desk.danger),
              )
            else
              const Text('握手与主机指纹检查通过。', key: ValueKey('host-test-success')),
            const SizedBox(height: 12),
            if (widget.host.jumpHostId != null)
              const Text(
                '此连接需先认证所选跳板机，再检查目标 SSH 握手与独立指纹。',
                style: TextStyle(fontSize: 12),
              ),
            const Text(
              '此测试不验证目标账号登录认证，也不会开启远端终端。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: _closing ? null : _close,
          child: Text(_busy ? '取消测试' : '关闭'),
        ),
      ],
    ),
  );
}
