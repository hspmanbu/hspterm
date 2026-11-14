import 'package:flutter/material.dart';

/// Fixed-width Latin/space metrics; CJK glyphs use the bundled fallback.
/// Editing is plain text: no automatic correction or smart punctuation.
TextStyle plainEditorStyle(BuildContext context, {double size = 14}) =>
    Theme.of(context).textTheme.bodyMedium!.copyWith(
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: const ['NotoSansCJK', 'Consolas', 'monospace'],
      fontSize: size,
      fontWeight: FontWeight.normal,
      letterSpacing: 0,
      wordSpacing: 0,
      height: 1.4,
      fontFeatures: const [
        FontFeature.disable('liga'),
        FontFeature.disable('calt'),
      ],
    );
