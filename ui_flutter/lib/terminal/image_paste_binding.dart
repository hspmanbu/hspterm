import 'package:flutter/services.dart';

import 'application_keys.dart';

class ImagePasteBinding {
  const ImagePasteBinding({
    this.enabled = true,
    this.key = 'KeyV',
    this.modifiers = 6,
  });
  final bool enabled;
  final String key;
  final int modifiers;
  static final keys = Map<String, LogicalKeyboardKey>.unmodifiable(
    Map.of(PaletteBinding.keys)
      ..removeWhere((key, _) => key.startsWith('Digit')),
  );
  factory ImagePasteBinding.parse(Map<String, dynamic> value) {
    if (value.length != 3 ||
        value['enabled'] is! bool ||
        !keys.containsKey(value['key']) ||
        ![5, 6, 7].contains(value['modifiers']) ||
        value['modifiers'] == 5 &&
            ['KeyC', 'KeyV', 'KeyF'].contains(value['key'])) {
      throw const FormatException('图片粘贴快捷键无效或与复制/粘贴/搜索冲突');
    }
    return ImagePasteBinding(
      enabled: value['enabled'] as bool,
      key: value['key'] as String,
      modifiers: value['modifiers'] as int,
    );
  }
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'key': key,
    'modifiers': modifiers,
  };
  bool matches(KeyEvent event) => PaletteBinding(
    enabled: enabled,
    key: keys[key]!,
    modifiers: modifiers,
  ).matches(event);
}
