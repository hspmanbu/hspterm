import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show AnyhowException;

String appMessage(Object value) {
  var text = value is AnyhowException ? value.message : value.toString();
  for (final prefix in ['Bad state: ', 'Exception: ']) {
    if (text.startsWith(prefix)) text = text.substring(prefix.length);
  }
  return text.replaceAllMapped(
    RegExp(r'AnyhowException\((.*)\)', dotAll: true),
    (m) => m[1]!,
  );
}

/// Explicit feedback levels. Only [warning] and [error] raise the bottom
/// SnackBar; [info] and [success] appear in the quiet status area instead so
/// ordinary operations never interrupt the user.
enum AppNoticeLevel { info, success, warning, error }

/// One quiet status message published by info/success notices.
class QuietNotice {
  QuietNotice(this.message, this.level, this.at, this.action);
  final String message;
  final AppNoticeLevel level;
  final DateTime at;
  final SnackBarAction? action;
}

/// Process-wide quiet notice stream. The workbench status bar listens and
/// shows the latest message briefly; nothing is logged or persisted here.
final quietNoticeNotifier = ValueNotifier<QuietNotice?>(null);

DateTime? _lastPopupAt;
String? _lastPopupMessage;

/// Test hook: the dedupe window compares wall-clock stamps, which do not
/// advance under `tester.pump`, so tests that re-show the same notice must
/// reset the dedupe state explicitly.
@visibleForTesting
void resetAppNoticeDedupe() {
  _lastPopupMessage = null;
  _lastPopupAt = null;
}

void _publishQuiet(
  String message,
  AppNoticeLevel level,
  SnackBarAction? action,
) {
  quietNoticeNotifier.value = QuietNotice(
    message,
    level,
    DateTime.now(),
    action,
  );
}

void showAppNotice(
  BuildContext context,
  Object message, {
  AppNoticeLevel level = AppNoticeLevel.info,
  SnackBarAction? action,
  SnackBarAction? secondaryAction,
}) {
  final text = appMessage(message);
  if (level != AppNoticeLevel.warning && level != AppNoticeLevel.error) {
    _publishQuiet(text, level, action);
    return;
  }
  final now = DateTime.now();
  if (_lastPopupMessage == text &&
      _lastPopupAt != null &&
      now.difference(_lastPopupAt!) < const Duration(seconds: 3)) {
    return;
  }
  _lastPopupMessage = text;
  _lastPopupAt = now;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  // Errors outrank whatever transient SnackBar is on screen; ordinary quiet
  // notices never touch the SnackBar at all.
  messenger.hideCurrentSnackBar();
  // SnackBar renders one trailing action natively; a second action (e.g.
  // forwarding "重试" plus "查看") is laid out inline with matching color.
  Widget content = Text(text);
  if (secondaryAction != null && action != null) {
    final inverse = Theme.of(context).colorScheme.inversePrimary;
    content = Row(
      children: [
        Expanded(child: Text(text)),
        TextButton(
          onPressed: action.onPressed,
          child: Text(action.label, style: TextStyle(color: inverse)),
        ),
        TextButton(
          onPressed: secondaryAction.onPressed,
          child: Text(secondaryAction.label, style: TextStyle(color: inverse)),
        ),
      ],
    );
  }
  messenger.showSnackBar(
    SnackBar(
      content: content,
      duration: const Duration(seconds: 6),
      showCloseIcon: true,
      persist: false,
      behavior: SnackBarBehavior.floating,
      action: secondaryAction != null && action != null ? null : action,
    ),
  );
}

/// Shows the latest quiet notice in the status area, fading it out after
/// [visibleFor]. Errors never appear here, so a quiet message cannot cover a
/// real SnackBar error.
class QuietNoticeView extends StatefulWidget {
  const QuietNoticeView({
    super.key,
    this.visibleFor = const Duration(seconds: 4),
  });
  final Duration visibleFor;
  @override
  State<QuietNoticeView> createState() => _QuietNoticeViewState();
}

class _QuietNoticeViewState extends State<QuietNoticeView> {
  Timer? _fade;
  @override
  void initState() {
    super.initState();
    quietNoticeNotifier.addListener(_changed);
  }

  @override
  void dispose() {
    _fade?.cancel();
    quietNoticeNotifier.removeListener(_changed);
    // Release action closures referencing closed SSH sessions.
    quietNoticeNotifier.value = null;
    super.dispose();
  }

  void _changed() {
    _fade?.cancel();
    if (quietNoticeNotifier.value != null) {
      _fade = Timer(widget.visibleFor, () {
        if (mounted) {
          quietNoticeNotifier.value = null;
        }
      });
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final notice = quietNoticeNotifier.value;
    if (notice == null ||
        DateTime.now().difference(notice.at) > widget.visibleFor) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final color = notice.level == AppNoticeLevel.success
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Tooltip(
              message: notice.message,
              child: Text(
                compactNotice(notice.message),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
          ),
          if (notice.action case final action?)
            TextButton(onPressed: action.onPressed, child: Text(action.label)),
        ],
      ),
    );
  }
}

/// Keep routine status text compact; retain the full text in its tooltip.
String compactNotice(String text) {
  final first = text.split(RegExp(r'[；;\n]')).first.trim();
  return first.runes.length <= 18
      ? first
      : '${String.fromCharCodes(first.runes.take(17))}…';
}
