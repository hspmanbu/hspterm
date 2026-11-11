import '../prototype/design.dart';

// Single-use inputs; only non-secret target metadata survives reconnect.
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../prototype/model.dart';

enum TemporaryAuth { saved, password, privateKey }

/// Only this metadata may be retained for a subsequent explicit confirmation.
class TemporaryTarget {
  const TemporaryTarget(this.address, this.port, this.username, this.auth);
  final String address, username;
  final int port;
  final TemporaryAuth auth;
}

/// Never store this object in host catalog, drafts, history, sync or diagnostics.
/// The consumer must release secrets after the one Native call finishes.
class TemporaryConnectionInput {
  TemporaryConnectionInput(
    this.target, {
    this.password,
    this.keyFile,
    this.passphrase,
  });
  final TemporaryTarget target;
  String? password, keyFile, passphrase;
  void forgetSecrets() {
    password = keyFile = passphrase = null;
  }
}

Future<TemporaryConnectionInput?> showTemporaryConnection(
  BuildContext context,
  DemoHost host, {
  TemporaryTarget? previous,
  Future<String?> Function()? pickKey,
}) => showAppDialog<TemporaryConnectionInput>(
  context: context,
  builder: (_) =>
      _TemporaryDialog(host: host, previous: previous, pickKey: pickKey),
);

class _TemporaryDialog extends StatefulWidget {
  const _TemporaryDialog({required this.host, this.previous, this.pickKey});
  final DemoHost host;
  final TemporaryTarget? previous;
  final Future<String?> Function()? pickKey;
  @override
  State<_TemporaryDialog> createState() => _TemporaryDialogState();
}

class _TemporaryDialogState extends State<_TemporaryDialog> {
  final form = GlobalKey<FormState>();
  late final address = TextEditingController(
    text: widget.previous?.address ?? widget.host.address,
  );
  late final port = TextEditingController(
    text: '${widget.previous?.port ?? widget.host.port}',
  );
  late final username = TextEditingController(
    text: widget.previous?.username ?? widget.host.user,
  );
  final password = TextEditingController(),
      passphrase = TextEditingController(),
      keyFile = TextEditingController();
  late TemporaryAuth auth = widget.host.credentialSet
      ? (widget.previous?.auth ?? TemporaryAuth.saved)
      : (widget.previous?.auth == TemporaryAuth.privateKey ||
                widget.host.auth == '私钥'
            ? TemporaryAuth.privateKey
            : TemporaryAuth.password);
  bool picking = false;
  String? pickError;
  @override
  void dispose() {
    for (final controller in [
      address,
      port,
      username,
      password,
      passphrase,
      keyFile,
    ]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  void changeAuth(TemporaryAuth value) {
    // Changing methods must not retain hidden or later reused credentials.
    password.clear();
    passphrase.clear();
    keyFile.clear();
    setState(() {
      auth = value;
      pickError = null;
    });
  }

  Future<void> selectKey() async {
    if (picking) {
      return;
    }
    setState(() {
      picking = true;
      pickError = null;
    });
    try {
      final path = widget.pickKey != null
          ? await widget.pickKey!()
          : (await openFile(confirmButtonText: '本次使用此私钥'))?.path;
      if (mounted && path != null && auth == TemporaryAuth.privateKey) {
        keyFile.text = path;
      }
    } catch (_) {
      if (mounted) {
        setState(() => pickError = '无法选择私钥文件，请重试');
      }
    } finally {
      if (mounted) {
        setState(() => picking = false);
      }
    }
  }

  void submit() {
    if (picking || !(form.currentState?.validate() ?? false)) {
      return;
    }
    final target = TemporaryTarget(
      address.text.trim(),
      int.parse(port.text),
      username.text,
      auth,
    );
    Navigator.of(context).pop(
      TemporaryConnectionInput(
        target,
        password: auth == TemporaryAuth.password ? password.text : null,
        keyFile: auth == TemporaryAuth.privateKey ? keyFile.text : null,
        passphrase:
            auth == TemporaryAuth.privateKey && passphrase.text.isNotEmpty
            ? passphrase.text
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('本次临时覆盖连接'),
    scrollable: true,
    content: SizedBox(
      width: 540,
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('已保存主机：${widget.host.name}'),
            const SizedBox(height: 8),
            const Text(
              '只用于本次连接，不修改已保存主机。跳板、代理等沿用保存配置；断开后须重新确认，不保留本次密码或私钥。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('temporary-address'),
              controller: address,
              autofocus: true,
              maxLength: 1024,
              decoration: const InputDecoration(
                labelText: '本次 SSH 地址',
                counterText: '',
              ),
              validator: (value) =>
                  value == null ||
                      value.trim().isEmpty ||
                      value.contains(RegExp(r'[\x00-\x20\x7f]'))
                  ? '请输入不含空白或控制字符的主机地址'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('temporary-port'),
              controller: port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '本次端口'),
              validator: (value) {
                final n = int.tryParse(value ?? '');
                return n == null || n < 1 || n > 65535 ? '端口范围为 1–65535' : null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('temporary-user'),
              controller: username,
              maxLength: 512,
              decoration: const InputDecoration(
                labelText: '本次用户名',
                counterText: '',
              ),
              validator: (value) =>
                  value == null ||
                      value.isEmpty ||
                      value.contains(RegExp(r'[\x00-\x1f\x7f]'))
                  ? '请输入有效用户名'
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<TemporaryAuth>(
              key: const ValueKey('temporary-auth'),
              initialValue: auth,
              decoration: const InputDecoration(labelText: '本次认证'),
              items: [
                DropdownMenuItem(
                  value: TemporaryAuth.saved,
                  enabled: widget.host.credentialSet,
                  child: const Text('沿用已保存的一种认证方式'),
                ),
                const DropdownMenuItem(
                  value: TemporaryAuth.password,
                  child: Text('本次密码'),
                ),
                const DropdownMenuItem(
                  value: TemporaryAuth.privateKey,
                  child: Text('本次私钥文件'),
                ),
              ],
              onChanged: picking
                  ? null
                  : (value) {
                      if (value != null) {
                        changeAuth(value);
                      }
                    },
            ),
            if (auth == TemporaryAuth.password) ...[
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('temporary-password'),
                controller: password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '本次密码（允许空密码）'),
              ),
            ],
            if (auth == TemporaryAuth.privateKey) ...[
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('temporary-key-file'),
                controller: keyFile,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: '本次私钥文件',
                  errorText: pickError,
                  suffixIcon: IconButton(
                    onPressed: picking ? null : selectKey,
                    tooltip: '选择私钥文件',
                    icon: const Icon(Icons.folder_open_outlined),
                  ),
                ),
                validator: (value) =>
                    value == null || value.isEmpty ? '请明确选择本次私钥' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('temporary-passphrase'),
                controller: passphrase,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '本次私钥口令（可选）'),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: picking ? null : submit,
        child: const Text('连接一次'),
      ),
    ],
  );
}
