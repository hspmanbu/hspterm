import 'package:flutter/material.dart';

/// Tracks only dirty/busy booleans and labels. Draft text, passwords and
/// configuration values remain in their existing editor and are never copied.
class SettingsLeaveRegistry {
  final _editors =
      <
        Object,
        ({
          String label,
          String? category,
          bool Function() dirty,
          bool Function() busy,
          Future<void> Function()? apply,
          bool Function()? confirmed,
        })
      >{};
  final _failed = <Object>{};
  bool _checking = false;
  bool applying = false;
  String? failedCategory;
  void register(
    Object owner,
    String label,
    bool Function() dirty,
    bool Function() busy, {
    String? category,
    Future<void> Function()? apply,
    bool Function()? confirmed,
  }) => _editors[owner] = (
    label: label,
    category: category,
    dirty: dirty,
    busy: busy,
    apply: apply,
    confirmed: confirmed,
  );
  void unregister(Object owner) {
    _editors.remove(owner);
    _failed.remove(owner);
  }

  bool get busy => applying || _editors.values.any((entry) => entry.busy());
  Future<bool> applyAll(BuildContext context) async {
    if (busy) return false;
    applying = true;
    failedCategory = null;
    try {
      // Independent repositories acknowledge each save. Never claim a partial
      // save was rolled back, and never close if validation/save left a draft.
      for (final item in _editors.entries.toList()) {
        final owner = item.key, entry = item.value;
        if (!entry.dirty() && !_failed.contains(owner)) continue;
        _failed.add(owner);
        failedCategory = entry.category;
        final save = entry.apply;
        if (save == null) throw StateError('${entry.label}尚未接入应用操作');
        await save();
        if (entry.dirty() || entry.confirmed?.call() == false) {
          throw StateError('${entry.label}未保存，请检查该页提示');
        }
        _failed.remove(owner);
      }
      failedCategory = null;
      return true;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('$error。已确认保存的设置保持生效。')));
      }
      return false;
    } finally {
      applying = false;
    }
  }

  Future<bool> canLeave(BuildContext context) async {
    if (_checking) return false;
    if (busy) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('设置保存尚未结束，请等待确认后再离开。')));
      return false;
    }
    final changed = _editors.entries
        .where((entry) => entry.value.dirty() || _failed.contains(entry.key))
        .map((entry) => entry.value.label)
        .toSet();
    if (changed.isEmpty) return true;
    _checking = true;
    try {
      return await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              scrollable: true,
              title: const Text('放弃未保存的设置？'),
              content: Text('${changed.join('、')}有未应用的修改。可返回设置后应用，或放弃本次修改。'),
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
    this.category,
    required super.child,
  });
  final SettingsLeaveRegistry registry;
  final String? category;
  static SettingsLeaveRegistry? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsLeaveScope>()
      ?.registry;
  @override
  bool updateShouldNotify(SettingsLeaveScope oldWidget) =>
      !identical(registry, oldWidget.registry) ||
      category != oldWidget.category;
}

class SettingsDraftGuard extends StatefulWidget {
  const SettingsDraftGuard({
    super.key,
    required this.label,
    required this.dirty,
    required this.busy,
    required this.child,
    this.apply,
    this.confirmed,
  });
  final String label;
  final bool Function() dirty, busy;
  final Widget child;
  final Future<void> Function()? apply;
  final bool Function()? confirmed;
  @override
  State<SettingsDraftGuard> createState() => _SettingsDraftGuardState();
}

class _SettingsDraftGuardState extends State<SettingsDraftGuard> {
  SettingsLeaveRegistry? _registry;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = SettingsLeaveScope.of(context);
    if (!identical(_registry, registry)) _registry?.unregister(this);
    _registry = registry;
    _registry?.register(
      this,
      widget.label,
      () => widget.dirty(),
      () => widget.busy(),
      category: context
          .dependOnInheritedWidgetOfExactType<SettingsLeaveScope>()
          ?.category,
      apply: () async {
        await widget.apply?.call();
      },
      confirmed: () => widget.confirmed?.call() ?? true,
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
    Future<void> Function()? apply,
    bool Function()? confirmed,
  }) => SettingsDraftGuard(
    label: label,
    dirty: dirty,
    busy: busy,
    apply: apply,
    confirmed: confirmed,
    child: this,
  );
}
