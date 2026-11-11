import 'design.dart';
import '../terminal/application_keys.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// IDs are application-defined constants or opaque session IDs, never remote
/// commands, search input, host labels or terminal contents.
class AppCommand {
  const AppCommand(
    this.id,
    this.label,
    this.run, {
    this.available,
    this.availableChanges,
  });
  final String id, label;
  final FutureOr<void> Function() run;
  final bool Function()? available;
  final Listenable? availableChanges;
  bool get allowed => available?.call() ?? true;
}

/// Session-local recent application action IDs only; no search text or labels.
class RecentAppCommands {
  final _ids = <String>[];
  List<String> get ids => List.unmodifiable(_ids);
  void record(String id) {
    if (!RegExp(r'^[a-zA-Z0-9:._-]{1,256}$').hasMatch(id)) return;
    _ids.remove(id);
    _ids.insert(0, id);
    if (_ids.length > 8) _ids.removeLast();
  }

  List<AppCommand> visible(List<AppCommand> source, String query) {
    final needle = query.trim().toLowerCase();
    final positions = {for (var i = 0; i < source.length; i++) source[i].id: i};
    final result = source
        .where((c) => c.allowed && c.label.toLowerCase().contains(needle))
        .toList();
    if (needle.isEmpty) {
      int rank(AppCommand c) {
        final i = _ids.indexOf(c.id);
        return i < 0 ? 8 : i;
      }

      result.sort((a, b) {
        final recent = rank(a).compareTo(rank(b));
        return recent != 0
            ? recent
            : positions[a.id]!.compareTo(positions[b.id]!);
      });
    }
    return result;
  }
}

class _MoveIntent extends Intent {
  const _MoveIntent(this.delta);
  final int delta;
}

class _AcceptIntent extends Intent {
  const _AcceptIntent();
}

class _PaletteShortcuts extends ShortcutManager {
  _PaletteShortcuts(this.composing)
    : super(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowDown): _MoveIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowUp): _MoveIntent(-1),
          SingleActivator(LogicalKeyboardKey.enter): _AcceptIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): _AcceptIntent(),
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
      );
  final bool Function() composing;
  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    if (composing() &&
        const [
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.escape,
        ].contains(event.logicalKey)) {
      // Return candidate keys to the platform IME while preventing an outer
      // Flutter shortcut from invoking Enter/Escape on the dialog underneath.
      return KeyEventResult.skipRemainingHandlers;
    }
    final claim = ApplicationKeyScope.claimHandler(context);
    final result = super.handleKeypress(context, event);
    if (result == KeyEventResult.handled) claim?.call(event);
    return result;
  }
}

Future<AppCommand?> showAppCommandPalette(
  BuildContext context, {
  required List<AppCommand> commands,
  required RecentAppCommands recent,
  required Listenable changes,
}) => showAppDialog<AppCommand>(
  context: context,
  builder: (_) =>
      AppCommandPalette(commands: commands, recent: recent, changes: changes),
);

class AppCommandPalette extends StatefulWidget {
  const AppCommandPalette({
    super.key,
    required this.commands,
    required this.recent,
    this.changes,
  });
  final List<AppCommand> commands;
  final RecentAppCommands recent;
  final Listenable? changes;
  @override
  State<AppCommandPalette> createState() => _AppCommandPaletteState();
}

class _AppCommandPaletteState extends State<AppCommandPalette> {
  final _query = TextEditingController(), _scroll = ScrollController();
  late final _shortcuts = _PaletteShortcuts(
    () => _query.value.composing.isValid && !_query.value.composing.isCollapsed,
  );
  String? _selected;
  bool _closed = false;
  List<(String, String)> _shown = const [];
  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_changed);
  }

  @override
  void didUpdateWidget(AppCommandPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes?.removeListener(_changed);
      widget.changes?.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted) return;
    final items = _visible;
    if (items.length == _shown.length) {
      var same = true;
      for (var i = 0; i < items.length; i++) {
        if ((items[i].id, items[i].label) != _shown[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_changed);
    _shortcuts.dispose();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<AppCommand> get _visible =>
      widget.recent.visible(widget.commands, _query.text);
  void _move(int delta) {
    final items = _visible;
    if (items.isEmpty) return;
    final previous = items.indexWhere((c) => c.id == _selected);
    final index = ((previous < 0 ? 0 : previous) + delta) % items.length;
    setState(() => _selected = items[index].id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        final start = index * 36.0, end = start + 36;
        final offset = _scroll.offset,
            height = _scroll.position.viewportDimension;
        final next = start < offset
            ? start
            : end > offset + height
            ? end - height
            : offset;
        _scroll.jumpTo(next.clamp(0, _scroll.position.maxScrollExtent));
      }
    });
  }

  void _dismiss() {
    if (_closed || ModalRoute.of(context)?.isCurrent != true) return;
    _closed = true;
    Navigator.pop(context);
  }

  void _accept([AppCommand? command]) {
    if (_closed || ModalRoute.of(context)?.isCurrent != true) return;
    final items = _visible;
    final chosen =
        command ??
        items.where((c) => c.id == _selected).firstOrNull ??
        items.firstOrNull;
    if (chosen != null && chosen.allowed) {
      _closed = true;
      Navigator.pop(context, chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _visible;
    _shown = [for (final item in items) (item.id, item.label)];
    if (!items.any((c) => c.id == _selected)) _selected = items.firstOrNull?.id;
    final size = MediaQuery.sizeOf(context),
        insets = MediaQuery.viewInsetsOf(context);
    final height = math.min(
      360.0,
      math.max(0.0, size.height - insets.vertical - 48),
    );
    return Dialog(
      alignment: const Alignment(0, -.45),
      child: SizedBox(
        width: math.min(560.0, math.max(0.0, size.width - 48)),
        height: height,
        child: Shortcuts.manager(
          manager: _shortcuts,
          child: Actions(
            actions: {
              _MoveIntent: CallbackAction<_MoveIntent>(
                onInvoke: (i) {
                  _move(i.delta);
                  return null;
                },
              ),
              _AcceptIntent: CallbackAction<_AcceptIntent>(
                onInvoke: (_) {
                  _accept();
                  return null;
                },
              ),
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  _dismiss();
                  return null;
                },
              ),
            },
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    key: const ValueKey('app-command-query'),
                    controller: _query,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '搜索应用操作…',
                      prefixIcon: Icon(Icons.search, size: 17),
                    ),
                    onChanged: (_) {
                      setState(() => _selected = null);
                      if (_scroll.hasClients) _scroll.jumpTo(0);
                    },
                  ),
                ),
                Expanded(
                  child: items.isEmpty
                      ? const Center(child: Text('没有可用的匹配操作'))
                      : ListView.builder(
                          key: const ValueKey('app-command-list'),
                          controller: _scroll,
                          itemExtent: 36,
                          itemCount: items.length,
                          itemBuilder: (_, i) {
                            final command = items[i];
                            return ListTile(
                              key: ValueKey('app-command-${command.id}'),
                              dense: true,
                              selected: command.id == _selected,
                              selectedTileColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: .12),
                              title: Text(
                                command.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing:
                                  _query.text.isEmpty &&
                                      widget.recent.ids.contains(command.id)
                                  ? const Icon(Icons.history, size: 14)
                                  : null,
                              onTap: () => _accept(command),
                            );
                          },
                        ),
                ),
                if (height > 150)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: Text(
                      '↑↓ 选择 · Enter 执行应用操作 · Esc 关闭 · 不向远端发送命令',
                      style: TextStyle(fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
