import 'dart:math';

import 'package:flutter/material.dart';

import 'suggestions.dart';

class TerminalSuggestionsOverlay extends StatefulWidget {
  const TerminalSuggestionsOverlay({
    super.key,
    required this.controller,
    required this.viewport,
    required this.cell,
    required this.cursorColumn,
    required this.cursorRow,
    required this.choose,
    required this.delete,
  });
  final TerminalSuggestionsController controller;
  final Size viewport, cell;
  final int cursorColumn, cursorRow;
  final void Function(int, String) choose;

  /// Round-12: tombstone-delete the command at [index]; the ticket guards
  /// staleness on the Rust side.
  final void Function(int, String) delete;
  @override
  State<TerminalSuggestionsOverlay> createState() =>
      _TerminalSuggestionsOverlayState();
}

/// Always occupies a fixed slot so the row layout does not shift on hover.
class _CandidateDeleteButton extends StatelessWidget {
  const _CandidateDeleteButton({required this.onDelete});
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 26,
    height: 24,
    child: IconButton(
      tooltip: '删除该历史记录',
      padding: EdgeInsets.zero,
      iconSize: 16,
      onPressed: onDelete,
      icon: const Icon(Icons.delete_outline),
    ),
  );
}

class _TerminalSuggestionsOverlayState
    extends State<TerminalSuggestionsOverlay> {
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_reveal);
  }

  @override
  void didUpdateWidget(TerminalSuggestionsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_reveal);
      widget.controller.addListener(_reveal);
    }
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !widget.controller.showing) return;
      if (widget.controller.selected < 0) return;
      final top = widget.controller.selected * 30.0;
      final position = _scroll.position;
      final next = top < position.pixels
          ? top
          : top + 30 > position.pixels + position.viewportDimension
          ? top + 30 - position.viewportDimension
          : position.pixels;
      if (next != position.pixels) {
        _scroll.jumpTo(next.clamp(0.0, position.maxScrollExtent));
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_reveal);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final state = widget.controller, size = widget.viewport;
        if (!state.showing || size.width < 120 || size.height < 70) {
          return const IgnorePointer(child: SizedBox.expand());
        }
        final choices = state.view!.choices;
        final ticket = state.view!.ticket;
        final width = min(480.0, size.width - 18);
        final height = min(
          200.0,
          min(choices.length * 30.0 + 24, size.height * .5),
        );
        final left = (widget.cursorColumn * widget.cell.width).clamp(
          0.0,
          max(0.0, size.width - width - 12),
        );
        final below = (widget.cursorRow + 1) * widget.cell.height;
        final top =
            (below + height <= size.height
                    ? below
                    : below - widget.cell.height - height)
                .clamp(0.0, max(0.0, size.height - height));
        return Stack(
          children: [
            Positioned(
              left: left.toDouble(),
              top: top.toDouble(),
              width: width,
              height: height,
              child: Material(
                elevation: 5,
                borderRadius: BorderRadius.circular(4),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(
                      height: 24,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        child: Text(
                          '历史命令 · Enter执行 · Tab填入 · Esc关闭',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: EdgeInsets.zero,
                        itemCount: choices.length,
                        itemBuilder: (context, index) => InkWell(
                          key: ValueKey('history-candidate-$index-$ticket'),
                          canRequestFocus: false,
                          onTap: () => widget.choose(index, ticket),
                          child: Container(
                            height: 30,
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            color: index == state.selected
                                ? Theme.of(context).colorScheme.primary
                                      .withValues(alpha: .18)
                                : null,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Tooltip(
                                    message: choices[index],
                                    child: Text(
                                      choices[index],
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                ),
                                // Round-12: hover-revealed delete; removing
                                // the tombstoned command never selects or
                                // executes the row.
                                _CandidateDeleteButton(
                                  onDelete: () => widget.delete(index, ticket),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
