import '../prototype/settings_leave.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/previews.dart';

class FileOpenSettingsPanel extends StatefulWidget {
  const FileOpenSettingsPanel({super.key, this.load, this.save});
  final Future<FileOpenPreferences> Function()? load;
  final Future<void> Function(FileOpenPreferences)? save;
  @override
  State<FileOpenSettingsPanel> createState() => _FileOpenSettingsPanelState();
}

class _FileOpenSettingsPanelState extends State<FileOpenSettingsPanel> {
  final _limit = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _loading = true, _loaded = false, _saving = false, _saved = false;
  String? _error;
  String? _originalView;
  bool get _dirty => _loaded && _originalView != _limit.text;
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
      final value = await (widget.load ?? rust.fileOpenPreferences)();
      if (mounted) {
        _limit.text = '${value.confirmationMib}';
        _originalView = _limit.text;
        _loaded = true;
      }
    } catch (e) {
      if (mounted) _error = '读取文件打开设置失败：$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final value = FileOpenPreferences(confirmationMib: int.parse(_limit.text));
    setState(() {
      _saving = true;
      _saved = false;
      _error = null;
    });
    try {
      if (widget.save != null) {
        await widget.save!(value);
      } else {
        await rust.saveFileOpenPreferences(value: value);
      }
      if (mounted) {
        _saved = true;
        _originalView = _limit.text;
      }
    } catch (e) {
      if (mounted) _error = '保存失败，原有文件打开设置继续生效：$e';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LinearProgressIndicator();
    if (!_loaded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_error ?? '无法读取文件打开设置'),
          TextButton(onPressed: _load, child: const Text('重新读取文件打开设置')),
        ],
      );
    }
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            key: const ValueKey('file-open-confirmation-mib'),
            controller: _limit,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ],
            decoration: const InputDecoration(labelText: '文件打开确认阈值（MiB）'),
            validator: (text) {
              final n = int.tryParse(text ?? '');
              return n == null || n < 0 || n > 4294967295
                  ? '请输入 0–4294967295 之间的整数'
                  : null;
            },
            onChanged: (_) => setState(() => _saved = false),
          ),
          const SizedBox(height: 8),
          const Text(
            '默认 100 MiB，严格超过阈值时先确认；0 表示每次都确认（含空文件）。'
            '保存后对下一次文件打开生效；已弹出的确认保持原阈值。'
            '每次打开重新下载，临时预览退出清理，不会回传修改。',
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_saved) const Text('文件打开设置已加密保存'),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const ValueKey('save-file-open-settings'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '正在保存…' : '保存文件打开设置'),
            ),
          ),
          const SizedBox(height: 14),
        ],
      ),
    ).guardSettings(
      label: '文件打开确认设置',
      dirty: () => _dirty,
      busy: () => _saving,
    );
  }
}
