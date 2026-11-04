import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Layout only. It never changes a terminal cell, character or protocol state.
class TerminalTypography {
  const TerminalTypography({
    this.kind = 'builtin',
    this.family = 'JetBrainsMono',
    this.size = 15,
    this.lineHeight = 1.4,
    this.padding = 8,
    this.ligatures = false,
  });
  final String kind, family;
  final double size, lineHeight, padding;
  final bool ligatures;

  String get renderFamily => kind == 'imported'
      ? 'HSPImported-$family'
      : kind == 'builtin' && family == 'JetBrainsMonoNerd'
      ? 'JetBrainsMono'
      : family;
  List<String> get fallback => [
    if (kind == 'builtin' && family == 'JetBrainsMonoNerd') 'HSPNerdSymbols',
    'JetBrainsMono',
    'NotoSansCJK',
    'Cascadia Mono',
    'Consolas',
    'monospace',
  ];
  List<ui.FontFeature> get features => [
    if (ligatures)
      const ui.FontFeature.enable('liga')
    else
      const ui.FontFeature.disable('liga'),
    if (ligatures)
      const ui.FontFeature.enable('calt')
    else
      const ui.FontFeature.disable('calt'),
    const ui.FontFeature.disable('kern'),
  ];
  TextStyle textStyle({double? fontSize}) => TextStyle(
    fontFamily: renderFamily,
    fontFamilyFallback: fallback,
    fontSize: fontSize ?? size,
    height: 1,
    fontFeatures: features,
  );
  TerminalTypography copyWith({
    String? kind,
    String? family,
    double? size,
    double? lineHeight,
    double? padding,
    bool? ligatures,
  }) => TerminalTypography(
    kind: kind ?? this.kind,
    family: family ?? this.family,
    size: size ?? this.size,
    lineHeight: lineHeight ?? this.lineHeight,
    padding: padding ?? this.padding,
    ligatures: ligatures ?? this.ligatures,
  );
  Map<String, Object> toJson() => {
    'kind': kind,
    'family': family,
    'size': size,
    'line_height': lineHeight,
    'padding': padding,
    'ligatures': ligatures,
  };
  factory TerminalTypography.fromJson(Map<String, dynamic> value) {
    final result = TerminalTypography(
      kind: value['kind'] as String,
      family: value['family'] as String,
      size: (value['size'] as num).toDouble(),
      lineHeight: (value['line_height'] as num).toDouble(),
      padding: (value['padding'] as num).toDouble(),
      ligatures: value['ligatures'] as bool,
    );
    if (!result.size.isFinite ||
        result.size < 9 ||
        result.size > 36 ||
        !result.lineHeight.isFinite ||
        result.lineHeight < 1 ||
        result.lineHeight > 2 ||
        !result.padding.isFinite ||
        result.padding < 0 ||
        result.padding > 32 ||
        !['builtin', 'system', 'imported'].contains(result.kind) ||
        result.family.isEmpty ||
        result.family.length > 192 ||
        result.family.runes.any((r) => r < 32 || (r >= 127 && r <= 159)) ||
        (result.kind == 'builtin' &&
            ![
              'JetBrainsMono',
              'JetBrainsMonoNerd',
              'NotoSansCJK',
            ].contains(result.family)) ||
        (result.kind == 'imported' &&
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(result.family)) ||
        (result.kind == 'system' && result.family.startsWith('HSPImported-'))) {
      throw const FormatException('终端字体或排版配置无效');
    }
    return result;
  }
  @override
  bool operator ==(Object other) =>
      other is TerminalTypography &&
      kind == other.kind &&
      family == other.family &&
      size == other.size &&
      lineHeight == other.lineHeight &&
      padding == other.padding &&
      ligatures == other.ligatures;
  @override
  int get hashCode =>
      Object.hash(kind, family, size, lineHeight, padding, ligatures);
}
