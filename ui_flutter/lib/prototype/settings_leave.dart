import 'package:flutter/material.dart';

/// Tracks only dirty/busy booleans and labels. Draft text, passwords and
/// configuration values remain in their existing editor and are never copied.
class SettingsLeaveRegistry {
  final _editors =
      <Object, ({String label, bool Function() dirty, bool Function() busy})>{};
  bool _checking = false;
  void register(
    Object owner,
    String label,
    bool Function() dirty,
    bool Function() busy,
  ) => _editors[owner] = (label: label, dirty: dirty, busy: busy);
  void unregister(Object owner) => _editors.remove(owner);
  Future<bool> canLeave(BuildContext context) async {
    if (_checking) return false;
    if (_editors.values.any((entry) => entry.busy())) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('设置保存尚未结束，请等待确认后再离开。')));
      return false;
    }
    final changed = _editors.values
        .where((entry) => entry.dirty())
        .map((entry) => entry.label)
        .toSet();
    if (changed.isEmpty) return true;
    _checking = true;
    try {
      return await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              scrollable: true,
              title: const Text('放弃未保存的设置？'),
              content: Text(
                '${changed.join('、')}有未保存修改。返回编辑后可使用原保存按钮；放弃只丢弃本机尚未提交的表单，不回滚已确认保存的设置。',
              ),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('返回编辑'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('放弃并离开'),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      _checking = false;
    }
  }
}

class SettingsLeaveScope extends InheritedWidget {
  const SettingsLeaveScope({
    super.key,
    required this.registry,
    required super.child,
  });
  final SettingsLeaveRegistry registry;
  static SettingsLeaveRegistry? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsLeaveScope>()
      ?.registry;
  @override
  bool updateShouldNotify(SettingsLeaveScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}

class SettingsDraftGuard extends StatefulWidget {
  const SettingsDraftGuard({
    super.key,
    required this.label,
    required this.dirty,
    required this.busy,
    required this.child,
  });
  final String label;
  final bool Function() dirty, busy;
  final Widget child;
  @override
  State<SettingsDraftGuard> createState() => _SettingsDraftGuardState();
}

class _SettingsDraftGuardState extends State<SettingsDraftGuard> {
  SettingsLeaveRegistry? _registry;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _registry?.unregister(this);
    _registry = SettingsLeaveScope.of(context);
    _registry?.register(
      this,
      widget.label,
      () => widget.dirty(),
      () => widget.busy(),
    );
  }

  @override
  void dispose() {
    _registry?.unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

extension SettingsDraftProtection on Widget {
  Widget guardSettings({
    required String label,
    required bool Function() dirty,
    required bool Function() busy,
  }) => SettingsDraftGuard(label: label, dirty: dirty, busy: busy, child: this);
}
