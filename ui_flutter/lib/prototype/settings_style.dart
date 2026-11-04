import 'package:flutter/material.dart';

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
