import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';

/// Local-only preview. Line numbers and resize chrome never enter the text.
class PasteEditor extends StatefulWidget {
  const PasteEditor({
    super.key,
    required this.controller,
    required this.onChanged,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  @override
  State<PasteEditor> createState() => _PasteEditorState();
}

class _PasteEditorState extends State<PasteEditor> {
  final _scroll = ScrollController();
  final _layoutChanged = ValueNotifier<int>(0);
  final _field = GlobalKey();
  final _gutter = GlobalKey();
  late final _numbers = _LineNumbers(
    _scroll,
    _layoutChanged,
    () {
      EditableTextState? result;
      void visit(Element element) {
        if (element is StatefulElement && element.state is EditableTextState) {
          result = element.state as EditableTextState;
        } else {
          element.visitChildren(visit);
        }
      }

      _field.currentContext?.visitChildElements(visit);
      return result?.renderEditable;
    },
    () => _gutter.currentContext?.findRenderObject() as RenderBox?,
    () => widget.controller.text,
  );
  double _dragY = 0, _dragHeight = 0;
  double _height = 240;
  @override
  void dispose() {
    _layoutChanged.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodyMedium!.copyWith(
      fontSize: 14,
      height: 1.4,
    );
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
    final background = Color.alphaBlend(
      Colors.white.withValues(
        alpha: theme.brightness == Brightness.dark ? .035 : .3,
      ),
      scheme.surface,
    );
    // Selection rectangles can overlap around wrapped and empty lines. Blend
    // once, then paint opaque rectangles so overlaps never form darker bands.
    final selection = Color.alphaBlend(
      theme.textSelectionTheme.selectionColor ??
          scheme.primary.withValues(alpha: .3),
      background,
    );
    final maxHeight = math.max(100.0, MediaQuery.sizeOf(context).height * .55);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: _height.clamp(100.0, maxHeight),
          decoration: BoxDecoration(
            color: background,
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(4),
          ),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(
            builder: (context, constraints) {
              const rail = 22.0;
              final digits = (widget.controller.text.split('\n').length)
                  .toString()
                  .length;
              final gutter = math.max(
                44.0,
                MediaQuery.textScalerOf(context).scale(8) * digits + 16,
              );
              _numbers.configure(
                widget.controller.text,
                MediaQuery.textScalerOf(context),
                scheme.onSurfaceVariant,
              );
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _layoutChanged.value++;
              });
              return MouseRegion(
                cursor: SystemMouseCursors.basic,
                child: RawScrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  interactive: true,
                  thickness: 7,
                  crossAxisMargin: 5,
                  child: Padding(
                    padding: const EdgeInsets.only(right: rail),
                    child: Row(
                      children: [
                        SizedBox(
                          key: _gutter,
                          width: gutter,
                          height: double.infinity,
                          child: ClipRect(
                            child: CustomPaint(
                              key: const ValueKey('paste-line-numbers'),
                              painter: _numbers,
                            ),
                          ),
                        ),
                        Expanded(
                          child: ScrollConfiguration(
                            behavior: const _EditorScrollBehavior(),
                            child: KeyedSubtree(
                              key: _field,
                              child: TextSelectionTheme(
                                data: theme.textSelectionTheme.copyWith(
                                  selectionColor: selection,
                                ),
                                child: TextField(
                                  key: const ValueKey('terminal-paste-editor'),
                                  controller: widget.controller,
                                  scrollController: _scroll,
                                  onChanged: (value) {
                                    setState(() {});
                                    widget.onChanged(value);
                                  },
                                  style: style,
                                  strutStyle: strut,
                                  selectionHeightStyle: ui.BoxHeightStyle.max,
                                  selectionWidthStyle: ui.BoxWidthStyle.max,
                                  textAlignVertical: TextAlignVertical.top,
                                  expands: true,
                                  minLines: null,
                                  maxLines: null,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    filled: false,
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 10,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpDown,
            child: GestureDetector(
              key: const ValueKey('paste-resize-handle'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: (event) {
                _dragY = event.globalPosition.dy;
                _dragHeight = _height.clamp(100.0, maxHeight);
              },
              onVerticalDragUpdate: (event) => setState(() {
                _height = (_dragHeight + event.globalPosition.dy - _dragY)
                    .clamp(100.0, maxHeight);
              }),
              child: const SizedBox(
                width: 52,
                height: 18,
                child: Icon(Icons.drag_handle, size: 16),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EditorScrollBehavior extends MaterialScrollBehavior {
  const _EditorScrollBehavior();
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

class _LineNumbers extends CustomPainter {
  _LineNumbers(
    this.scroll,
    this.changes,
    this.editable,
    this.gutter,
    this.currentText,
  ) : super(repaint: Listenable.merge([scroll, changes]));
  final ValueNotifier<int> changes;
  final ScrollController scroll;
  final RenderEditable? Function() editable;
  final RenderBox? Function() gutter;
  final String Function() currentText;
  final _starts = <int>[0];
  String? _text;
  TextScaler scaler = TextScaler.noScaling;
  Color color = Colors.grey;
  void configure(String text, TextScaler value, Color ink) {
    scaler = value;
    color = ink;
    if (_text == text) return;
    _text = text;
    _starts.clear();
    _starts.add(0);
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10 ||
          text.codeUnitAt(i) == 13 &&
              (i + 1 == text.length || text.codeUnitAt(i + 1) != 10)) {
        _starts.add(i + 1);
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    configure(currentText(), scaler, color);
    final render = editable(), box = gutter();
    if (render == null || box == null || !render.hasSize || !box.hasSize) {
      return;
    }
    Rect caret(int i) {
      final rect = render.getLocalRectForCaret(
        TextPosition(offset: _starts[i]),
      );
      return box.globalToLocal(render.localToGlobal(rect.topLeft)) & rect.size;
    }

    final label = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    );
    try {
      var lo = 0, hi = _starts.length;
      while (lo < hi) {
        final mid = (lo + hi) ~/ 2;
        if (caret(mid).bottom < 0) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      for (var i = lo; i < _starts.length; i++) {
        final rect = caret(i);
        if (rect.top > size.height) break;
        label.text = TextSpan(
          text: '${i + 1}',
          style: TextStyle(fontSize: 11, color: color),
        );
        label.layout();
        label.paint(
          canvas,
          Offset(
            size.width - label.width - 8,
            rect.center.dy - label.height / 2,
          ),
        );
      }
    } finally {
      label.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _LineNumbers oldDelegate) => true;
}
