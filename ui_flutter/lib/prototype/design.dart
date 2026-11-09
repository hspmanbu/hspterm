import '../app_notice.dart';

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Round-12 dialog visibility guard. A Flutter dialog cannot leave its
/// window's client area, so when the window itself hangs off the monitor a
/// centered dialog is unreachable. On Windows the runner slides the window
/// back into the monitor work area (size unchanged) before the dialog
/// opens; elsewhere this is a no-op. The dialog body is also height-bounded
/// and scrollable so long text can never push the buttons off-window.
Future<void> ensureDialogHostVisible(
  BuildContext context, {
  double minWidth = 480,
  double minHeight = 400,
}) async {
  if (!Platform.isWindows) return;
  try {
    await const MethodChannel('hspterm/prototype_window').invokeMethod<void>(
      'ensureDialogVisible',
      {'minWidth': minWidth, 'minHeight': minHeight},
    );
  } on MissingPluginException {
    // Non-standard embedding (tests, older runner): the dialog keeps its
    // ordinary in-window centering.
  } on PlatformException {
    // Window geometry unavailable; never block the dialog on this.
  }
}

/// showDialog with screen-bounds awareness (round-12): the host window is
/// first made dialog-visible, and the dialog itself is constrained to the
/// available size with a scrollable body so title/buttons stay reachable.
Future<T?> showBoundedDialog<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool barrierDismissible = true,
}) {
  final size = MediaQuery.sizeOf(context);
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (c) => ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: size.width < 560 ? size.width - 24 : 536,
        maxHeight: size.height - 48,
      ),
      child: builder(c),
    ),
  );
}

abstract final class Desk {
  static const accent = Color(0xff70cbb2);
  static const warning = Color(0xffe5b975);
  static const danger = Color(0xffef9093);
  static const mono = 'JetBrainsMono';
  static ThemeData theme(bool light) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xff2b947c),
          brightness: light ? Brightness.light : Brightness.dark,
        ).copyWith(
          primary: light ? const Color(0xff187963) : accent,
          surface: light ? const Color(0xfff8fafb) : const Color(0xff161b22),
          onSurface: light ? const Color(0xff26333d) : const Color(0xffd9e0e7),
          outlineVariant: light
              ? const Color(0xffd8dfe4)
              : const Color(0xff2c3540),
          surfaceContainerHighest: light
              ? const Color(0xffeaf0f3)
              : const Color(0xff222b35),
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: light
          ? const Color(0xffeef2f5)
          : const Color(0xff10151c),
      fontFamily: 'NotoSansCJK',
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 12),
        bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 11),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontSize: 13),
        titleSmall: base.textTheme.titleSmall?.copyWith(fontSize: 12),
        labelLarge: base.textTheme.labelLarge?.copyWith(fontSize: 12),
      ),
      dividerColor: scheme.outlineVariant,
      iconTheme: IconThemeData(size: 17, color: scheme.onSurfaceVariant),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(30, 30),
          padding: const EdgeInsets.all(6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: light ? Colors.white : const Color(0xff11171e),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 32),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 32),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(32, 30),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        elevation: 6,
        textStyle: TextStyle(
          fontFamily: 'NotoSansCJK',
          color: scheme.onSurface,
          fontSize: 12,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(9),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 450),
      ),
    );
  }
}

class Tool extends StatelessWidget {
  const Tool(
    this.icon,
    this.tip,
    this.action, {
    super.key,
    this.active = false,
    this.size = 16,
  });
  final IconData icon;
  final String tip;
  final VoidCallback? action;
  final bool active;
  final double size;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tip,
    onPressed: action,
    icon: Icon(icon, size: size),
    color: active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant,
  );
}

class DeskBadge extends StatelessWidget {
  const DeskBadge(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .1),
        border: Border.all(color: c.withValues(alpha: .25)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w500),
      ),
    );
  }
}

class ResizeGrip extends StatelessWidget {
  const ResizeGrip({
    super.key,
    required this.horizontal,
    required this.onDelta,
  });
  final bool horizontal;
  final ValueChanged<double> onDelta;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: horizontal
        ? SystemMouseCursors.resizeLeftRight
        : SystemMouseCursors.resizeUpDown,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) => onDelta(horizontal ? d.delta.dx : d.delta.dy),
      child: SizedBox(
        width: horizontal ? 7 : null,
        height: horizontal ? null : 7,
        child: Center(
          child: Container(
            width: horizontal ? 1 : 30,
            height: horizontal ? 30 : 1,
            color: Theme.of(context).dividerColor,
          ),
        ),
      ),
    ),
  );
}

void notice(
  BuildContext context,
  String message, {
  AppNoticeLevel level = AppNoticeLevel.info,
}) => showAppNotice(context, message, level: level);

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String accept = '确认',
  bool danger = false,
}) async {
  await ensureDialogHostVisible(context);
  if (!context.mounted) return false;
  return await showBoundedDialog<bool>(
        context,
        (c) => AlertDialog(
          title: Text(title, style: const TextStyle(fontSize: 17)),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(child: Text(body)),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: danger
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(c).colorScheme.error,
                    )
                  : null,
              onPressed: () => Navigator.pop(c, true),
              child: Text(accept),
            ),
          ],
        ),
      ) ??
      false;
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        ),
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    ),
  );
}

/// Selection is immediate on primary pointer down; double-click can still open.
class SelectionTarget extends StatelessWidget {
  const SelectionTarget({
    super.key,
    required this.child,
    required this.onTapDown,
    this.onDoubleTap,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.borderRadius,
    this.behavior = HitTestBehavior.opaque,
  });
  final Widget child;
  final GestureTapDownCallback onTapDown;
  final GestureTapCallback? onDoubleTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final GestureTapUpCallback? onSecondaryTapUp;
  final BorderRadius? borderRadius;
  final HitTestBehavior behavior;
  @override
  Widget build(BuildContext context) => Listener(
    behavior: behavior,
    onPointerDown: (e) {
      if (e.buttons == 1) {
        onTapDown(
          TapDownDetails(
            globalPosition: e.position,
            localPosition: e.localPosition,
          ),
        );
      }
    },
    child: GestureDetector(
      behavior: behavior,
      onDoubleTap: onDoubleTap,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      child: child,
    ),
  );
}

/// Compact desktop menus keep Flutter's standard focus and keyboard behavior.
class DeskMenuItem<T> extends PopupMenuItem<T> {
  const DeskMenuItem({
    super.key,
    required super.child,
    super.value,
    super.enabled,
    super.onTap,
    super.height = 30,
    super.padding,
  });
}

class DeskCheckedMenuItem<T> extends PopupMenuItem<T> {
  DeskCheckedMenuItem({
    super.key,
    required Widget child,
    super.value,
    bool checked = false,
    super.enabled,
    super.height = 30,
  }) : super(
         padding: const EdgeInsets.symmetric(horizontal: 8),
         child: Row(
           mainAxisSize: MainAxisSize.min,
           children: [
             SizedBox(
               width: 24,
               height: 24,
               child: Checkbox(
                 value: checked,
                 onChanged: null,
                 materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                 visualDensity: VisualDensity.compact,
               ),
             ),
             const SizedBox(width: 8),
             child,
           ],
         ),
       );
}

class DeskMenuDivider extends PopupMenuDivider {
  const DeskMenuDivider({super.key, super.height = 9});
}
