import 'package:flutter/material.dart';

import '../terminal/backend.dart';
import '../terminal/controller.dart';
import '../terminal/painter.dart';
import '../src/rust/api.dart' as rust;
import 'model.dart';

/// Reuses Phase 2's actual painter/cache. Never starts a backend or loads FRB.
/// Fixture cells and the local input demonstration are not a terminal emulator.
class TerminalPreview extends StatefulWidget {
  const TerminalPreview({super.key, required this.pane});
  final TerminalSession pane;
  @override
  State<TerminalPreview> createState() => _TerminalPreviewState();
}

class _TerminalPreviewState extends State<TerminalPreview> {
  final _controller = TerminalController(const NativeTerminalBackend());
  final _cache = TerminalPaintCache();
  final _blink = ValueNotifier(true), _preedit = ValueNotifier('');
  late final TextEditingController _input;
  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.pane.draft);
  }

  @override
  void didUpdateWidget(TerminalPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_input.text != widget.pane.draft) _input.text = widget.pane.draft;
  }

  @override
  void dispose() {
    _input.dispose();
    _cache.dispose();
    _controller.dispose();
    _blink.dispose();
    _preedit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final background = light ? 0xfffbfcfd : 0xff10151c;
    final fg = light ? 0xff3d4c5e : 0xffbdc8d5;
    final green = light ? 0xff1c8065 : 0xff70cbb2;
    final lines = <(String, int)>[
      ('${widget.pane.host.user}@${widget.pane.host.address}', green),
      ('/home/ubuntu/project  |  SSH UI PREVIEW', 0xff7f8da1),
      ('', fg),
      ('\$ git status --short', fg),
      (' M  src/main.rs', 0xffd9b66e),
      (' M  ui_flutter/lib/workbench.dart', 0xffd9b66e),
      ('', fg),
      ('\$ cargo build --release', fg),
      ('   Compiling hspterm v0.1.0', green),
      ('    Finished release target(s) in 2.41s', green),
      ('', fg),
      ('[preview] All output above is synthetic.', 0xff7f8da1),
      ...widget.pane.entered.map((s) => ('[local preview] $s', green)),
    ];
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(
              builder: (context, bounds) {
                const cell = Size(7.8, 20);
                final cols = (bounds.maxWidth / cell.width).floor().clamp(
                      1,
                      1000,
                    ),
                    rows = (bounds.maxHeight / cell.height).floor().clamp(
                      1,
                      200,
                    );
                final start = (lines.length - rows).clamp(0, lines.length);
                _controller.applyFrame(
                  rust.RenderFrame(
                    revision: _controller.frameCount + 1,
                    contentRevision: 1,
                    outputLines: 0,
                    sizeLocked: false,
                    searchSpans: const [],
                    columns: cols,
                    rows: rows,
                    full: true,
                    changedRows: List.generate(rows, (r) {
                      final line = r + start < lines.length
                          ? lines[r + start]
                          : ('', fg);
                      return rust.RenderRow(
                        index: r,
                        cells: List.generate(
                          cols,
                          (c) => rust.RenderCell(
                            text: c < line.$1.length ? line.$1[c] : ' ',
                            foreground: line.$2,
                            background: background,
                            flags: 0,
                          ),
                        ),
                      );
                    }),
                    cursorColumn: 0,
                    cursorRow: rows - 1,
                    cursorVisible: false,
                    cursorShape: 1,
                    cursorBlink: false,
                    cursorColor: green,
                    background: background,
                    alternateScreen: false,
                    mouseReporting: false,
                    historyLines: 0,
                    displayOffset: 0,
                  ),
                );
                return RepaintBoundary(
                  child: CustomPaint(
                    size: bounds.biggest,
                    painter: TerminalPainter(
                      _controller,
                      _cache,
                      13,
                      cell,
                      _blink,
                      false,
                      _preedit,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (!widget.pane.disconnected)
          SizedBox(
            height: 30,
            child: Row(
              children: [
                const SizedBox(width: 9),
                Text('›', style: TextStyle(color: Color(green))),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: ValueKey('mock-input-${widget.pane.id}'),
                    controller: _input,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                      color: Color(fg),
                    ),
                    decoration: const InputDecoration(
                      hintText: '本地输入演示 · 不发送到服务器',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (s) => widget.pane.draft = s,
                    onSubmitted: (s) {
                      setState(() {
                        widget.pane.entered.add(s);
                        widget.pane.draft = '';
                        _input.clear();
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
