import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

/// The system catalogue can contain thousands of families. Keep only strings
/// until this route is opened, and build text/layout objects for visible rows.
Future<String?> showTerminalFontPicker(
  BuildContext context, {
  required String selected,
  required Map<String, String> choices,
  required Future<List<String>> Function() systemFamilies,
}) => showDialog<String>(
  context: context,
  builder: (_) => _FontPicker(
    selected: selected,
    choices: choices,
    systemFamilies: systemFamilies,
  ),
);

class _FontPicker extends StatefulWidget {
  const _FontPicker({
    required this.selected,
    required this.choices,
    required this.systemFamilies,
  });
  final String selected;
  final Map<String, String> choices;
  final Future<List<String>> Function() systemFamilies;
  @override
  State<_FontPicker> createState() => _FontPickerState();
}

class _FontPickerState extends State<_FontPicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late final _choices = Map<String, String>.of(widget.choices);
  late List<MapEntry<String, String>> _visible;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _filter();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final names = await widget.systemFamilies();
      if (!mounted) return;
      setState(() {
        for (final name in names) {
          _choices['system:$name'] = '系统 · $name';
        }
        _filter();
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = '系统字体列表暂不可用，仍可选择内置或已导入字体。');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _filter() {
    final query = _search.text.trim().toLowerCase();
    _visible = _choices.entries
        .where((e) => e.value.toLowerCase().contains(query))
        .toList(growable: false);
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择终端字体'),
    content: SizedBox(
      width: 520,
      height: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('font-picker-search'),
            controller: _search,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '搜索字体',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (_) => setState(() {
              if (_scroll.hasClients) _scroll.jumpTo(0);
              _filter();
            }),
            onSubmitted: (_) {
              if (_visible.isNotEmpty) {
                Navigator.pop(context, _visible.first.key);
              }
            },
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          const SizedBox(height: 8),
          Text('${_visible.length} 项字体'),
          const SizedBox(height: 4),
          Expanded(
            child: _visible.isEmpty
                ? const Center(child: Text('没有匹配的字体'))
                : Scrollbar(
                    controller: _scroll,
                    child: ListView.builder(
                      key: const ValueKey('font-picker-list'),
                      controller: _scroll,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                      itemCount: _visible.length,
                      itemBuilder: (context, i) {
                        final entry = _visible[i];
                        return ListTile(
                          key: ValueKey('font-option-${entry.key}'),
                          dense: true,
                          selected: entry.key == widget.selected,
                          title: Text(entry.value),
                          trailing: entry.key == widget.selected
                              ? const Icon(Icons.check, size: 18)
                              : null,
                          onTap: () => Navigator.pop(context, entry.key),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}
