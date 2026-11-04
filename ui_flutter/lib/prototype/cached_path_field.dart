import 'dart:async';

import 'package:flutter/material.dart';

import 'model.dart';

/// Local cache only. Never call a directory reader, mutate the cache or infer a
/// symlink's target. Limit both retained results and per-event-loop work.
Future<List<String>> cachedDirectorySuggestions(
  String query,
  Map<String, List<DemoFile>> cache, {
  required bool Function() cancelled,
}) async {
  if (!query.startsWith('/') ||
      query.contains('\u0000') ||
      query.length > 4096) {
    return const [];
  }
  final matches = <String>[];
  void offer(String path) {
    if (path.length > 4096 ||
        path.contains('\u0000') ||
        path == query ||
        !path.startsWith(query)) {
      return;
    }
    if (matches.contains(path)) return;
    var index = matches.indexWhere((item) => item.compareTo(path) > 0);
    if (index < 0) index = matches.length;
    if (index >= 12) return;
    matches.insert(index, path);
    if (matches.length > 12) matches.removeLast();
  }

  // The live LRU contains at most 16 keys. Capture keys before yielding so a
  // refresh/eviction cannot invalidate an iterator across asynchronous work.
  for (final path in cache.keys.toList()) {
    if (cancelled()) return const [];
    offer(path);
  }
  final slash = query.lastIndexOf('/');
  final parent = slash == 0 ? '/' : query.substring(0, slash);
  final prefix = query.substring(slash + 1);
  final stem = parent == '/' ? '' : parent;
  final maxNameLength = 4096 - stem.length - 1;
  final files = cache[parent];
  if (files == null) return matches;
  for (var i = 0; i < files.length; i++) {
    if (cancelled()) return const [];
    final file = files[i];
    if (file.folder &&
        file.name.length <= maxNameLength &&
        file.name.startsWith(prefix) &&
        !file.name.contains('/') &&
        !file.name.contains('\u0000')) {
      offer('$stem/${file.name}');
    }
    if ((i + 1) % 512 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return cancelled() ? const [] : matches;
}

class CachedPathField extends StatefulWidget {
  const CachedPathField({
    super.key,
    required this.controller,
    required this.currentDirectory,
    required this.cache,
    required this.onSubmitted,
    this.contextMenuExtras,
  });
  final List<ContextMenuButtonItem> Function(EditableTextState)?
  contextMenuExtras;
  final TextEditingController controller;
  final String currentDirectory;
  final Map<String, List<DemoFile>> cache;
  final ValueChanged<String> onSubmitted;
  @override
  State<CachedPathField> createState() => _CachedPathFieldState();
}

class _CachedPathFieldState extends State<CachedPathField> {
  final _focus = FocusNode();
  final _optionsScroll = ScrollController();
  int _request = 0;
  String? _query;
  Future<List<String>>? _lookup;
  Completer<void>? _composition;
  bool get _composing =>
      widget.controller.value.composing.isValid &&
      !widget.controller.value.composing.isCollapsed;
  void _releaseComposition() {
    final gate = _composition;
    _composition = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void _invalidate() {
    _request++;
    _query = null;
    _lookup = null;
    _releaseComposition();
  }

  void _controllerChanged() {
    if (!_composing) _releaseComposition();
  }

  Future<List<String>> _options(TextEditingValue value) {
    if (_query == value.text && _lookup != null) return _lookup!;
    _invalidate();
    _query = value.text;
    final request = _request;
    return _lookup = () async {
      // RawAutocomplete discards composition-only updates with unchanged text.
      // Keep its original text-change request pending until IME commits, and
      // share that work with the composition-only callback. Never alter text.
      if (_composing) {
        final gate = _composition = Completer<void>();
        await gate.future;
      }
      if (!mounted ||
          request != _request ||
          value.text == widget.currentDirectory) {
        return const <String>[];
      }
      return cachedDirectorySuggestions(
        value.text,
        widget.cache,
        cancelled: () => !mounted || request != _request,
      );
    }();
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
    _focus.addListener(() {
      if (!_focus.hasFocus) _invalidate();
    });
  }

  @override
  void didUpdateWidget(CachedPathField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _invalidate();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _invalidate();
    _focus.dispose();
    _optionsScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => RawAutocomplete<String>(
      textEditingController: widget.controller,
      focusNode: _focus,
      optionsBuilder: _options,
      fieldViewBuilder: (context, controller, focus, accept) => TextField(
        contextMenuBuilder: (context, field) =>
            AdaptiveTextSelectionToolbar.buttonItems(
              anchors: field.contextMenuAnchors,
              buttonItems: [
                ...field.contextMenuButtonItems,
                ...?widget.contextMenuExtras?.call(field),
              ],
            ),
        key: const ValueKey('remote-path'),
        controller: controller,
        focusNode: focus,
        style: const TextStyle(fontSize: 11, fontFamily: 'JetBrainsMono'),
        decoration: const InputDecoration(
          hintText: '绝对路径（仅缓存补全）',
          contentPadding: EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        ),
        onSubmitted: (_) {
          accept();
          widget.onSubmitted(controller.text);
        },
      ),
      optionsViewBuilder: (context, select, values) {
        final options = values.toList();
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(4),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: constraints.maxWidth,
              height: (options.length * 30).clamp(30, 210).toDouble(),
              child: ListView.builder(
                controller: _optionsScroll,
                padding: EdgeInsets.zero,
                itemCount: options.length,
                itemExtent: 30,
                itemBuilder: (context, index) {
                  final highlighted =
                      AutocompleteHighlightedOption.of(context) == index;
                  if (highlighted) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || !_optionsScroll.hasClients) return;
                      final position = _optionsScroll.position;
                      final top = index * 30.0;
                      if (top < position.pixels ||
                          top + 30 >
                              position.pixels + position.viewportDimension) {
                        _optionsScroll.jumpTo(
                          (top - position.viewportDimension / 2 + 15).clamp(
                            position.minScrollExtent,
                            position.maxScrollExtent,
                          ),
                        );
                      }
                    });
                  }
                  final path = options[index];
                  final query = widget.controller.text;
                  final parent = query.substring(0, query.lastIndexOf('/') + 1);
                  final label = path.startsWith(parent)
                      ? path.substring(parent.length)
                      : path;
                  return Tooltip(
                    message: path,
                    child: InkWell(
                      key: ValueKey('cached-path-${options[index]}'),
                      onTap: () => select(options[index]),
                      child: ColoredBox(
                        color: highlighted
                            ? Theme.of(context).colorScheme.primary
                                  .withValues(alpha: .14)
                            : Colors.transparent,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    ),
  );
}
