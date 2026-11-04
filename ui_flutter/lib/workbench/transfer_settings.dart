import '../prototype/settings_style.dart';
import '../prototype/settings_leave.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/transfers.dart' as jobs;

/// This panel is real configuration; adjacent prototype settings remain labelled.
class TransferSettingsPanel extends StatefulWidget {
  const TransferSettingsPanel({super.key, this.load, this.save});
  final Future<jobs.TransferPreferences> Function()? load;
  final Future<void> Function(jobs.TransferPreferences)? save;
  @override
  State<TransferSettingsPanel> createState() => _TransferSettingsPanelState();
}

class _TransferSettingsPanelState extends State<TransferSettingsPanel> {
  final _form = GlobalKey<FormState>();
  final _concurrency = TextEditingController();
  final _upload = TextEditingController();
  final _download = TextEditingController();
  bool _loading = true, _loaded = false, _saving = false, _saved = false;
  String? _error;
  Object? _originalView;
  Object get _view => (
    _concurrency.text,
    _upload.text,
    _download.text,
    _policy,
    _resumeOnReconnect,
  );
  bool get _dirty => _loaded && _originalView != _view;
  String _policy = 'ask';
  bool _resumeOnReconnect = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await (widget.load ?? rust.transferPreferences)();
      if (!mounted) return;
      final policy = value.defaultConflict ?? 'ask';
      if (!['ask', 'overwrite', 'skip', 'rename'].contains(policy)) {
        throw StateError('不支持的同名处理策略');
      }
      _policy = policy;
      _resumeOnReconnect = value.resumeOnReconnect ?? false;
      _concurrency.text = '${value.concurrency}';
      _upload.text = '${value.uploadBytesPerSecond}';
      _download.text = '${value.downloadBytesPerSecond}';
      _originalView = _view;
      _loaded = true;
    } catch (error) {
      if (mounted) _error = '读取传输配置失败：$error';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _concurrency.dispose();
    _upload.dispose();
    _download.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final value = jobs.TransferPreferences(
      concurrency: int.parse(_concurrency.text),
      uploadBytesPerSecond: int.parse(_upload.text),
      downloadBytesPerSecond: int.parse(_download.text),
      defaultConflict: _policy,
      resumeOnReconnect: _resumeOnReconnect,
    );
    setState(() {
      _saving = true;
      _saved = false;
      _error = null;
    });
    try {
      if (widget.save != null) {
        await widget.save!(value);
      } else {
        await rust.saveTransferPreferences(value: value);
      }
      if (mounted) {
        _saved = true;
        _originalView = _view;
      }
    } catch (error) {
      if (mounted) _error = '保存失败，原有配置继续生效：$error';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget field(
    String name,
    TextEditingController controller,
    int min,
    int max,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: SettingsField(
      child: TextFormField(
        key: ValueKey('transfer-setting-$name'),
        controller: controller,
        enabled: !_saving,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(13),
        ],
        decoration: InputDecoration(labelText: name),
        validator: (text) {
          final n = int.tryParse(text ?? '');
          return n == null || n < min || n > max ? '请输入 $min–$max 之间的整数' : null;
        },
        onChanged: (_) {
          if (_saved) setState(() => _saved = false);
        },
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (_loading) return const LinearProgressIndicator();
    if (!_loaded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_error ?? '无法读取配置'),
          OutlinedButton(onPressed: _load, child: const Text('重新读取传输配置')),
        ],
      );
    }
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field('并发顶层任务', _concurrency, 1, 32),
          field('总体上传限制（字节/秒）', _upload, 0, 1099511627776),
          field('总体下载限制（字节/秒）', _download, 0, 1099511627776),
          SettingsField(
            child: DropdownButtonFormField<String>(
              key: const ValueKey('transfer-default-conflict'),
              initialValue: _policy,
              decoration: const InputDecoration(labelText: '新任务默认同名处理'),
              items: const [
                DropdownMenuItem(value: 'ask', child: Text('询问（默认）')),
                DropdownMenuItem(value: 'rename', child: Text('更名另存，保留旧目标')),
                DropdownMenuItem(value: 'skip', child: Text('跳过同名文件')),
                DropdownMenuItem(value: 'overwrite', child: Text('覆盖已有文件内容')),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _policy = value;
                        _saved = false;
                      });
                    },
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '同名策略仅对保存后新入队任务生效，旧任务保持入队时策略；逐项明确决定优先。'
            '覆盖会替换目标文件内容，无法撤销。目录或文件类型不兼容仍报错。',
          ),
          CompactSettingsToggle(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('手动重连后恢复本次中断的传输'),
              subtitle: const Text(
                '默认关闭。只恢复原标签、原账户和指纹的待传项目；不自动建立SSH，主动暂停/取消、失败项、冲突和跨应用启动任务仍需手动处理。跨服务器任务需要两端均已手动连接。',
              ),
              value: _resumeOnReconnect,
              onChanged: _saving
                  ? null
                  : (v) => setState(() {
                      _resumeOnReconnect = v;
                      _saved = false;
                    }),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '0 表示不限速；1 MiB/s = 1048576 字节/秒。所有任务共享同方向预算。'
            '带宽保存后立即生效，已在途数据最多保留一块；降低并发不会中断活动任务，后续按 FIFO 准入。SSH 终端不受限速影响。',
          ),
          const SizedBox(height: 10),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_saved) const Text('已加密保存并生效'),
          Align(
            alignment: Alignment.centerLeft,
            child: Visibility(
              visible: SettingsLeaveScope.of(context) == null,
              child: FilledButton(
                key: const ValueKey('save-transfer-settings'),
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '正在保存…' : '保存传输配置'),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ).guardSettings(
      confirmed: () => _loaded && _error == null,
      apply: _save,
      label: '传输设置',
      dirty: () => _dirty,
      busy: () => _saving,
    );
  }
}
