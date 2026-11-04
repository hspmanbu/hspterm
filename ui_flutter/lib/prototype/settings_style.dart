import 'package:flutter/material.dart';

/// Floating field labels extend above the outline; reserve outside spacing,
/// rather than relying on InputDecoration's padding inside the border.
class SettingsField extends StatelessWidget {
  const SettingsField({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: child);
}

/// Keep the whole settings row clickable while using the slimmer desktop
/// switch geometry. Text, colors and keyboard semantics retain the page theme.
class CompactSettingsToggle extends StatelessWidget {
  const CompactSettingsToggle({super.key, required this.child});
  final Widget child;
  static final _themes = Expando<ThemeData>();
  @override
  Widget build(BuildContext context) {
    final source = Theme.of(context);
    final theme = _themes[source] ??= ThemeData(
      useMaterial3: false,
      colorScheme: source.colorScheme,
      textTheme: source.textTheme,
      visualDensity: source.visualDensity,
      listTileTheme: source.listTileTheme,
    );
    return Theme(
      data: theme,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: child,
      ),
    );
  }
}
