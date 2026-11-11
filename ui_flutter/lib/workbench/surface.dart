import '../app_notice.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../prototype/design.dart';
import '../terminal/view.dart';
import '../terminal/links.dart';
import '../terminal/typography.dart';
import 'model.dart';
import '../prototype/files.dart' show RemoteDrag;

class LiveTerminalSurface extends StatefulWidget {
  const LiveTerminalSurface({
    super.key,
    required this.session,
    required this.focused,
    required this.fontSize,
    this.typography,
    this.typographyNotice,
    this.retryTypography,
    this.onLocatePath,
    this.onOpenLink,
    this.onPasteImage,
    this.onDropPaths,
  });
  final LiveTerminalSession session;
  final Future<void> Function()? onPasteImage;
  final bool focused;
  final double fontSize;
  final TerminalTypography? typography;
  final String? typographyNotice;
  final VoidCallback? retryTypography;
  final Future<void> Function(String)? onLocatePath;
  final Future<void> Function(TerminalLink)? onOpenLink;
  final Future<void> Function(List<String>, int)? onDropPaths;
  @override
  State<LiveTerminalSurface> createState() => _LiveTerminalSurfaceState();
}

class _LiveTerminalSurfaceState extends State<LiveTerminalSurface> {
  late final Object _lease;
  @override
  void initState() {
    super.initState();
    _lease = widget.session.attachView();
    _focus();
  }

  @override
  void didUpdateWidget(LiveTerminalSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focused && !oldWidget.focused) _focus();
  }

  void _focus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.focused) {
        widget.session.view.currentState?.focusTerminal();
      }
    });
  }

  @override
  void dispose() {
    widget.session.detachView(_lease);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.session.controller;
    final recovery = c.reconnectNotice;
    if (c.connected && recovery != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && c.reconnectNotice == recovery) {
          showAppNotice(context, recovery, level: AppNoticeLevel.warning);
          c.dismissReconnectNotice();
        }
      });
    }
    return Column(
      children: [
        if (widget.typographyNotice != null)
          Row(
            children: [
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.typographyNotice!,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 10),
                ),
              ),
              TextButton(
                onPressed: widget.retryTypography,
                child: const Text('重试', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
        if (!c.connected)
          Container(
            constraints: const BoxConstraints(minHeight: 31),
            padding: const EdgeInsets.only(left: 9, right: 3),
            color: Desk.warning.withValues(alpha: .1),
            child: Row(
              children: [
                const Icon(Icons.link_off, size: 14, color: Desk.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Tooltip(
                    message: c.error ?? widget.session.statusLabel,
                    child: Text(
                      '${widget.session.statusLabel}${c.error == null ? '' : ' · ${c.error}'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: Desk.warning),
                    ),
                  ),
                ),
                if (c.phase == 'Connecting')
                  TextButton(
                    onPressed: () {
                      if (c.id != null) {
                        unawaited(c.backend.cancel(c.id!).catchError(c.report));
                      }
                    },
                    child: const Text('取消', style: TextStyle(fontSize: 10)),
                  ),
                if (c.phase == 'Failed' || c.phase == 'Disconnected')
                  TextButton(
                    onPressed: () => unawaited(c.reconnect()),
                    child: const Text('重新连接', style: TextStyle(fontSize: 10)),
                  ),
              ],
            ),
          ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.all(widget.typography?.padding ?? 8),
            child: DragTarget<RemoteDrag>(
              key: ValueKey('terminal-path-drop-${widget.session.id}'),
              onWillAcceptWithDetails: (details) =>
                  widget.onDropPaths != null &&
                  c.connected &&
                  details.data.sessionId == widget.session.id &&
                  details.data.generation == c.generation,
              onAcceptWithDetails: (details) {
                final drag = details.data, expected = c.generation;
                if (!c.connected ||
                    drag.sessionId != widget.session.id ||
                    drag.generation != expected) {
                  return;
                }
                final paths = [
                  for (final file in drag.files)
                    '${drag.sourcePath.endsWith('/') ? drag.sourcePath : '${drag.sourcePath}/'}${file.name}',
                ];
                unawaited(
                  widget.onDropPaths!(paths, expected).catchError(c.report),
                );
              },
              builder: (context, candidates, rejected) => DecoratedBox(
                decoration: BoxDecoration(
                  border: candidates.isEmpty
                      ? null
                      : Border.all(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                ),
                child: TerminalView(
                  key: widget.session.view,
                  controller: c,
                  fontSize: widget.fontSize,
                  typography: widget.typography,
                  onLocatePath: widget.onLocatePath,
                  onOpenLink: widget.onOpenLink,
                  onPasteImage: widget.onPasteImage,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
