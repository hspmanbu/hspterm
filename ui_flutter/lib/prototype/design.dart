import '../app_notice.dart';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Returns the visible client rectangle in physical pixels after the runner
/// has brought a minimally usable area onto the nearest monitor.
Future<Rect?> _visibleDialogArea() async {
  // Use the framework's platform so adapter behavior can be exercised under
  // widget tests on other hosts. ThemeData.platform does not alter this value.
  if (defaultTargetPlatform != TargetPlatform.windows) return null;
  try {
    final bounds = await const MethodChannel('hspterm/prototype_window')
        .invokeListMethod<double>('ensureDialogVisible', {
          'minWidth': 480.0,
          'minHeight': 400.0,
        });
    if (bounds != null &&
        bounds.length == 4 &&
        bounds.every((v) => v.isFinite) &&
        bounds[2] > 0 &&
        bounds[3] > 0) {
      return Rect.fromLTWH(bounds[0], bounds[1], bounds[2], bounds[3]);
    }
  } on MissingPluginException {
    // Unit tests and alternative embeddings have no native geometry channel.
  } on PlatformException {
    // Geometry failures must not hide the actual operation's dialog.
  }
  return null;
}

Future<void> ensureDialogHostVisible(
  BuildContext context, {
  double minWidth = 480,
  double minHeight = 400,
}) async {
  await _visibleDialogArea();
}

/// The only business-dialog route. Native geometry uses physical pixels;
/// layout uses the current view's scale after any monitor/DPI move.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final route = await createAppDialogRoute<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
  );
  if (route == null || !context.mounted) return null;
  return Navigator.of(context, rootNavigator: true).push(route);
}

/// For owners that must wait for route.completed before disposing controllers
/// or remove a route when its original SSH session closes.
Future<DialogRoute<T>?> createAppDialogRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final physicalArea = await _visibleDialogArea();
  if (!context.mounted) return null;
  if (physicalArea != null) {
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted) return null;
  }
  final scale = View.of(context).devicePixelRatio;
  final area = physicalArea == null
      ? null
      : Rect.fromLTRB(
          physicalArea.left / scale,
          physicalArea.top / scale,
          physicalArea.right / scale,
          physicalArea.bottom / scale,
        );
  return DialogRoute<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (_) => DialogViewport(visibleArea: area, builder: builder),
  );
}

/// Keeps all dialog layout (including MediaQuery-driven panels) inside the
/// visible portion of the client area, without shrinking desktop panels to a
/// phone-sized fixed width. The barrier still covers the whole window.
class DialogViewport extends StatelessWidget {
  const DialogViewport({super.key, this.visibleArea, required this.builder});
  final Rect? visibleArea;
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final full = Offset.zero & box.biggest;
      final area = visibleArea?.intersect(full) ?? full;
      final usable = area.isEmpty ? full : area;
      return Stack(
        children: [
          Positioned.fromRect(
            rect: usable,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(size: usable.size),
              child: Builder(builder: builder),
            ),
          ),
        ],
      );
    },
  );
}

Future<T?> showBoundedDialog<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool barrierDismissible = true,
}) => showAppDialog<T>(
  context: context,
  builder: builder,
  barrierDismissible: barrierDismissible,
);

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
  return await showBoundedDialog<bool>(
        context,
        (c) => AlertDialog(
          scrollable: true,
          title: Text(title, style: const TextStyle(fontSize: 17)),
          content: SizedBox(width: 380, child: Text(body)),
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
