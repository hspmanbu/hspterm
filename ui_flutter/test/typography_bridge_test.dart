import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/typography_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('native font import is encrypted and scoped; reopen restores choice without SSH', () async {
    final dir = await Directory.systemTemp.createTemp(
      'hspterm-typography-native-',
    );
    const gateway = NativeTypographyGateway();
    final path = '${dir.path}/font.vault';
    const master = 'synthetic-typography-master';
    try {
      await rust.unlockVault(path: path, password: master);
      final first = await gateway.load();
      final data = (await rootBundle.load(
        'assets/fonts/JetBrainsMono-Regular.ttf',
      )).buffer.asUint8List();
      final imported = await gateway.importFont(
        first,
        'Synthetic imported mono',
        data,
      );
      final id = imported.fonts.single.id;
      final original = await gateway.fontBytes(imported, id);
      expect(original, data);
      final selected = await gateway.save(
        imported,
        imported.settings.copyWith(
          kind: 'imported',
          family: id,
          size: 17,
          lineHeight: 1.6,
          padding: 12,
          ligatures: true,
        ),
      );
      final portable = jsonDecode(
        await rust.loadTerminalPreferences(),
      ) as Map<String, dynamic>;
      final geometry =
          (portable['value'] as Map<String, dynamic>)['typography']
              as Map<String, dynamic>;
      expect(geometry, {
        'size': 17.0,
        'line_height': 1.6,
        'padding': 12.0,
        'ligatures': true,
      });
      expect(geometry.containsKey('family'), false);
      await expectLater(gateway.save(first, first.settings), throwsA(anything));
      await rust.unlockVault(path: path, password: master);
      await expectLater(gateway.removeFont(selected, id), throwsA(anything));
      final reopened = await gateway.load();
      expect(reopened.settings.family, id);
      expect(reopened.settings.size, 17);
      final removed = await gateway.removeFont(reopened, id);
      expect(removed.fonts, isEmpty);
      expect(removed.settings.family, 'JetBrainsMono');
      expect(removed.settings.ligatures, true);
      expect(removed.settings.padding, 12);
      final raw = await File(path).readAsBytes();
      expect(
        utf8.decode(raw, allowMalformed: true),
        isNot(contains('Synthetic imported mono')),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isLinux);
}
