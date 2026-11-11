import 'dart:math' as math;
import 'dart:ui' as ui;

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
  late final _numbers = _LineNumbers(_scroll, _layoutChanged);
  double _height = 240;
  @override
  void dispose() {
    _numbers.disposeLayout();
    _layoutChanged.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontFamily: 'JetBrainsMono',
      fontSize: 14,
      height: 1.4,
    );
    const strut = StrutStyle(
      fontFamily: 'JetBrainsMono',
      fontSize: 14,
      height: 1.4,
      forceStrutHeight: true,
    );
    final scheme = Theme.of(context).colorScheme;
    final maxHeight = math.max(100.0, MediaQuery.sizeOf(context).height * .55);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: _height.clamp(100.0, maxHeight),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
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
                math.max(1, constraints.maxWidth - gutter - rail - 16),
                style,
                strut,
                MediaQuery.textScalerOf(context),
                scheme.onSurfaceVariant,
              );
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
                            behavior: const MaterialScrollBehavior().copyWith(
                              scrollbars: false,
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
              onVerticalDragUpdate: (event) => setState(() {
                _height = (_height + event.delta.dy).clamp(100.0, maxHeight);
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

class _LineNumbers extends CustomPainter {
  _LineNumbers(this.scroll, this.changes)
    : super(repaint: Listenable.merge([scroll, changes]));
  final ValueNotifier<int> changes;
  final ScrollController scroll;
  final _layout = TextPainter(textDirection: TextDirection.ltr);
  String? _text;
  double? _width;
  TextScaler? _scaler;
  Color color = Colors.grey;
  final _positions = <double>[];
  void configure(
    String text,
    double width,
    TextStyle style,
    StrutStyle strut,
    TextScaler scaler,
    Color value,
  ) {
    if (_text == text &&
        _width == width &&
        _scaler == scaler &&
        color == value) {
      return;
    }
    color = value;
    _text = text;
    _width = width;
    _scaler = scaler;
    _layout.text = TextSpan(text: text, style: style);
    _layout.strutStyle = strut;
    _layout.textScaler = scaler;
    _layout.layout(maxWidth: width);
    _positions.clear();
    _positions.add(
      _layout.getOffsetForCaret(const TextPosition(offset: 0), Rect.zero).dy,
    );
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10 ||
          text.codeUnitAt(i) == 13 &&
              (i + 1 == text.length || text.codeUnitAt(i + 1) != 10)) {
        _positions.add(
          _layout.getOffsetForCaret(TextPosition(offset: i + 1), Rect.zero).dy,
        );
      }
    }
    changes.value++;
  }

  void disposeLayout() => _layout.dispose();
  @override
  void paint(Canvas canvas, Size size) {
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    final label = TextPainter(textDirection: TextDirection.ltr);
    try {
      for (var i = 0; i < _positions.length; i++) {
        final y = _positions[i] + 10 - offset;
        if (y < -30) continue;
        if (y > size.height) break;
        label.text = TextSpan(
          text: '${i + 1}',
          style: TextStyle(fontSize: 11, color: color),
        );
        label.textScaler = _scaler ?? TextScaler.noScaling;
        label.layout();
        label.paint(canvas, Offset(size.width - label.width - 8, y + 3));
      }
    } finally {
      label.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _LineNumbers oldDelegate) => true;
}
